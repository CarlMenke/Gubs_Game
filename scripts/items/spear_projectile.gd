class_name SpearProjectile
extends Node3D
## A thrown spear. One hit anywhere is a kill.
##
## Every peer spawns and simulates its own copy from the same launch parameters.
## The flight is pure ballistics with no randomness, so all peers agree on where
## the spear is without a single position packet — the only thing that travels
## is the launch itself.
##
## Only the host's copy is `authoritative` and allowed to declare a kill. The
## others stop and stick at the same moment purely so the visual matches.
##
## This is a plain `Node3D` integrated by hand rather than a `RigidBody3D`. At
## 42 m/s a physics body covers 0.7 m per tick and tunnels straight through a
## Gub; stepping the flight and sweeping the segment between the old and new
## position is what makes an instant-kill weapon actually hit.

signal struck_gub(victim: Gub, point: Vector3, bone: String)
signal struck_world(point: Vector3, normal: Vector3)

const MODEL := preload("res://art/generated/spear.glb")

const SPEED := 42.0
## Spears drop, but at a third of world gravity. Enough that a long throw has to
## be led and arced — which is where the skill in the fight lives — without
## turning mid-range duels into mortar practice.
const DROP := 8.0
const MAX_LIFETIME := 6.0
## How long a spear stays stuck in the ground before fading out.
const STUCK_LINGER := 7.0
const STUCK_FADE := 1.2
## How far past the impact point the head sinks.
const BURY_DEPTH := 0.12

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_DEPLOYABLE := 8

var thrower_id: int = 0
var authoritative: bool = false

var _velocity: Vector3 = Vector3.ZERO
var _previous: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _stuck: bool = false
var _stuck_age: float = 0.0
var _model: Node3D
var _thrower: Gub


## Launch a spear. `direction` is expected to be normalised.
static func launch(parent: Node, thrower: Gub, origin: Vector3, direction: Vector3,
		is_authoritative: bool) -> SpearProjectile:
	var spear := SpearProjectile.new()
	spear.name = "Spear_%d_%d" % [thrower.peer_id, Time.get_ticks_msec()]
	spear.thrower_id = thrower.peer_id
	spear.authoritative = is_authoritative
	spear._thrower = thrower
	parent.add_child(spear)
	spear.global_position = origin
	spear._previous = origin
	spear._velocity = direction.normalized() * SPEED
	spear._face_travel()
	return spear


func _ready() -> void:
	_model = MODEL.instantiate() as Node3D
	# The mesh runs along its own +Y from butt to tip, but the projectile flies
	# along -Z like everything else in Godot, so the model is tipped forward and
	# slid back to put its point at the origin.
	_model.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_model.position = Vector3(0.0, 0.0, 0.62)
	add_child(_model)


func _physics_process(delta: float) -> void:
	if _stuck:
		_tick_stuck(delta)
		return

	_age += delta
	if _age > MAX_LIFETIME:
		queue_free()
		return

	_velocity.y -= DROP * delta
	_previous = global_position
	var next := global_position + _velocity * delta

	var hit := _sweep(_previous, next)
	if hit.is_empty():
		global_position = next
		_face_travel()
		return

	_resolve(hit)


## Sweep the segment the spear covered this tick. A ray rather than a shape cast:
## the spear is a stick, its tip is what matters, and a ray is both cheaper and
## easier to reason about than a swept capsule that can catch on its own length.
func _sweep(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = LAYER_WORLD | LAYER_PLAYER | LAYER_DEPLOYABLE
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# A Gub cannot spear itself on the way out of its own hand.
	if is_instance_valid(_thrower):
		query.exclude = [_thrower.get_rid()]
	return space.intersect_ray(query)


func _resolve(hit: Dictionary) -> void:
	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var collider: Object = hit["collider"]

	var victim := collider as Gub
	if victim != null:
		# Spawn protection makes a Gub solid but unkillable, so the spear passes
		# through rather than stopping short and looking like a miss.
		if victim.alive and not victim.is_invulnerable():
			struck_gub.emit(victim, point, _nearest_bone(victim, point))
			queue_free()
			return
		global_position = point
		return

	global_position = point
	_stick(normal)
	struck_world.emit(point, normal)


## Which bone the spear went through, so the ragdoll spins around the right
## place. Approximate on purpose — it drives a visual, not a damage number.
func _nearest_bone(victim: Gub, point: Vector3) -> String:
	var skeleton := victim.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		return "spine.002"
	var best := "spine.002"
	var best_distance := INF
	for segment: Dictionary in RagdollBuilder.SEGMENTS:
		var bone: int = skeleton.find_bone(segment["bone"])
		if bone < 0:
			continue
		var world := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
		var distance := world.origin.distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best = segment["bone"]
	return best


func _stick(normal: Vector3) -> void:
	_stuck = true
	set_process_priority(0)
	# Bury the head a little and let the shaft keep the angle it arrived at, so
	# a spear in the dirt reads as thrown rather than placed. The tip is at the
	# origin, so pushing *along* the flight direction sinks it into the surface.
	global_position += _velocity.normalized() * BURY_DEPTH
	_velocity = Vector3.ZERO
	if normal.length_squared() > 0.001:
		# A slight lean toward the surface normal stops spears from lying flush
		# against a wall.
		var lean := global_transform.basis.z.slerp(-normal, 0.18)
		if lean.length_squared() > 0.001:
			look_at(global_position - lean, Vector3.UP)


func _tick_stuck(delta: float) -> void:
	_stuck_age += delta
	if _stuck_age < STUCK_LINGER:
		return
	var fade := 1.0 - clampf((_stuck_age - STUCK_LINGER) / STUCK_FADE, 0.0, 1.0)
	if fade <= 0.0:
		queue_free()
		return
	if _model != null:
		_model.scale = Vector3.ONE * maxf(fade, 0.01)


func _face_travel() -> void:
	if _velocity.length_squared() < 0.001:
		return
	# look_at points -Z at the target, which is the direction of flight.
	look_at(global_position + _velocity, Vector3.UP)


## Where the spear is right now, for trails and audio.
func velocity() -> Vector3:
	return _velocity


func is_stuck() -> bool:
	return _stuck
