extends Node3D
## Fixed-camera ragdoll test: a Gub is killed on a known frame and the corpse is
## watched from the side, which is the only way to tell a good tumble from a
## broken one. Development tool, not shipped.
##
## Godot --path . --script tools/snapshot.gd -- res://tools/preview_ragdoll.tscn out.png <frame> [impulse]

const GUB := preload("res://scenes/player/gub.tscn")

@export var kill_frame: int = 20

var _gub: Gub
var _frames: int = 0
var _impulse: float = 2.4
var _killed: bool = false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		_impulse = float(args[3])

	_ground()
	_lights()

	_gub = GUB.instantiate()
	add_child(_gub)
	_gub.global_position = Vector3(0, 0.05, 0)
	_gub.set_multiplayer_authority(multiplayer.get_unique_id())
	# The rig's camera would take over the viewport; this preview supplies its own.
	(_gub.get_node("CameraRig") as Node3D).queue_free()
	(_gub.get_node("Nameplate") as Node3D).queue_free()

	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(6.5, 2.6, 6.5), Vector3(-0.6, 0.5, -0.6), Vector3.UP)
	cam.fov = 50.0
	add_child(cam)
	cam.make_current()

func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames == kill_frame and not _killed:
		_killed = true
		GubRagdoll.spawn_from(_gub, self, Vector3(0, 0.25, -1).normalized() * _impulse,
			"spine.002")
		_gub.visible = false
		_gub.alive = false

func _ground() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	add_child(body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.13, 0.15, 0.14)
	mat.roughness = 0.95
	plane.material = mat
	mesh.mesh = plane
	body.add_child(mesh)

func _lights() -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 2.2
	key.shadow_enabled = true
	add_child(key)
	var env := WorldEnvironment.new()
	env.environment = load("res://resources/config/default_env.tres")
	add_child(env)
