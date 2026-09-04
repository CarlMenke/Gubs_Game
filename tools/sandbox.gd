extends Node3D
## Playable testbed for the Gub: flat ground, a few obstacles, one player.
## Development tool, not shipped.
##
## Run it interactively to feel the movement:
##   Godot --path . tools/sandbox.tscn
##
## Or let it drive itself for a snapshot, which is how the camera framing and
## the animation blends get checked without a human at the keyboard:
##   Godot --path . --script tools/snapshot.gd -- res://tools/sandbox.tscn out.png 90 run

const GUB := preload("res://scenes/player/gub.tscn")

## Scripted inputs, so a snapshot can catch the Gub mid-stride rather than
## standing still. Keyed by the mode passed on the command line.
const DRIVES := {
	"idle": {},
	"walk": {"move_forward": true},
	"run": {"move_forward": true, "sprint": true},
	"crouch": {"move_forward": true, "crouch": true},
	"jump": {"move_forward": true, "sprint": true, "jump": true},
	"throw": {"move_forward": true, "sprint": true, "throw_spear": true},
}

var _gub: Gub
var _drive: Dictionary = {}
var _frames: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		_drive = DRIVES.get(args[3], {})

	_build_ground()
	_build_obstacles()
	_build_lighting()

	_gub = GUB.instantiate()
	_gub.name = "LocalGub"
	add_child(_gub)
	_gub.global_position = Vector3(0, 1.2, 6)
	_gub.set_multiplayer_authority(multiplayer.get_unique_id())
	_gub.display_name = "Sandbox"
	(_gub.get_node("Nameplate") as Nameplate).set_display_name("Sandbox")

	if _drive.is_empty():
		SceneFlow.recapture_cursor("sandbox")


func _physics_process(_delta: float) -> void:
	if _gub == null:
		return
	_frames += 1

	if not _drive.is_empty():
		# Feed the scripted inputs straight into the body, bypassing Input so
		# this works in a windowless-ish snapshot run.
		_gub.input_direction = Vector2(0, -1) if _drive.get("move_forward", false) else Vector2.ZERO
		_gub.wants_sprint = _drive.get("sprint", false)
		_gub.wants_crouch = _drive.get("crouch", false)
		if _drive.get("jump", false) and _frames % 48 == 0:
			_gub.request_jump()
		if _drive.get("throw_spear", false) and _frames == 20:
			(_gub.get_node("AnimationTree") as GubAnimator).play_throw()
		return

	_gub.input_direction = Input.get_vector("move_left", "move_right",
		"move_forward", "move_back")
	_gub.wants_sprint = Input.is_action_pressed("sprint")
	_gub.wants_crouch = Input.is_action_pressed("crouch")
	if Input.is_action_just_pressed("jump"):
		_gub.request_jump()
	if Input.is_action_just_pressed("throw_spear"):
		(_gub.get_node("AnimationTree") as GubAnimator).play_throw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		get_tree().quit()


# ------------------------------------------------------------------ stage ---

func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.14, 0.16, 0.13)
	mat.roughness = 0.95
	# A grid so speed and distance are actually legible in a still frame.
	mat.uv1_scale = Vector3(40, 40, 1)
	plane.material = mat
	mesh.mesh = plane
	body.add_child(mesh)


func _build_obstacles() -> void:
	var layout := [
		{"pos": Vector3(-4, 0.4, 0), "size": Vector3(3, 0.8, 3)},
		{"pos": Vector3(4.5, 0.9, -2), "size": Vector3(2, 1.8, 2)},
		{"pos": Vector3(0, 0.25, -6), "size": Vector3(10, 0.5, 2)},
		{"pos": Vector3(-8, 1.6, -8), "size": Vector3(4, 3.2, 4)},
	]
	for entry: Dictionary in layout:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.position = entry["pos"]
		add_child(body)

		var box := BoxShape3D.new()
		box.size = entry["size"]
		var shape := CollisionShape3D.new()
		shape.shape = box
		body.add_child(shape)

		var mesh := MeshInstance3D.new()
		var cube := BoxMesh.new()
		cube.size = entry["size"]
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.22, 0.24, 0.26)
		mat.roughness = 0.9
		cube.material = mat
		mesh.mesh = cube
		body.add_child(mesh)


func _build_lighting() -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-46, -40, 0)
	key.light_energy = 1.5
	key.shadow_enabled = true
	add_child(key)

	var env := WorldEnvironment.new()
	env.environment = load("res://resources/config/default_env.tres")
	add_child(env)
