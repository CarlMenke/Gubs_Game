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

	# Close enough to judge, aimed down the middle of the corpse's path rather
	# than at where it starts: the impulse below sends it a couple of metres
	# along -Z, and from 10 m away (where this camera first sat) a 1.8 m Gub is
	# eighty pixels tall and "the mesh is following the capsules" cannot be
	# answered from the picture. At 6 m it was still only 200 px and the fix
	# pass could not tell a crumpled corpse from a slumped one; at 3.5 m a
	# settled corpse is about half the frame. The eye is also low — 1.2 m, near
	# the height of a standing Gub's own eyes — because the thing being judged
	# is a body on the ground, and looking down on it from 2 m flattens exactly
	# the sprawl that says "body" rather than "ball". Still a *fixed* camera on
	# purpose: a chase camera hides the drift a broken ragdoll shows.
	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(2.7, 1.2, 1.1), Vector3(0.0, 0.45, -1.3), Vector3.UP)
	cam.fov = 50.0
	add_child(cam)
	cam.make_current()

func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames == kill_frame and not _killed:
		_killed = true
		GubRagdoll.spawn_from(_gub, self, Vector3(0, 0.25, -1).normalized() * _impulse,
			"Spine1")
		# Freed, not just hidden: `--debug-collisions` keeps drawing a hidden
		# body's shapes, and a phantom 1.55 m standing capsule left at the
		# origin is the one thing that makes the ragdoll capsules hard to read.
		_gub.alive = false
		_gub.queue_free()

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
