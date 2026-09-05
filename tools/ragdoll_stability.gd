extends Node3D
## Regression guard for the ragdoll. Development tool, not shipped.
##
## Drops a corpse, lets it land, and asserts it is still a corpse afterwards.
## This exists because the bug it caught was invisible: `preview_ragdoll` at 26
## ticks looked perfect while the same corpse was a scribble of metre-long
## sticks by tick 60. Anything that measures only the first half-second will
## certify a broken ragdoll as working — see D-013.
##
## What it judges, and deliberately what it does not:
##
##   settled   — by SETTLE_BY the corpse must be a compact, still body: every
##               part within SPREAD_LIMIT of its centre and moving under
##               SETTLED_SPEED. This is the real test. A broken ragdoll never
##               arrives here.
##   runaway   — no body may ever exceed RUNAWAY_SPEED, which is far above
##               anything a spear can impart, so only a solver that is adding
##               energy can reach it.
##
## It does NOT bound the peak spread or speed during the tumble. A Gub killed by
## a 42 m/s spear is *supposed* to be thrown across the ground, and an earlier
## version of this file failed the fixed ragdoll for doing exactly that.
##
## Godot --path . --script tools/snapshot.gd -- res://tools/ragdoll_stability.tscn out.png 300

const GUB := preload("res://scenes/player/gub.tscn")

## Judged only once the corpse has had time to come to rest.
const SPREAD_LIMIT := 1.5
const SETTLED_SPEED := 1.5
## Judged every tick. A spear arrives at 42 m/s, so nothing legitimate comes
## close to this — reaching it means the solver is adding energy.
const RUNAWAY_SPEED := 120.0
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
		# A real spear velocity, not a token nudge: the corpse is thrown hard
		# now, and the joints have to survive being thrown hard and *then*
		# hitting the ground.
		_corpse = GubRagdoll.spawn_from(_gub, self,
			Vector3(0, -0.12, -1).normalized() * SpearProjectile.SPEED, "spine.002")
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

	if not _failed and fastest > RUNAWAY_SPEED:
		_failed = true
		print("ragdoll_stability: FAIL at tick %d — %.1f m/s exceeds the %.1f m/s "
			% [_frames, fastest, RUNAWAY_SPEED]
			+ "a spear could ever impart; the solver is adding energy")

	if _frames == SETTLE_BY:
		if spread > SPREAD_LIMIT:
			_failed = true
			print("ragdoll_stability: FAIL — still %.2f m across at rest (limit %.2f)"
				% [spread, SPREAD_LIMIT])
		if fastest > SETTLED_SPEED:
			_failed = true
			print("ragdoll_stability: FAIL — still moving at %.2f m/s (limit %.2f)"
				% [fastest, SETTLED_SPEED])
		print("ragdoll_stability: settled spread %.2f m, fastest %.2f m/s"
			% [spread, fastest])
		print("ragdoll_stability: peak spread %.2f m, peak speed %.1f m/s (not judged)"
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
