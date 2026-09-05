class_name PropScatter
extends RefCounted
## Dresses a generated island with the Stylized Nature MegaKit, from the same
## seed the terrain came from.
##
## Two placement strategies, because a forest and a lawn are different problems:
##
## * **Sparse layers** (trees, dead trees, boulders) are dart-thrown with a
##   minimum gap. There are a few dozen of them, each one is individually
##   visible, and the thing that must not happen is two trunks growing out of
##   each other.
## * **Dense layers** (grass, clover, flowers, pebbles, fallen petals) are placed
##   by jittered stratified sampling: walk a grid over the island and accept a
##   randomly-offset point inside each cell. Dart-throwing eight hundred blades
##   of grass costs a quadratic number of distance checks to solve a problem that
##   a grid solves for free, and stratification also guarantees even coverage,
##   which uniform random sampling emphatically does not.
##
## Both strategies are gated by a per-layer noise field, so the island grows
## thickets and clearings instead of an even sprinkle. That noise is what makes
## the scatter read as vegetation rather than as a particle system.
##
## Everything dense goes into `MultiMeshInstance3D`s grouped by source mesh. A
## thousand `Node3D`s would cost a thousand transform updates and a thousand draw
## calls a frame for props that never move; a MultiMesh is one of each.

const KIT := "res://assets/Stylized_Nature_MegaKitStandard/glTF/%s.gltf"

## Physics layer 1 — "world" in project.godot. Trunks and boulders are cover, so
## they collide with Gubs and stop spears exactly like the terrain does.
const LAYER_WORLD := 1


## A circle nothing may be planted inside. Landmarks and spawn pads publish
## these before the scatter runs, which is the whole reason the scatter runs
## last: a shrine that has to fight a tree for its own courtyard is a shrine
## that gets rebuilt every time the seed changes.
class Keepout extends RefCounted:
	var centre: Vector2
	var radius: float
	## When false only the sparse layers are excluded, so a landmark can keep
	## its skirt of grass and flowers while keeping trees off it.
	var blocks_dense: bool

	func _init(at: Vector2, size: float, all: bool = true) -> void:
		centre = at
		radius = size
		blocks_dense = all


## Sparse layers: a handful of large props, dart-thrown against a minimum gap.
##
## `radial_power` shapes where they go, as a weight on the normalised distance
## from the landmass centre. Above 1 pushes a layer to the rim, below 1 pulls it
## inward, and the trees sit slightly outward on purpose: a forest ringing an
## arena frames the fight, while a forest standing in the middle of it turns an
## instant-kill weapon into a coin toss.
const SPARSE_LAYERS := [
	{
		"name": "Trees",
		"models": ["CommonTree_1", "CommonTree_2", "CommonTree_3", "CommonTree_4",
			"CommonTree_5", "Pine_1", "Pine_2", "Pine_3", "Pine_4", "Pine_5"],
		"count": 42, "gap": 3.7, "reserve": 2.6,
		"scale": [0.78, 1.16], "slope_max": 0.5, "rim_margin": 2.2, "sink": 0.22,
		"radial_power": 1.35, "clump": 0.55, "clump_frequency": 0.055,
		"trunk_radius": 0.44, "trunk_fraction": 0.62,
	},
	{
		"name": "DeadTrees",
		"models": ["DeadTree_1", "DeadTree_2", "DeadTree_3", "DeadTree_4", "DeadTree_5"],
		"count": 7, "gap": 5.5, "reserve": 3.0,
		"scale": [0.42, 0.62], "slope_max": 0.45, "rim_margin": 2.6, "sink": 0.25,
		"radial_power": 1.6, "clump": 0.0, "clump_frequency": 0.05,
		"trunk_radius": 0.36, "trunk_fraction": 0.55,
	},
	{
		"name": "Boulders",
		"models": ["Rock_Medium_1", "Rock_Medium_2", "Rock_Medium_3"],
		"count": 16, "gap": 4.2, "reserve": 2.2,
		"scale": [0.42, 0.95], "slope_max": 0.8, "rim_margin": 1.4, "sink": 0.42,
		"radial_power": 0.9, "clump": 0.35, "clump_frequency": 0.07,
		"trunk_radius": 0.0, "trunk_fraction": 0.0,
	},
]

## Dense layers: stratified over a grid of `cell` metres, each candidate kept
## with probability `chance` once the clumping noise has had its say.
##
## `shadows` is off for everything under about knee height. A blade of grass
## casts a shadow the size of a blade of grass, and paying for it in every one of
## a dozen torch shadow maps buys a pixel of noise.
const DENSE_LAYERS := [
	{
		"name": "Bushes",
		"models": ["Bush_Common", "Bush_Common_Flowers"],
		"cell": 2.8, "chance": 0.62, "scale": [0.42, 0.78], "align": 0.25,
		"slope_max": 0.7, "rim_margin": 1.0, "sink": 0.12,
		"radial_power": 1.1, "clump": 0.5, "clump_frequency": 0.06, "shadows": true,
	},
	{
		"name": "Ferns",
		"models": ["Fern_1", "Plant_1", "Plant_1_Big", "Plant_7", "Plant_7_Big"],
		"cell": 2.2, "chance": 0.7, "scale": [0.18, 0.34], "align": 0.35,
		"slope_max": 0.8, "rim_margin": 0.8, "sink": 0.08,
		"radial_power": 1.2, "clump": 0.6, "clump_frequency": 0.08, "shadows": false,
	},
	{
		"name": "Grass",
		# Scale matters more here than anywhere else in the table.
		# `Grass_Common_Tall` is 1.87 m at scale 1 and a Gub is 1.81 m: the first
		# pass ran to scale 1.0 and grew grass taller than the players, which
		# reads as a swamp and hides a crouched Gub at three metres.
		"models": ["Grass_Common_Short", "Grass_Common_Tall", "Grass_Wispy_Short",
			"Grass_Wispy_Tall"],
		"cell": 0.68, "chance": 0.95, "scale": [0.30, 0.58], "align": 0.4,
		"slope_max": 0.95, "rim_margin": 0.3, "sink": 0.06,
		"radial_power": 0.85, "clump": 0.22, "clump_frequency": 0.09, "shadows": false,
	},
	{
		"name": "Clover",
		"models": ["Clover_1", "Clover_2"],
		"cell": 1.7, "chance": 0.82, "scale": [0.34, 0.62], "align": 0.5,
		"slope_max": 0.8, "rim_margin": 0.5, "sink": 0.05,
		"radial_power": 0.7, "clump": 0.7, "clump_frequency": 0.11, "shadows": false,
	},
	{
		"name": "Flowers",
		"models": ["Flower_3_Group", "Flower_3_Single", "Flower_4_Group", "Flower_4_Single"],
		"cell": 2.3, "chance": 0.75, "scale": [0.26, 0.48], "align": 0.2,
		"slope_max": 0.6, "rim_margin": 0.8, "sink": 0.05,
		# Whisperbloom Hollow is named after what grows in the bowl, so the
		# flowers are pulled toward the middle rather than pushed to the rim.
		"radial_power": 0.45, "clump": 0.8, "clump_frequency": 0.13, "shadows": false,
	},
	{
		"name": "Mushrooms",
		"models": ["Mushroom_Common", "Mushroom_Common", "Mushroom_Laetiporus"],
		"cell": 4.0, "chance": 0.6, "scale": [0.55, 1.05], "align": 0.5,
		"slope_max": 0.8, "rim_margin": 0.8, "sink": 0.04,
		"radial_power": 1.15, "clump": 0.75, "clump_frequency": 0.14, "shadows": false,
	},
	{
		"name": "Pebbles",
		"models": ["Pebble_Round_1", "Pebble_Round_2", "Pebble_Round_3", "Pebble_Round_4",
			"Pebble_Round_5", "Pebble_Square_1", "Pebble_Square_2", "Pebble_Square_3",
			"Pebble_Square_4", "Pebble_Square_5", "Pebble_Square_6"],
		"cell": 2.6, "chance": 0.68, "scale": [0.45, 1.1], "align": 0.9,
		"slope_max": 1.2, "rim_margin": 0.2, "sink": 0.05,
		"radial_power": 1.25, "clump": 0.4, "clump_frequency": 0.1, "shadows": false,
	},
	{
		"name": "Petals",
		"models": ["Petal_1", "Petal_2", "Petal_3", "Petal_4", "Petal_5"],
		"cell": 2.9, "chance": 0.66, "scale": [0.28, 0.55], "align": 1.0,
		"slope_max": 0.7, "rim_margin": 0.4, "sink": 0.01,
		"radial_power": 0.6, "clump": 0.85, "clump_frequency": 0.16, "shadows": false,
	},
]

## Number of dart throws allowed per prop a sparse layer asks for. Generous,
## because the rejection tests are cheap and the alternative to giving up is a
## layer whose count quietly depends on how lucky the seed was — the first pass
## allowed 40, and the tally showed it placing thirteen of the forty trees it
## was asked for and none at all of the dead ones, which on screen read as
## "the scatter looks sparse" rather than as the outright failure it was.
const SPARSE_ATTEMPTS := 200

var _island: IslandGenerator
var _keepouts: Array[Keepout] = []
var _rng := RandomNumberGenerator.new()
## Everything sparse that has been planted, as (x, z, radius). Dense layers test
## against this too, so grass never sprouts out of the middle of a trunk.
var _occupied: Array[Vector3] = []
var _mesh_cache: Dictionary = {}
var _triangle_cache: Dictionary = {}
## Cumulative area weights over the landmasses, built on first use.
var _area_weights: Array[float] = []

## Where the trees ended up. The falling-leaf emitters in `Ambience` need
## canopies to fall out of, and re-deriving them from the scene tree afterwards
## would mean trusting node names.
var canopy_points: PackedVector3Array = PackedVector3Array()
## Rough triangle cost of everything placed, for `tools/island_report.gd`.
var triangles: int = 0
var instances: int = 0
## layer name -> how many were placed. "The island looks bare" is a judgement;
## "the grass layer placed 41" is a number, and only one of them is debuggable.
var counts: Dictionary = {}


func _init(island: IslandGenerator, map_seed: int, keepouts: Array[Keepout]) -> void:
	_island = island
	_keepouts = keepouts
	# Offset from the terrain's own seed so that two maps whose terrain differs
	# cannot accidentally share a scatter, and vice versa.
	_rng.seed = map_seed ^ 0x5CA77E4


## Build every layer under `parent`. Called once, at load.
func scatter(parent: Node3D) -> void:
	for layer: Dictionary in SPARSE_LAYERS:
		_scatter_sparse(parent, layer)
	for layer: Dictionary in DENSE_LAYERS:
		_scatter_dense(parent, layer)


# ------------------------------------------------------------------ sparse ---

func _scatter_sparse(parent: Node3D, layer: Dictionary) -> void:
	var group := Node3D.new()
	group.name = layer["name"]
	parent.add_child(group)

	var noise := _layer_noise(layer)
	var wanted: int = layer["count"]
	var reserve: float = layer["reserve"]
	# This layer's own placements, kept separately from `_occupied`. The minimum
	# gap is a *within-layer* rule — "two trees do not grow out of each other" —
	# and applying it across layers as well is what stopped the boulders being
	# placed at all: thirty trees each vetoing a 4.2 m disc covers more than the
	# island's whole area, so every boulder throw landed inside somebody's gap.
	var mine: Array[Vector2] = []
	var placed := 0
	var attempts := wanted * SPARSE_ATTEMPTS
	while placed < wanted and attempts > 0:
		attempts -= 1
		var spot := _candidate(layer)
		if spot == Vector2.INF:
			continue
		if not _clump_allows(noise, spot, layer):
			continue
		if _crowded(spot, mine, float(layer["gap"])):
			continue
		if _overlaps(spot, reserve):
			continue

		var models: Array = layer["models"]
		var model: String = models[_rng.randi_range(0, models.size() - 1)]
		var mesh := kit_mesh(model)
		if mesh == null:
			continue

		var uniform := _rng.randf_range(layer["scale"][0], layer["scale"][1])
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.position = _island.surface_point(spot.x, spot.y) \
			- Vector3.UP * float(layer["sink"]) * uniform
		node.rotation.y = _rng.randf_range(0.0, TAU)
		# A little non-uniform squash, so ten copies of one tree do not read as
		# ten copies of one tree.
		node.scale = Vector3(uniform * _rng.randf_range(0.94, 1.06), uniform,
			uniform * _rng.randf_range(0.94, 1.06))
		group.add_child(node)

		_add_collider(group, node, layer, mesh, uniform)
		_occupied.append(Vector3(spot.x, spot.y, reserve * uniform))
		mine.append(spot)
		if layer["name"] == "Trees":
			canopy_points.append(node.position + Vector3.UP * mesh.get_aabb().size.y
				* uniform * 0.72)
		triangles += _triangles_of(model)
		instances += 1
		placed += 1
	counts[layer["name"]] = placed


## Trunks are cylinders and boulders are convex hulls, both on the world layer.
##
## This is a gameplay decision, not a cosmetic one: an instant-kill projectile
## needs cover to be *reliable*, and a tree you can shoot through but not walk
## through — or vice versa — is worse than a tree that is not there.
func _add_collider(group: Node3D, node: MeshInstance3D, layer: Dictionary,
		mesh: Mesh, uniform: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	body.position = node.position
	body.rotation = node.rotation

	var shape := CollisionShape3D.new()
	if float(layer["trunk_radius"]) > 0.0:
		var height := mesh.get_aabb().size.y * uniform * float(layer["trunk_fraction"])
		var cylinder := CylinderShape3D.new()
		cylinder.radius = float(layer["trunk_radius"]) * uniform
		cylinder.height = height
		shape.shape = cylinder
		# The cylinder is centred on its origin; the trunk starts at the ground.
		shape.position = Vector3.UP * height * 0.5
	else:
		# `create_convex_shape(clean, simplify)`: the simplified hull of a
		# boulder is a dozen planes, which is what a boulder should cost.
		var convex := mesh.create_convex_shape(true, true)
		if convex == null:
			return
		shape.shape = convex
		body.scale = node.scale
	body.add_child(shape)
	group.add_child(body)


# ------------------------------------------------------------------- dense ---

func _scatter_dense(parent: Node3D, layer: Dictionary) -> void:
	var noise := _layer_noise(layer)
	var cell: float = layer["cell"]
	var reach := _island.extent()
	var models: Array = layer["models"]

	# One transform list per source mesh, because a MultiMesh draws exactly one.
	var buckets: Dictionary = {}
	for model: String in models:
		buckets[model] = []

	var steps := int(ceil(reach * 2.0 / cell))
	for ix in steps:
		for iz in steps:
			var base_x := -reach + (float(ix) + 0.5) * cell
			var base_z := -reach + (float(iz) + 0.5) * cell
			# Jitter inside the cell. Without it the layer is visibly a grid;
			# with the full cell width it degenerates back to uniform random and
			# clumps again. 0.42 keeps the spacing honest and the pattern gone.
			var spot := Vector2(
				base_x + _rng.randf_range(-cell, cell) * 0.42,
				base_z + _rng.randf_range(-cell, cell) * 0.42)
			if _rng.randf() > float(layer["chance"]):
				continue
			if not _usable(spot, layer):
				continue
			if not _clump_allows(noise, spot, layer):
				continue
			# Dense props have no reserve of their own — grass growing at the
			# foot of a tree is exactly right — so they are only kept out of the
			# trunk itself.
			if _overlaps(spot, 0.0):
				continue

			var model: String = models[_rng.randi_range(0, models.size() - 1)]
			buckets[model].append(_dense_transform(spot, layer))

	var group := Node3D.new()
	group.name = layer["name"]
	parent.add_child(group)
	var placed := 0
	for model: String in buckets:
		var transforms: Array = buckets[model]
		if transforms.is_empty():
			continue
		var node := _multimesh_for(model, transforms, bool(layer["shadows"]))
		if node != null:
			group.add_child(node)
			placed += transforms.size()
	counts[layer["name"]] = placed


func _dense_transform(spot: Vector2, layer: Dictionary) -> Transform3D:
	var uniform := _rng.randf_range(layer["scale"][0], layer["scale"][1])
	var up := Vector3.UP.lerp(_island.normal_at(spot.x, spot.y),
		float(layer["align"])).normalized()
	# Build the basis from the (tilted) up vector rather than rotating about a
	# world axis, so a pebble lying on a bank lies *on* the bank.
	var forward := Vector3.FORWARD.rotated(Vector3.UP, _rng.randf_range(0.0, TAU))
	var right := up.cross(forward).normalized()
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	var basis := Basis(right, up, right.cross(up).normalized())
	basis = basis.scaled(Vector3(uniform, uniform, uniform))

	var origin := _island.surface_point(spot.x, spot.y) \
		- Vector3.UP * float(layer["sink"]) * uniform
	return Transform3D(basis, origin)


func _multimesh_for(model: String, transforms: Array, shadows: bool) -> MultiMeshInstance3D:
	var mesh := kit_mesh(model)
	if mesh == null:
		return null

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	var bounds := AABB()
	for i in transforms.size():
		var xform: Transform3D = transforms[i]
		multi.set_instance_transform(i, xform)
		var box := xform * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)

	var node := MultiMeshInstance3D.new()
	node.name = model
	node.multimesh = multi
	# Godot can derive this itself, but only by walking every instance on the
	# first frame; the island already knows the answer.
	node.custom_aabb = bounds
	node.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

	triangles += _triangles_of(model) * transforms.size()
	instances += transforms.size()
	return node


# ------------------------------------------------------------------- tests ---

## A random point on some landmass that passes every placement rule, or
## `Vector2.INF` if this throw missed.
##
## Sampled inside a chosen landmass's own disc rather than inside the map's
## bounding square. The square is four times the area of the land in it, so
## three throws in four used to be thrown at the void before any placement rule
## had even been consulted.
##
## The landmass is picked in proportion to its area, so the islets get their
## share and no more, and the radius uses `sqrt` because uniform-in-radius is not
## uniform-in-area — it piles props into the middle.
func _candidate(layer: Dictionary) -> Vector2:
	var mass := _pick_landmass()
	var reach := mass.base_radius + mass.rim_amp
	var angle := _rng.randf_range(0.0, TAU)
	var radius := sqrt(_rng.randf()) * reach
	var spot := mass.centre + Vector2(cos(angle), sin(angle)) * radius
	return spot if _usable(spot, layer) else Vector2.INF


func _pick_landmass() -> IslandGenerator.Landmass:
	if _area_weights.is_empty():
		var running := 0.0
		for mass: IslandGenerator.Landmass in _island.landmasses:
			running += mass.base_radius * mass.base_radius
			_area_weights.append(running)
	var pick := _rng.randf() * _area_weights[_area_weights.size() - 1]
	for i in _area_weights.size():
		if pick <= _area_weights[i]:
			return _island.landmasses[i]
	return _island.landmasses[0]


func _usable(spot: Vector2, layer: Dictionary) -> bool:
	var mass: IslandGenerator.Landmass = _island.landmass_at(spot.x, spot.y)
	if mass == null:
		return false
	# Keep back from the lip. A tree half off the edge looks like a bug, and the
	# rim is also the one place a Gub most needs to see their own feet.
	#
	# Capped at a quarter of the landmass radius, because a flat 2.2 m margin is
	# a sensible skirt on a nineteen-metre island and the *entire surface* of a
	# four-metre islet. Uncapped, both islets came out bald.
	var margin := minf(float(layer["rim_margin"]), mass.base_radius * 0.25)
	if _island.inset_at(spot.x, spot.y) < margin:
		return false
	if _island.slope_at(spot.x, spot.y) > float(layer["slope_max"]):
		return false

	var dense: bool = layer.has("cell")
	for keepout: Keepout in _keepouts:
		if not keepout.blocks_dense and dense:
			continue
		if spot.distance_to(keepout.centre) < keepout.radius:
			return false

	# Radial weighting, evaluated as a rejection test so it composes with
	# everything else instead of needing its own sampling distribution.
	var local := spot - mass.centre
	var t := clampf(local.length() / maxf(mass.rim_radius(local.angle()), 0.001), 0.0, 1.0)
	return _rng.randf() <= pow(t, float(layer["radial_power"]))


## Thickets and clearings. `clump` is how much of the decision the noise gets:
## at 0 the layer is even, at 1 it only grows where the field is high.
func _clump_allows(noise: FastNoiseLite, spot: Vector2, layer: Dictionary) -> bool:
	var strength: float = layer["clump"]
	if strength <= 0.0:
		return true
	var field := noise.get_noise_2d(spot.x, spot.y) * 0.5 + 0.5
	return _rng.randf() <= lerpf(1.0, field * field * 1.9, strength)


## Minimum spacing within one layer.
func _crowded(spot: Vector2, placed: Array[Vector2], gap: float) -> bool:
	for other: Vector2 in placed:
		if spot.distance_squared_to(other) < gap * gap:
			return true
	return false


## Footprint overlap against everything sparse already standing, whatever layer
## it came from. Half of each radius, so two props may touch but never grow
## through one another.
func _overlaps(spot: Vector2, reserve: float) -> bool:
	for entry: Vector3 in _occupied:
		var limit := (entry.z + reserve) * 0.55
		if spot.distance_squared_to(Vector2(entry.x, entry.y)) < limit * limit:
			return true
	return false


func _layer_noise(layer: Dictionary) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	# Hashing the layer name in keeps every layer's clumping independent while
	# still being a pure function of the map seed.
	noise.seed = _rng.seed + hash(layer["name"])
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = layer["clump_frequency"]
	noise.fractal_octaves = 2
	return noise


# --------------------------------------------------------------- kit access ---

## The `Mesh` inside one MegaKit model, cached.
##
## Every kit file is a `Node3D` wrapping a single `MeshInstance3D`; taking the
## mesh out and dropping the wrapper means a scattered prop is one node rather
## than two, and it is the only form a MultiMesh can use at all.
func kit_mesh(model: String) -> Mesh:
	if _mesh_cache.has(model):
		return _mesh_cache[model]
	var mesh := load_kit_mesh(model)
	_mesh_cache[model] = mesh
	return mesh


## Uncached load, also used by the landmark pass for its one-off pieces.
static func load_kit_mesh(model: String) -> Mesh:
	var packed := load(KIT % model) as PackedScene
	if packed == null:
		push_error("PropScatter: missing kit model '%s'" % model)
		return null
	var root := packed.instantiate()
	var mesh: Mesh = null
	for child in root.get_children():
		if child is MeshInstance3D:
			mesh = (child as MeshInstance3D).mesh
			break
	root.free()
	return mesh


## Triangle count of one kit model, cached — `surface_get_arrays` copies the
## whole index buffer out of the rendering server, which is not something to do
## once per scattered prop.
func _triangles_of(model: String) -> int:
	if _triangle_cache.has(model):
		return _triangle_cache[model]
	var mesh := kit_mesh(model)
	var total := 0
	if mesh != null:
		for s in mesh.get_surface_count():
			var indices: PackedInt32Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			total += indices.size() / 3
	_triangle_cache[model] = total
	return total
