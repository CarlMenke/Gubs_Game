extends Node3D
## Regression guard for the ragdoll. Development tool, not shipped.
##
## Drops a corpse, lets it land, and asserts it is still a corpse afterwards.
## This exists because the bug it caught was invisible: `preview_ragdoll` at 26
## ticks looked perfect while the same corpse was a scribble of metre-long
## sticks by tick 60. Anything that measures only the first half-second will
## certify a broken ragdoll as working — see D-013.
##
## The two numbers that matter:
##   spread  — the furthest any body sits from the corpse's centre. A settled
##             Gub is about 0.6 m. Anything past SPREAD_LIMIT is an explosion.
##   fastest — the quickest body. A settled corpse is under 1 m/s; a diverging
##             one reaches hundreds within a dozen ticks.
##
## Godot --path . --script tools/snapshot.gd -- res://tools/ragdoll_stability.tscn out.png 300

const GUB := preload("res://scenes/player/gub.tscn")

const SPREAD_LIMIT := 1.5
const SPEED_LIMIT := 40.0
## Ticks to let the corpse settle before judging it.
const SETTLE_BY := 150

var _gub: Gub
var _corpse: GubRagdoll
var _frames: int = 0
var _worst_spread: float = 0.0
var _worst_speed: float = 0.0
var _failed: bool = false


func _ready() -> void:
	_ground()
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 2.2
	add_child(key)

	_gub = GUB.instantiate()
	add_child(_gub)
	_gub.global_position = Vector3(0, 0.05, 0)
	_gub.set_multiplayer_authority(multiplayer.get_unique_id())
	(_gub.get_node("CameraRig") as Node3D).queue_free()
	(_gub.get_node("Nameplate") as Node3D).queue_free()

	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(3.2, 1.3, 3.2), Vector3(-0.2, 0.35, -0.2), Vector3.UP)
	cam.fov = 50.0
	add_child(cam)
	cam.make_current()


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames == 10:
		_corpse = GubRagdoll.spawn_from(_gub, self,
			Vector3(0, 0.25, -1).normalized() * 2.4, "spine.002")
		_gub.visible = false
		_gub.alive = false
		return
	if _corpse == null:
		return

	var sim := _corpse.get("_simulator") as PhysicalBoneSimulator3D
	if sim == null:
		return
	var bodies: Array[PhysicalBone3D] = []
	for child in sim.get_children():
		var pb := child as PhysicalBone3D
		if pb != null:
			bodies.append(pb)
	if bodies.is_empty():
		return

	var centre := Vector3.ZERO
	for pb in bodies:
		centre += pb.global_position
	centre /= bodies.size()

	var spread := 0.0
	var fastest := 0.0
	for pb in bodies:
		spread = maxf(spread, pb.global_position.distance_to(centre))
		fastest = maxf(fastest, pb.linear_velocity.length())
	_worst_spread = maxf(_worst_spread, spread)
	_worst_speed = maxf(_worst_speed, fastest)

	if not _failed and (spread > SPREAD_LIMIT or fastest > SPEED_LIMIT):
		_failed = true
		print("ragdoll_stability: FAIL at tick %d — spread %.2f m (limit %.2f), "
			% [_frames, spread, SPREAD_LIMIT]
			+ "fastest %.1f m/s (limit %.1f)" % [fastest, SPEED_LIMIT])

	if _frames == SETTLE_BY:
		print("ragdoll_stability: settled spread %.2f m, fastest %.2f m/s"
			% [spread, fastest])
		print("ragdoll_stability: peak spread %.2f m, peak speed %.1f m/s"
			% [_worst_spread, _worst_speed])
		print("ragdoll_stability: %s" % ("FAIL" if _failed else "PASS"))


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
	plane.material = mat
	mesh.mesh = plane
	body.add_child(mesh)
