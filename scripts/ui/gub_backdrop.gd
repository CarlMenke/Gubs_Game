class_name GubBackdrop
extends Node3D
## The live 3D scene behind the menu and the lobby: a torch-lit glade in
## Whisperbloom Hollow with real Gubs standing in it.
##
## These are ordinary `gub.tscn` instances, not a rendered backdrop image and
## not a special "menu Gub" model. That matters for two reasons. The obvious one
## is that the lobby then shows you the actual roster — eight named, team-tinted
## Gubs with the same nameplates you will read across the island in ten seconds
## (PLAN 1.5). The less obvious one is the same argument the combat range is
## built on (D-011): every Gub here is a *remote* Gub, so the menu is one more
## place the remote-Gub code path is looked at before eight people rely on it.
##
## "Remote" is achieved exactly the way `MatchState` does it: multiplayer
## authority is set to a peer id that will never connect, and it is set *before*
## the node enters the tree, so no rig ever briefly believes it is local and
## steals the viewport.
##
## The glade itself is seeded rather than hand-placed, from the same CC0 kit the
## island will use (D-007), so the menu and the map are made of the same trees.

## Peer ids for the backdrop Gubs. Far outside anything ENet hands out and
## outside the combat range's 900s, so nothing can collide with a real peer.
const BACKDROP_PEER_BASE := 8100

const GUB_SCENE := preload("res://scenes/player/gub.tscn")
const KIT := "res://assets/Stylized_Nature_MegaKitStandard/glTF/"

## How the Gubs are arranged and where the camera sits.
##
##   HERO — one Gub, close, three-quarter view, held to the right of frame so a
##          column of menu items can own the left half.
##   RING — the roster gathered around the fire, heads and nameplates high in
##          frame so they clear the lobby panels below them.
enum Formation { HERO, RING }

@export var formation: Formation = Formation.HERO
## Changing this reshuffles the trees without touching anything else.
@export var glade_seed: int = 40219
## Radius of the arc the Gubs stand on, in metres.
@export var ring_radius: float = 3.9
## How much of the circle they occupy. They fill the *far* arc, so the near side
## stays open and the camera looks into the group rather than at its backs.
@export_range(40.0, 300.0) var ring_arc_degrees: float = 170.0

## Trees and undergrowth, by how far out they sit. Pines read as silhouette at
## the treeline; the broad-leafed ones have enough canopy to catch torchlight.
const CANOPY := ["Pine_1", "Pine_3", "Pine_4", "CommonTree_2", "CommonTree_4",
	"TwistedTree_2", "TwistedTree_4"]
const UNDERGROWTH := ["Bush_Common", "Bush_Common_Flowers", "Fern_1", "Plant_1",
	"Plant_7", "Grass_Common_Tall", "Grass_Wispy_Tall"]
const FLOOR_DRESSING := ["Mushroom_Common", "Rock_Medium_1", "Rock_Medium_2",
	"Pebble_Round_2", "Pebble_Square_3", "Clover_1", "Flower_4_Group"]

## Framing per formation: where the camera sits, what it aims at, and how wide.
## The aim point is deliberately off to one side in HERO so the subject sits
## right of centre without the camera itself going off-axis and skewing him.
const FRAMING := {
	Formation.HERO: {
		"eye": Vector3(2.35, 1.70, 3.15),
		"look": Vector3(-1.05, 1.08, -0.10),
		"fov": 46.0,
	},
	Formation.RING: {
		"eye": Vector3(0.0, 2.95, 7.30),
		"look": Vector3(0.0, 1.62, 0.20),
		"fov": 44.0,
	},
}

## Torch flicker. Two detuned sines beat against each other so the period never
## quite repeats, which is what stops a flicker reading as a pulsing loop.
const FIRE_ENERGY := 5.2
const FIRE_FLICKER := 0.22

var _camera: Camera3D
var _fire: OmniLight3D
var _gub_root: Node3D
var _gubs: Array[Gub] = []
## `[{name, team}, ...]`, in the order they should stand.
var _roster: Array[Dictionary] = []
var _elapsed: float = 0.0


func _ready() -> void:
	_build_environment()
	_build_ground()
	_build_glade()
	_build_fire()

	_gub_root = Node3D.new()
	_gub_root.name = "Gubs"
	add_child(_gub_root)

	_build_camera()
	if _roster.is_empty():
		# Whoever is at the keyboard, so the menu is never an empty stage.
		set_roster([{"name": Settings.sanitized_player_name(), "team": MatchConfig.TEAM_NONE}])


func _process(delta: float) -> void:
	_elapsed += delta
	if _fire != null:
		var flicker := sin(_elapsed * 7.3) * 0.6 + sin(_elapsed * 11.9) * 0.4
		_fire.light_energy = FIRE_ENERGY * (1.0 + FIRE_FLICKER * flicker)


# ------------------------------------------------------------------- roster ---

## Show these players, in this order. Safe to call every time the roster
## changes: Gubs are pooled and repositioned rather than rebuilt, so joining a
## lobby shuffles everyone along instead of restarting eight animations.
func set_roster(entries: Array) -> void:
	_roster.clear()
	for entry: Variant in entries:
		if entry is Dictionary:
			_roster.append(entry)
	if _gub_root == null:
		return  # still pre-`_ready`; `_ready` will apply it
	_grow_pool(_roster.size())
	for i in _gubs.size():
		_apply_slot(i)


func _grow_pool(wanted: int) -> void:
	var target := clampi(wanted, 0, MatchConfig.MAX_PLAYERS)
	while _gubs.size() < target:
		_gubs.append(_make_gub(_gubs.size()))


func _make_gub(index: int) -> Gub:
	var gub := GUB_SCENE.instantiate() as Gub
	gub.name = "BackdropGub_%d" % index
	gub.peer_id = BACKDROP_PEER_BASE + index
	# Before `add_child`, always. Set it afterwards and the rig spends its
	# `_ready` believing it is the local player and makes its camera current --
	# the exact bug that had every client playing out of the wrong Gub's eyes.
	gub.set_multiplayer_authority(gub.peer_id)
	_gub_root.add_child(gub)
	# A remote Gub takes its whole pose from the replicated fields, and nobody
	# is going to replicate anything to these. `sync_grounded` in particular has
	# to be set by hand: left false, `GubAnimator` plays the Jump clip forever
	# and the lobby is a ring of Gubs frozen in mid-leap.
	gub.sync_grounded = true
	gub.sync_velocity = Vector3.ZERO
	# Stagger the idle cycles. Eight Gubs breathing in perfect lockstep is the
	# one thing that would give away that they are copies of each other.
	var animator := gub.get_node_or_null("AnimationTree") as GubAnimator
	if animator != null:
		animator.advance(randf() * 4.0)
	return gub


## Position, name and tint one pooled Gub, or hide it if the roster is shorter
## than the pool.
func _apply_slot(index: int) -> void:
	var gub := _gubs[index]
	if index >= _roster.size():
		gub.visible = false
		return
	gub.visible = true

	var entry := _roster[index]
	var spot := _slot_transform(index, _roster.size())
	gub.revive_at(spot)
	gub.sync_grounded = true

	var team: int = entry.get("team", MatchConfig.TEAM_NONE)
	gub.display_name = String(entry.get("name", "Gub"))
	gub.team = team
	var plate := gub.get_node_or_null("Nameplate") as Nameplate
	if plate != null:
		plate.set_display_name(gub.display_name)
		plate.set_team(team)


func _slot_transform(index: int, count: int) -> Transform3D:
	if formation == Formation.HERO or count <= 1:
		# One Gub stands just off the fire, turned a few degrees away from the
		# camera so the pose reads as three-quarter rather than as a mugshot.
		return Transform3D(Basis(Vector3.UP, deg_to_rad(163.0)), Vector3(0.0, 0.0, 0.0))

	# Fill the far arc, centred on the back of the ring. One Gub is at the
	# middle of the arc, two straddle it, and so on outward.
	var arc := deg_to_rad(ring_arc_degrees)
	var step := arc / float(count - 1)
	var angle := PI + (float(index) - float(count - 1) * 0.5) * step
	var spot := Vector3(sin(angle) * ring_radius, 0.0, cos(angle) * ring_radius)
	# Everyone faces the fire, then turns a little toward the camera so the
	# ring reads as a group of faces rather than a circle of shoulders.
	var yaw := Gub.yaw_towards(-spot) + deg_to_rad(sin(angle) * -22.0)
	return Transform3D(Basis(Vector3.UP, yaw), spot)


# --------------------------------------------------------------- the stage ---

func _build_camera() -> void:
	var view: Dictionary = FRAMING[formation]
	_camera = Camera3D.new()
	_camera.name = "BackdropCamera"
	_camera.fov = view["fov"]
	_camera.near = 0.05
	_camera.far = 220.0
	_camera.look_at_from_position(view["eye"], view["look"], Vector3.UP)
	add_child(_camera)
	# Claimed last and explicitly, so it wins over any rig that might have
	# made itself current on the way in.
	_camera.make_current()


func _build_environment() -> void:
	var env := WorldEnvironment.new()
	env.name = "Environment"
	# The arena's own environment, so the menu is lit by the same night the
	# match is (D-009) and retuning the sky retunes both.
	env.environment = load("res://resources/config/arena_env.tres")
	add_child(env)

	# The sky draws its moon at LIGHT0's direction, so this light *is* the moon.
	# Direction, colour and energy are the handoff values from D-009: fill only,
	# because the fire is the key light.
	var moon := DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.light_energy = 0.30
	moon.shadow_enabled = true
	moon.look_at_from_position(Vector3.ZERO, -Vector3(-0.42, 0.38, -0.82), Vector3.UP)
	add_child(moon)


func _build_ground() -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Ground"
	var disc := CylinderMesh.new()
	disc.top_radius = 26.0
	disc.bottom_radius = 26.0
	disc.height = 0.6
	disc.radial_segments = 48
	var mat := StandardMaterial3D.new()
	# Kept above the floor D-009 sets for terrain albedo; darker than this and
	# a Gub standing outside the firelight has nothing to be a silhouette
	# against.
	mat.albedo_color = Color(0.16, 0.19, 0.13)
	mat.roughness = 0.98
	disc.material = mat
	mesh.mesh = disc
	mesh.position.y = -0.3
	add_child(mesh)


## A seeded glade. Same generator shape as the island (D-007): a ring of canopy
## at the treeline, undergrowth inside it, and small dressing on the floor near
## the fire.
func _build_glade() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = glade_seed
	var props := Node3D.new()
	props.name = "Glade"
	add_child(props)

	# The treeline. Held back beyond the ring and thinned out toward the camera
	# so nothing grows in front of the Gubs.
	for i in 22:
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(9.0, 20.0)
		# `cos(angle)` is +1 straight at the camera; push those trees much
		# further out rather than deleting them, so the treeline still closes.
		distance += maxf(0.0, cos(angle)) * 7.0
		_place(props, CANOPY[rng.randi() % CANOPY.size()],
			Vector3(sin(angle) * distance, 0.0, cos(angle) * distance),
			rng.randf() * TAU, rng.randf_range(0.85, 1.35))

	for i in 26:
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(5.5, 15.0) + maxf(0.0, cos(angle)) * 3.0
		_place(props, UNDERGROWTH[rng.randi() % UNDERGROWTH.size()],
			Vector3(sin(angle) * distance, 0.0, cos(angle) * distance),
			rng.randf() * TAU, rng.randf_range(0.8, 1.4))

	for i in 30:
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(1.4, 7.0)
		_place(props, FLOOR_DRESSING[rng.randi() % FLOOR_DRESSING.size()],
			Vector3(sin(angle) * distance, 0.0, cos(angle) * distance),
			rng.randf() * TAU, rng.randf_range(0.7, 1.3))


func _place(parent: Node3D, model: String, spot: Vector3, yaw: float,
		scale_factor: float) -> void:
	var packed := load(KIT + model + ".gltf") as PackedScene
	if packed == null:
		return
	var node := packed.instantiate() as Node3D
	node.transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_factor), spot)
	parent.add_child(node)


## The campfire everyone is standing around: the key light, and the only warm
## thing on screen.
func _build_fire() -> void:
	var pit := Node3D.new()
	pit.name = "Fire"
	add_child(pit)

	for i in 5:
		var log_mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.13, 0.13, 0.95)
		var bark := StandardMaterial3D.new()
		bark.albedo_color = Color(0.10, 0.075, 0.055)
		bark.roughness = 1.0
		box.material = bark
		log_mesh.mesh = box
		log_mesh.transform = Transform3D(
			Basis(Vector3.UP, TAU * float(i) / 5.0) * Basis(Vector3.RIGHT, deg_to_rad(24.0)),
			Vector3(0.0, 0.14, 0.0))
		pit.add_child(log_mesh)

	# The flame itself is an unshaded emissive blob rather than particles: it is
	# 40 metres from anything the player will look at twice, and the glow pass
	# turns it into a believable fire for free.
	var flame := MeshInstance3D.new()
	var blob := SphereMesh.new()
	blob.radius = 0.30
	blob.height = 0.86
	var hot := StandardMaterial3D.new()
	hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot.albedo_color = Color(1.0, 0.62, 0.20)
	hot.emission_enabled = true
	hot.emission = Color(1.0, 0.58, 0.18)
	# Comfortably above the environment's 1.45 glow threshold, which was set
	# just over a torch-lit Gub so that only real light sources bloom.
	hot.emission_energy_multiplier = 4.0
	blob.material = hot
	flame.mesh = blob
	flame.position.y = 0.42
	pit.add_child(flame)

	_fire = OmniLight3D.new()
	_fire.light_color = Color(1.0, 0.63, 0.29)
	_fire.light_energy = FIRE_ENERGY
	_fire.omni_range = 17.0
	_fire.omni_attenuation = 1.4
	_fire.shadow_enabled = true
	# D-009: torch lights need roughly this to punch a halo through the
	# volumetric fog rather than lighting geometry and nothing else.
	_fire.light_volumetric_fog_energy = 2.0
	_fire.position = Vector3(0.0, 0.62, 0.0)
	pit.add_child(_fire)
