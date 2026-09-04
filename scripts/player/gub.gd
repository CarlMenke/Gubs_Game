class_name Gub
extends CharacterBody3D
## A player character.
##
## One of these exists per peer in a match. The peer it belongs to owns it:
## `set_multiplayer_authority(peer_id)` is called on spawn, that peer runs the
## movement code, and a `MultiplayerSynchronizer` pushes the result to everyone
## else (see docs/DECISIONS.md D-004). Remote Gubs run no input and no gravity —
## they only smooth toward what the network last said.
##
## Movement speeds are not arbitrary. They are the speeds the animation clips
## were *authored* at (recovered from the root motion the asset pipeline strips
## out — see D-008), multiplied by one shared factor. Getting this wrong is what
## makes feet skate, and it is invisible until you look for it.

signal died(killer_id: int, cause: int)
signal respawned()
signal landed(fall_speed: float)
signal jumped()
signal threw_spear(origin: Vector3, direction: Vector3)

enum Cause { SPEAR, FALL, VOID, UNKNOWN }

## Authored clip speeds, in metres per second, at the 0.35 import scale.
## Printed by `tools/decimate_assets.py`; see docs/DECISIONS.md D-008.
const AUTHORED_CROUCH_WALK := 1.21
const AUTHORED_JOG := 2.20
const AUTHORED_RUN := 4.01

## Everything is scaled up by this so the game plays at a lively pace, and the
## locomotion clips are played back at the same factor. Because both sides use
## the one number, the feet stay planted at any speed.
const SPEED_SCALE := 1.35

const CROUCH_SPEED := AUTHORED_CROUCH_WALK * SPEED_SCALE   # 1.63 m/s
const JOG_SPEED := AUTHORED_JOG * SPEED_SCALE              # 2.97 m/s
const RUN_SPEED := AUTHORED_RUN * SPEED_SCALE              # 5.41 m/s

## Gravity is 24 m/s² (project setting), which is deliberately about 2.4x real:
## it keeps jumps short and readable rather than floaty. 9.0 m/s of launch under
## that gravity is a 1.69 m apex — just under the Gub's own height.
const JUMP_VELOCITY := 9.0

const GROUND_ACCELERATION := 48.0
const GROUND_FRICTION := 42.0
## Air control is real but weak: enough to adjust a jump, not enough to make
## mid-air dodging the dominant way to avoid a spear.
const AIR_ACCELERATION := 12.0
const AIR_FRICTION := 1.5

## A jump pressed this long after walking off an edge still counts.
const COYOTE_TIME := 0.12
## A jump pressed this long before landing fires on touchdown.
const JUMP_BUFFER := 0.14

const SLIDE_SPEED := 3.00 * SPEED_SCALE
const SLIDE_DURATION := 0.85
const SLIDE_FRICTION := 3.2
## Sliding has to be worth doing and worth stopping: you must already be moving
## near a run to enter one, and you cannot re-enter immediately.
const SLIDE_ENTRY_SPEED := RUN_SPEED * 0.7
const SLIDE_COOLDOWN := 0.9

const STAND_HEIGHT := 1.55
const CROUCH_HEIGHT := 0.95
const CAPSULE_RADIUS := 0.38
const CROUCH_TRANSITION := 9.0

## How fast the body swings to face where it is going. Fast enough to feel
## responsive, slow enough that the turn reads as a turn.
const TURN_SPEED := 14.0

## Lure. Once caught, the Gub is dragged toward the crystal until it is inside
## LURE_GRIP metres, then pinned there for the rest of the hold. Jumping is
## blocked for the duration — the lure is meant to feel like being grabbed, and
## an escape hatch would make it never worth throwing.
const LURE_GRIP := 1.1
const LURE_MAX_SPEED := 11.0
const LURE_PIN_DAMP := 26.0

## Physics layers, from project.godot.
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_DEPLOYABLE := 8

@export var peer_id: int = 1

## Replicated state. The owning peer writes these; everyone else reads them.
@export var sync_position: Vector3
@export var sync_yaw: float
@export var sync_velocity: Vector3
@export var sync_crouching: bool
@export var sync_sliding: bool
@export var sync_grounded: bool

var display_name: String = "Gub"
## The spear in the Gub's hand. Hidden while one is in flight.
var held_spear: HeldSpear
var team: int = MatchConfig.TEAM_NONE
var alive: bool = true
## Set while the round is starting or just after a respawn; blocks damage.
var invulnerable_until: float = 0.0

var input_direction: Vector2 = Vector2.ZERO
var wants_sprint: bool = false
var wants_crouch: bool = false
var body_yaw: float = 0.0

var _coyote: float = 0.0
var _jump_buffered: float = 0.0
var _slide_time: float = 0.0
var _slide_cooldown: float = 0.0
var _crouch_blend: float = 0.0
var _was_grounded: bool = true
var _fall_speed: float = 0.0
## Set by the camera each frame; movement is relative to where you are looking.
var _view_basis: Basis = Basis.IDENTITY
## While aiming or throwing the body faces the camera instead of the direction
## of travel, so a thrown spear goes where the crosshair is.
var _face_view: bool = false

var _lure_centre: Vector3 = Vector3.ZERO
var _lure_strength: float = 0.0
var _lure_until: float = 0.0

@onready var _collision: CollisionShape3D = $Collision
@onready var _model_root: Node3D = $Model
@onready var _capsule: CapsuleShape3D = ($Collision as CollisionShape3D).shape as CapsuleShape3D


func _ready() -> void:
	collision_layer = LAYER_PLAYER
	collision_mask = LAYER_WORLD | LAYER_DEPLOYABLE
	floor_max_angle = deg_to_rad(52.0)
	floor_snap_length = 0.4
	# Slide along walls rather than sticking to them; a Gub that catches on
	# scenery during a fight feels broken even when it is technically correct.
	wall_min_slide_angle = deg_to_rad(12.0)

	add_to_group("gubs")
	body_yaw = rotation.y
	sync_position = global_position
	sync_yaw = body_yaw
	_apply_capsule(STAND_HEIGHT)
	_equip_spear()


func _equip_spear() -> void:
	var skeleton := _model_root.find_child("Skeleton3D", true, false) as Skeleton3D
	held_spear = HeldSpear.new()
	held_spear.name = "HeldSpear"
	add_child(held_spear)
	held_spear.attach_to(skeleton)


func is_local() -> bool:
	return is_multiplayer_authority()


## Called by the camera rig each frame so movement is relative to the view.
func set_view_basis(basis: Basis, face_view: bool) -> void:
	_view_basis = basis
	_face_view = face_view


func _physics_process(delta: float) -> void:
	if not is_local():
		_follow_network(delta)
		return
	if not alive:
		velocity = Vector3.ZERO
		_publish()
		return

	_tick_timers(delta)
	_apply_gravity(delta)
	_handle_slide(delta)
	_handle_crouch(delta)
	if is_lured():
		_handle_lure(delta)
	else:
		_handle_movement(delta)
		_handle_jump()

	var grounded_before := is_on_floor()
	_fall_speed = -velocity.y
	move_and_slide()
	_detect_landing(grounded_before)

	_face(delta)
	_publish()


# ------------------------------------------------------------------ motion ---

func _tick_timers(delta: float) -> void:
	if is_on_floor():
		_coyote = COYOTE_TIME
	else:
		_coyote = maxf(0.0, _coyote - delta)
	_jump_buffered = maxf(0.0, _jump_buffered - delta)
	_slide_cooldown = maxf(0.0, _slide_cooldown - delta)


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		return
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 24.0))
	# Falling faster than rising makes a jump feel decisive rather than floaty.
	if velocity.y < 0.0:
		gravity *= 1.35
	velocity.y -= gravity * delta
	velocity.y = maxf(velocity.y, -60.0)


func _handle_crouch(delta: float) -> void:
	var target := 1.0 if (wants_crouch or is_sliding()) and is_on_floor() else 0.0
	if target < 0.5 and _crouch_blend > 0.0 and not _has_headroom():
		target = 1.0  # something overhead; stay down
	_crouch_blend = move_toward(_crouch_blend, target, CROUCH_TRANSITION * delta)
	_apply_capsule(lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch_blend))


func _handle_slide(delta: float) -> void:
	if is_sliding():
		_slide_time -= delta
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		horizontal = horizontal.move_toward(Vector3.ZERO, SLIDE_FRICTION * delta)
		velocity.x = horizontal.x
		velocity.z = horizontal.z
		if _slide_time <= 0.0 or not is_on_floor() or horizontal.length() < 1.2:
			_end_slide()
		return

	var can_slide := wants_crouch and wants_sprint and is_on_floor() \
		and _slide_cooldown <= 0.0 \
		and Vector3(velocity.x, 0.0, velocity.z).length() >= SLIDE_ENTRY_SPEED
	if can_slide:
		_begin_slide()


func _begin_slide() -> void:
	_slide_time = SLIDE_DURATION
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if horizontal.length() > 0.01:
		# A slide commits to the direction you entered it in, at a fixed speed,
		# so it is a decision rather than a free speed boost.
		horizontal = horizontal.normalized() * maxf(horizontal.length(), SLIDE_SPEED)
		velocity.x = horizontal.x
		velocity.z = horizontal.z


func _end_slide() -> void:
	_slide_time = 0.0
	_slide_cooldown = SLIDE_COOLDOWN


## Remote Gubs never call `move_and_slide` and never run the slide timer, so on
## anything but the owning client these read the replicated flags instead. Left
## as `is_on_floor()` and `_slide_time`, a remote Gub is permanently airborne and
## never sliding, and the animator plays the Jump clip at everyone else forever.
func is_sliding() -> bool:
	return _slide_time > 0.0 if is_local() else sync_sliding


func is_grounded() -> bool:
	return is_on_floor() if is_local() else sync_grounded


func is_crouching() -> bool:
	return _crouch_blend > 0.5


func _handle_movement(delta: float) -> void:
	if is_sliding():
		return

	var wish := _wish_direction()
	var speed := target_speed()
	var accelerating := is_on_floor()
	var acceleration := GROUND_ACCELERATION if accelerating else AIR_ACCELERATION
	var friction := GROUND_FRICTION if accelerating else AIR_FRICTION

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if wish.length_squared() > 0.001:
		horizontal = horizontal.move_toward(wish * speed, acceleration * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, friction * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


## Called on the caught Gub's own client, because movement is client-authoritative
## and the host cannot simply move the body itself.
func apply_lure(centre: Vector3, strength: float, duration: float) -> void:
	_lure_centre = centre
	_lure_strength = strength
	_lure_until = Time.get_ticks_msec() * 0.001 + duration
	if is_sliding():
		_end_slide()


func is_lured() -> bool:
	return Time.get_ticks_msec() * 0.001 < _lure_until


func _handle_lure(delta: float) -> void:
	var to_centre := _lure_centre - (global_position + Vector3.UP * 0.6)
	var distance := to_centre.length()
	if distance > LURE_GRIP:
		velocity += to_centre.normalized() * _lure_strength * delta
		# Cap it, or a long pull accelerates the Gub into the crystal hard enough
		# to launch it off the far side of the island.
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		if horizontal.length() > LURE_MAX_SPEED:
			horizontal = horizontal.normalized() * LURE_MAX_SPEED
			velocity.x = horizontal.x
			velocity.z = horizontal.z
		return
	# Arrived: pinned until the hold expires.
	velocity.x = move_toward(velocity.x, 0.0, LURE_PIN_DAMP * delta)
	velocity.z = move_toward(velocity.z, 0.0, LURE_PIN_DAMP * delta)


func _wish_direction() -> Vector3:
	if input_direction.length_squared() < 0.0001:
		return Vector3.ZERO
	var forward := -_view_basis.z
	var right := _view_basis.x
	forward.y = 0.0
	right.y = 0.0
	var wish := (right * input_direction.x + forward * -input_direction.y)
	return wish.normalized() if wish.length_squared() > 0.0001 else Vector3.ZERO


func target_speed() -> float:
	if is_crouching():
		return CROUCH_SPEED
	return RUN_SPEED if wants_sprint else JOG_SPEED


func request_jump() -> void:
	_jump_buffered = JUMP_BUFFER


func _handle_jump() -> void:
	if _jump_buffered <= 0.0 or _coyote <= 0.0:
		return
	if is_crouching() and not _has_headroom():
		return
	_jump_buffered = 0.0
	_coyote = 0.0
	if is_sliding():
		_end_slide()
	velocity.y = JUMP_VELOCITY
	jumped.emit()


func _detect_landing(grounded_before: bool) -> void:
	var grounded_now := is_on_floor()
	if grounded_now and not grounded_before and _fall_speed > 3.0:
		landed.emit(_fall_speed)
	_was_grounded = grounded_now


func _face(delta: float) -> void:
	var desired := body_yaw
	if _face_view:
		desired = yaw_towards(-_view_basis.z)
	else:
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		if horizontal.length() > 0.35:
			desired = yaw_towards(horizontal)
	body_yaw = rotate_toward(body_yaw, desired, TURN_SPEED * delta)
	_model_root.rotation.y = body_yaw


## Yaw that points this node's forward (-Z, Godot's convention) along `direction`.
## The Gub mesh itself is authored facing +Z and is turned 180 degrees inside
## `gub.tscn` to compensate, so `body_yaw` always means "the way the Gub looks".
static func yaw_towards(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


## Unit vector the Gub is facing.
func facing() -> Vector3:
	return Vector3(-sin(body_yaw), 0.0, -cos(body_yaw))


# ------------------------------------------------------------------ shape ---

func _apply_capsule(height: float) -> void:
	# CapsuleShape3D.height is the full height including both hemispheres, and
	# the shape is centred on its origin, so it has to be lifted by half.
	_capsule.height = maxf(height, CAPSULE_RADIUS * 2.0 + 0.01)
	_capsule.radius = CAPSULE_RADIUS
	_collision.position.y = _capsule.height * 0.5


func _has_headroom() -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * (CROUCH_HEIGHT * 0.5)
	var query := PhysicsRayQueryParameters3D.create(
		from, global_position + Vector3.UP * (STAND_HEIGHT + 0.12))
	query.collision_mask = LAYER_WORLD | LAYER_DEPLOYABLE
	query.exclude = [get_rid()]
	return space.intersect_ray(query).is_empty()


## Height of the eyes, used to aim the camera and to spawn projectiles.
func eye_height() -> float:
	return lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch_blend) * 0.86


# --------------------------------------------------------------- networking ---

func _publish() -> void:
	sync_position = global_position
	sync_yaw = body_yaw
	sync_velocity = velocity
	sync_crouching = is_crouching()
	sync_sliding = is_sliding()
	sync_grounded = is_on_floor()


## Remote Gubs are not simulated — running physics for them would fight the
## authoritative position and produce jitter. They are eased toward what the
## network last reported, fast enough to stay honest and slow enough to hide
## packet spacing.
func _follow_network(delta: float) -> void:
	var distance := global_position.distance_to(sync_position)
	if distance > 6.0:
		# Too far to smooth: a teleport, a respawn, or a dropped burst.
		global_position = sync_position
	else:
		global_position = global_position.lerp(sync_position, clampf(18.0 * delta, 0.0, 1.0))
	velocity = sync_velocity
	body_yaw = rotate_toward(body_yaw, sync_yaw, TURN_SPEED * delta)
	_model_root.rotation.y = body_yaw
	_crouch_blend = move_toward(_crouch_blend, 1.0 if sync_crouching else 0.0,
		CROUCH_TRANSITION * delta)
	_apply_capsule(lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch_blend))


# ------------------------------------------------------------ life & death ---

func is_invulnerable() -> bool:
	return Time.get_ticks_msec() * 0.001 < invulnerable_until


func grant_invulnerability(seconds: float) -> void:
	invulnerable_until = Time.get_ticks_msec() * 0.001 + seconds


## Server-side. Kills this Gub and tells everyone.
func kill(killer_id: int, cause: Cause = Cause.UNKNOWN) -> void:
	if not alive:
		return
	alive = false
	velocity = Vector3.ZERO
	died.emit(killer_id, cause)


func revive_at(spawn: Transform3D) -> void:
	alive = true
	velocity = Vector3.ZERO
	global_position = spawn.origin
	body_yaw = spawn.basis.get_euler().y
	_model_root.rotation.y = body_yaw
	_slide_time = 0.0
	_crouch_blend = 0.0
	_lure_until = 0.0
	_apply_capsule(STAND_HEIGHT)
	_publish()
	respawned.emit()
