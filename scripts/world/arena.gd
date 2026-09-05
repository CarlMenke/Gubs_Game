class_name Arena
extends Node3D
## Whisperbloom Hollow — the map, and the scene `SceneFlow.go_to_arena()` loads.
##
## This is the node that closes the loop between the world and the match:
## everything above it in `scripts/game` waits for exactly one call,
## `MatchState.register_arena(players_root, spawn_points)`, and until something
## makes it there is no game. `tools/combat_range.tscn` was the only caller until
## this scene existed, which is why this file keeps to the same contract it does:
## build the world, hand over a node to parent Gubs under and a list of places to
## put them, and then get out of the way.
##
## The order of the build is load-bearing:
##
##   1. **terrain**, because everything else asks it how high the ground is;
##   2. **landmarks**, because they are hand-placed and get first refusal on
##      where they stand;
##   3. **spawn points**, which need to dodge the landmarks and then become
##      obstacles themselves;
##   4. **prop scatter**, which fills whatever is left without ever landing on
##      anything from 2 or 3;
##   5. **torches**, from the spots the landmarks asked for;
##   6. **ambience**, which needs to know where the scatter put its trees.
##
## Nothing here is replicated. Every peer builds the same island because every
## peer builds it from `Net.config.map_seed`, which is part of the match config
## and therefore already on every machine before this scene loads (D-007).

const ENVIRONMENT := "res://resources/config/arena_env.tres"

## D-009: the sky shader draws the moon at `LIGHT0_DIRECTION`, so this
## DirectionalLight3D *is* the moon. Changing where it points moves the moon in
## the sky. The energy is deliberately tiny — it is fill, and the torches are the
## key light.
const MOON_DIRECTION := Vector3(-0.42, 0.38, -0.82)
const MOON_COLOR := Color(0.62, 0.72, 1.0)
const MOON_ENERGY := 0.30

## How many spawn pads to lay out. Eight, matching `MatchConfig.MAX_PLAYERS`, so
## a full lobby never has two Gubs sharing a pad on the opening frame.
const SPAWN_COUNT := MatchConfig.MAX_PLAYERS
## Pads sit at this fraction of the main island's rim radius: far enough out that
## nobody opens the match standing in the hollow with five sightlines on them,
## far enough in that a spawn is never a step from the void.
const SPAWN_RING := 0.66
## A pad must be flatter than this and at least this far inside the rim.
const SPAWN_MAX_SLOPE := 0.32
const SPAWN_RIM_MARGIN := 4.0
## Gubs are spawned a few centimetres up so the capsule settles onto the ground
## rather than starting the match intersecting it.
const SPAWN_LIFT := 0.12

var island: IslandGenerator
var landmarks: Landmarks
var scatter: PropScatter
var spawn_points: Array[Transform3D] = []

var _players: Node3D
var _items: Node3D


func _ready() -> void:
	var map_seed := Net.config.map_seed
	var started := Time.get_ticks_msec()

	_build_environment()
	_build_containers()

	island = IslandGenerator.new(map_seed)
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	add_child(terrain)
	island.build_into(terrain)

	landmarks = Landmarks.new(island, map_seed)
	landmarks.build(self)

	_build_spawn_points()

	scatter = PropScatter.new(island, map_seed, landmarks.keepouts)
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	scatter.scatter(props)

	_build_torches()
	Ambience.build(self, island, scatter.canopy_points, map_seed)

	print("arena: Whisperbloom Hollow built from seed %d in %d ms" % [
		map_seed, Time.get_ticks_msec() - started])
	print("  %d props (~%dk triangles), %d spawns, %d torches" % [
		scatter.instances, scatter.triangles / 1000, spawn_points.size(),
		$Torches.get_child_count()])
	print("  scatter %s" % scatter.counts)

	# The handover. Every peer calls this for itself; only the host acts on it,
	# and it is what starts the warmup.
	MatchState.register_arena(_players, spawn_points)


# ------------------------------------------------------------- environment ---

func _build_environment() -> void:
	var world := WorldEnvironment.new()
	world.name = "Environment"
	world.environment = load(ENVIRONMENT)
	add_child(world)

	var moon := DirectionalLight3D.new()
	moon.name = "Moon"
	add_child(moon)
	# Positioned then aimed at the origin, so `LIGHT0_DIRECTION` inside the sky
	# shader comes out as MOON_DIRECTION exactly and the moon disc is drawn where
	# the moonlight is coming from. Setting a rotation by hand and hoping the two
	# agree is how a moon ends up lighting the island from behind itself.
	moon.position = MOON_DIRECTION.normalized() * 80.0
	moon.look_at(Vector3.ZERO, Vector3.UP)
	moon.light_color = MOON_COLOR
	moon.light_energy = MOON_ENERGY
	moon.light_specular = 0.35
	moon.shadow_enabled = true
	# The island is ~55 m across, so shadows past 90 m are shadows of nothing.
	moon.directional_shadow_max_distance = 90.0
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	moon.light_volumetric_fog_energy = 0.6


func _build_containers() -> void:
	# `MatchState._create_gub` parents every Gub here.
	_players = Node3D.new()
	_players.name = "Players"
	add_child(_players)

	# `GubCombat._spawn_root` finds this by group. Without it every spear,
	# mushroom and lure is parented to the scene root and nothing can be swept
	# up between rounds.
	_items = Node3D.new()
	_items.name = "SpawnedItems"
	_items.add_to_group("spawned_items")
	add_child(_items)


# ------------------------------------------------------------------ spawns ---

## Lay out the spawn ring (4.10).
##
## Pads are evenly spaced around the main island rather than placed by hand,
## because the rim outline moves with the seed and eight hand-typed coordinates
## would drift off the island the first time somebody changed it. What *is* hand
## decided is the shape of the ring: even spacing, well inside the rim, off the
## high ground, and never inside a landmark.
##
## Each pad is searched for rather than assumed: the ideal point is tried first,
## then rings of alternates around it. A pad that cannot be solved falls back to
## its ideal position, which is always on land — it may just be steeper than we
## would like, and a slightly awkward spawn beats a missing one.
func _build_spawn_points() -> void:
	var mass := island.landmasses[0]
	var rng := RandomNumberGenerator.new()
	# Offset from the map seed so the ring rotates between maps and the same
	# bearing is not always "the spawn behind the shrine".
	rng.seed = Net.config.map_seed ^ 0x59A70

	var twist := rng.randf_range(0.0, TAU)
	for i in SPAWN_COUNT:
		var bearing := twist + TAU * float(i) / float(SPAWN_COUNT)
		var found := _solve_spawn(mass, bearing, rng)
		var ground := island.surface_point(found.x, found.y) + Vector3.UP * SPAWN_LIFT
		# Facing the middle of the map. A player whose first frame looks out over
		# the void has to turn around before they can read anything.
		var yaw := Gub.yaw_towards(Vector3(-found.x, 0.0, -found.y).normalized())
		spawn_points.append(Transform3D(Basis(Vector3.UP, yaw), ground))

		# Published to the scatter so no tree or boulder grows on a pad and a Gub
		# can see out of its own spawn. Deliberately a *sparse-only* keepout:
		# an earlier version also kept the dense layers off, and every pad came
		# out as a bald circle of bare earth four metres across — which is both
		# ugly and a free map marker showing everyone where the spawns are.
		landmarks.keepouts.append(PropScatter.Keepout.new(found, 3.6, false))


func _solve_spawn(mass: IslandGenerator.Landmass, bearing: float,
		rng: RandomNumberGenerator) -> Vector2:
	var ideal := _spawn_candidate(mass, bearing, SPAWN_RING)
	# Widening search: nudge the bearing a little, then pull the radius in a
	# little, then both. Sixteen tries covers a quarter of the rim either way,
	# which is more than a spawn should ever have to move.
	for attempt in 16:
		var swing := (0.06 + 0.02 * float(attempt)) * (1.0 if attempt % 2 == 0 else -1.0)
		var pull := SPAWN_RING - 0.035 * float(attempt / 2)
		var spot := _spawn_candidate(mass, bearing + swing, pull)
		if _spawn_is_good(spot):
			return spot
	if _spawn_is_good(ideal):
		return ideal
	push_warning("arena: spawn at bearing %.2f fell back to its ideal position" % bearing)
	return ideal


func _spawn_candidate(mass: IslandGenerator.Landmass, bearing: float,
		fraction: float) -> Vector2:
	return Vector2(cos(bearing), sin(bearing)) * mass.rim_radius(bearing) * fraction


func _spawn_is_good(spot: Vector2) -> bool:
	if island.landmass_at(spot.x, spot.y) != island.landmasses[0]:
		return false
	if island.inset_at(spot.x, spot.y) < SPAWN_RIM_MARGIN:
		return false
	if island.slope_at(spot.x, spot.y, 0.8) > SPAWN_MAX_SLOPE:
		return false
	for keepout: PropScatter.Keepout in landmarks.keepouts:
		# Only the hard keepouts matter: a spawn is allowed to be on the grassy
		# skirt of a landmark, just not inside the landmark.
		if keepout.blocks_dense and spot.distance_to(keepout.centre) < keepout.radius + 1.5:
			return false
	# And never on top of a torch. Torches are placed before the spawn ring is
	# solved, and a pad that lands on one puts a player in the brightest circle
	# on the island on their first frame, fully lit to everyone outside it.
	for torch: Landmarks.TorchSpot in landmarks.torch_spots:
		if spot.distance_to(Vector2(torch.position.x, torch.position.z)) < 3.5:
			return false
	return true


# ----------------------------------------------------------------- torches ---

## Plant a torch at every spot the landmark pass asked for (4.5).
##
## The landmarks decide *where* — a torch marks something worth marking — and
## this decides only how many of them get to cast shadows, because that is a
## frame-cost question rather than a level-design one.
func _build_torches() -> void:
	var lights := Node3D.new()
	lights.name = "Torches"
	add_child(lights)

	var index := 0
	for spot: Landmarks.TorchSpot in landmarks.torch_spots:
		# A landmark can ask for a torch on ground the seed moved out from under
		# it. Better a missing torch than one burning in mid-air over the void.
		if spot.position.y <= IslandGenerator.NO_LAND:
			continue
		# Phase from the index and the seed: deterministic across clients, and
		# irrational enough between neighbours that no two torches pulse together.
		var phase := fposmod(float(index) * 2.399963 + float(Net.config.map_seed % 997), TAU)
		var torch := Torch.create(phase, spot.shadows, spot.height_scale)
		torch.name = "Torch%d" % index
		torch.position = spot.position
		lights.add_child(torch)
		index += 1
