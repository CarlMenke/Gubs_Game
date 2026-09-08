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
## Movement speeds here are gameplay choices, and the animation is made to fit
## them rather than the other way round. Each locomotion clip was authored at
## its own ground speed (`AUTHORED_*` below, measured out of the root motion the
## asset pipeline strips — see D-008), and `GubAnimator` plays each one back at
## `game speed / authored speed`, so the feet stay planted at whichever of these
## speeds the clip is assigned to. Change a speed here and the playback rate
## follows; there is no shared factor to keep in step any more.

signal died(killer_id: int, cause: int)
signal respawned()
signal landed(fall_speed: float)
signal jumped()
signal dived()
signal threw_spear(origin: Vector3, direction: Vector3)

enum Cause { SPEAR, FALL, VOID, UNKNOWN }

## The ground speed each locomotion clip was authored at, in metres per second,
## measured on the finished 1.80 m rig by `tools/build_gub.py` (hips travel over
## the cycle, divided by the cycle's *interval* count and not its frame count —
## a one-frame error there is a 1.3% skate). `GubAnimator` divides the game
## speeds below by these to get each clip's playback rate.
const AUTHORED_WALK := 1.079
const AUTHORED_RUN := 4.314
const AUTHORED_CROUCH_WALK := 1.273

## How fast the Gub actually moves. Chosen for how the game plays, not for what
## the clips were made at: walking is brisk, sprinting is nearly twice that, and
## crouching is slow enough that choosing it costs you something. Each of these
## is a blend point in the animator's locomotion space, so a Gub travelling at
## exactly one of them is running exactly one clip at a rate that plants its
## feet; in between, two cycles are blended.
const WALK_SPEED := 2.3
const RUN_SPEED := 5.4
const CROUCH_SPEED := 1.6

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

## The dive: jump again while already in the air and the Gub commits to a leap
## along whichever way it is trying to go. Once per airtime — that is what makes
## it a decision rather than free flight. The animator shows it with the
## `JumpTwo` clip, scrubbed by where the body is in its arc, and lands it with
## that clip's ground roll; see `GubAnimator`.
##
## The forward speed is deliberately well above RUN_SPEED: a dive that moved you
## no faster than running would be a worse way of running. Air friction is
## almost nothing (AIR_FRICTION 1.5), so this is very close to how fast the Gub
## is still travelling when it lands.
const DIVE_FORWARD_SPEED := 9.5
## Modest on purpose. The dive is meant to carry you *across* a gap, not over the
## treeline: at 24 m/s² this is 0.6 m of extra height on its own, and enough to
## keep the Gub in the air long enough for the leap to read.
const DIVE_UP_VELOCITY := 5.4

## A jump pressed this long after walking off an edge still counts.
const COYOTE_TIME := 0.12
## A jump pressed this long before landing fires on touchdown.
const JUMP_BUFFER := 0.14

## The slide. Its duration is set by the clip and not by taste: `Slide` puts the
## hips on the floor from 0.43 s and keeps them there until 1.13 s, so a slide
## the physics ends at 1.0 s ends while the body is still down, and the
## animator's fade-out lands on the clip's own stand-up. A slide that outlasted
## the low part of the clip would stand the Gub up and keep it sliding.
const SLIDE_SPEED := 4.0
const SLIDE_DURATION := 1.0
const SLIDE_FRICTION := 2.8
## Sliding has to be worth doing and worth stopping: you must already be moving
## near a run to enter one, and you cannot re-enter immediately.
const SLIDE_ENTRY_SPEED := RUN_SPEED * 0.7
const SLIDE_COOLDOWN := 0.9

## After landing from a dive the Gub is committed to its roll: movement input is
## ignored for this long, nothing but ROLL_FRICTION acts on the horizontal
## velocity, and jumping is refused but not lost (`_tick_timers` holds the
## buffered press until the lock ends) — so the body carries through the roll
## instead of skating across the floor in a tumbling pose. It is a gameplay rule
## as much as a cosmetic one: the dive is fast (DIVE_FORWARD_SPEED 9.5 m/s) and
## this is what it costs you at the far end. 0.45 s is a little under the 0.48 s
## of `JumpTwo` the animator plays as the roll, so control is back before the
## animation finishes rather than after it.
##
## It is a *ground* rule: the lock ends the moment the feet leave the floor
## (`_tick_timers`), so a Gub that rolls off a ledge gets its air control and
## AIR_FRICTION back at once instead of falling deaf to the stick with
## ROLL_FRICTION dragging on it.
##
## Set to 0.0 to turn the rule off completely: every use of it is guarded, so at
## zero the landing behaves exactly as it did before the rule existed.
const ROLL_LOCK := 0.45
## And only an airtime that lasted at least this long is rolled out of. The
## animator declines to play its roll one-shot below the same threshold —
## `GubAnimator.LAND_MIN_AIRTIME` *is* this constant — so without the guard here
## a dive that clipped the ground after a tenth of a second would take movement
## away for 0.45 s with no roll animation to explain it: the Gub would stand in
## a locomotion pose, deaf to the stick. One number, one rule, both sides.
const ROLL_MIN_AIRTIME := 0.20
## Deliberately much less than GROUND_FRICTION (42): the point is that the body
## keeps travelling.
const ROLL_FRICTION := 10.0

## The collision capsule follows the *pose the clips actually strike*, which is
## not the pose the word "crouch" suggests. Measured off silhouettes of the
## built asset: Idle stands 1.49 m (a hunched boxer's guard), CrouchWalk 1.51,
## Run 1.41 and Walk 1.73 — the new crouch is not lower than the new idle at
## all. So a 0.95 m crouch capsule, which is the right number for a character
## that folds up when it crouches, would leave the whole chest and head of this
## one outside its own hitbox: a crouching Gub could not be speared in the
## head. 1.35 m keeps everything but the antennae inside, and still sits 0.20 m
## below STAND_HEIGHT so crouching under an overhang works.
##
## The old asset had the same bug in a smaller size — 0.5 m of head outside its
## 0.95 m crouch capsule — which is why this is stated in metres of measured
## silhouette rather than as a fraction of standing height.
const STAND_HEIGHT := 1.55
const CROUCH_HEIGHT := 1.35
## The slide is the one pose that really is prone: `Slide` puts the hips at
## 0.17 m and keeps the body flat until ~0.95 s, and the whole mesh is under
## 0.73 m through it (measured). A sliding Gub is therefore genuinely a low
## target, and this is the height that says so. `_apply_capsule` rounds it up to
## 0.77 — a 0.38 m radius capsule cannot be shorter than its own two
## hemispheres — which is close enough to the pose that it is not worth
## narrowing the body for.
const SLIDE_HEIGHT := 0.75
const CAPSULE_RADIUS := 0.38
## Blend units per second, for both the crouch and the slide blend: a full
## stand-to-crouch takes 1/9 s either way.
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
## Bumped once per dive. A counter and not a flag, because a flag that goes true
## and false again inside one replication tick arrives as no change at all, and
## two dives in a row have to be two dives on every screen. `GubAnimator` watches
## it, so remote Gubs fire the dive from the same value their own client wrote.
@export var sync_dive_serial: int = 0
## Bumped once per ordinary jump, for the same reason and read the same way.
## Nothing has to *fire* on a jump — the animator scrubs the jump clip by where
## the body is in its arc, and leaving the ground with a positive vertical
## velocity is already the whole story — but the serial says which kind of
## airtime this is, which is what decides between the landing absorb and the
## dive roll. It also arrives on time when `sync_grounded` does not: a remote
## Gub whose grounded flag is a tick late still starts its airtime on the frame
## the jump happened.
@export var sync_jump_serial: int = 0

var display_name: String = "Gub"
## The spear in the Gub's hand. Hidden while one is in flight.
var held_spear: HeldSpear
var team: int = MatchConfig.TEAM_NONE
var alive: bool = true
## Set while the round is starting or just after a respawn; blocks damage.
var invulnerable_until: float = 0.0

## Movement intent for this frame. Filled from the keyboard in `_read_input`
## when this Gub is the local one, and set directly by the testbeds that script
## a Gub through a pose — see `reads_local_input`.
var input_direction: Vector2 = Vector2.ZERO
var wants_sprint: bool = false
var wants_crouch: bool = false
## False on a Gub whose movement is being driven by something other than the
## player: `tools/sandbox.gd` walks one through scripted poses for a snapshot,
## and reading an empty keyboard over the top of that would zero it every frame.
var reads_local_input: bool = true
var body_yaw: float = 0.0

var _coyote: float = 0.0
var _jump_buffered: float = 0.0
## Spent by the dive, returned by touching the ground.
var _air_jump_spent: bool = false
var _slide_time: float = 0.0
var _slide_cooldown: float = 0.0
## Counts down through the roll after a dive landing. See ROLL_LOCK.
var _roll_lock: float = 0.0
## How long the Gub has been off the ground, in seconds, reset on touchdown.
## Read by `_detect_landing` to decide whether an airtime was long enough to be
## worth rolling out of — see ROLL_MIN_AIRTIME.
var _airtime: float = 0.0
var _crouch_blend: float = 0.0
## How prone the body is, on top of the crouch blend. See `pose_height`.
var _slide_blend: float = 0.0
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
	# `is_multiplayer_authority()` asks the peer for its own id, and there is a
	# window every time a match ends where there is no peer to ask: leaving nulls
	# `multiplayer.multiplayer_peer` immediately, and `SceneFlow` then fades for
	# FADE_OUT seconds before the arena is freed. Every Gub still in the tree is
	# processed through those frames — this one, its animator and its combat all
	# ask — which is thirteen frames of engine errors on the way out of every
	# match. `Net.local_id` already guards the same call the same way.
	#
	# Nothing is locally controlled in a session that has ended, so the honest
	# answer is no: movement and input stop, and anything reading through
	# `is_grounded`/`is_sliding` falls back to the last synced values.
	if multiplayer.multiplayer_peer == null:
		return false
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

	_read_input()
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


# ------------------------------------------------------------------- input ---

## The keyboard half of a Gub. The mouse half lives in `GubCamera`, and the
## ability keys in `GubCombat`, which reads them exactly like this.
##
## This belongs on the Gub rather than on whatever scene is hosting it. It used
## to live only in `tools/combat_range.gd` and `tools/sandbox.gd`, which meant
## every testbed could be walked around and the actual game could not: the arena
## had nothing playing the part those two were playing, so `input_direction`
## stayed at zero for the whole match while the abilities — which do read their
## own keys — worked perfectly, and made it look like input was fine.
func _read_input() -> void:
	if not reads_local_input:
		return
	# Typing in chat, or reading the scoreboard, is not walking into a wall.
	if SceneFlow.cursor_is_free():
		input_direction = Vector2.ZERO
		wants_sprint = false
		wants_crouch = false
		return
	input_direction = Input.get_vector("move_left", "move_right",
		"move_forward", "move_back")
	wants_sprint = Input.is_action_pressed("sprint")
	wants_crouch = Input.is_action_pressed("crouch")
	if Input.is_action_just_pressed("jump"):
		request_jump()


# ------------------------------------------------------------------ motion ---

func _tick_timers(delta: float) -> void:
	if is_on_floor():
		_coyote = COYOTE_TIME
		_airtime = 0.0
	else:
		_coyote = maxf(0.0, _coyote - delta)
		_airtime += delta
	# Frozen rather than decayed while the roll lock is running. `_handle_jump`
	# refuses a jump during the roll and promises it fires on the frame the lock
	# ends; a 0.14 s buffer running inside a 0.45 s lock would always be empty
	# by then, so the promise was only true for a press made in the last 0.14 s
	# of the roll. Nothing else can consume the buffer meanwhile — the Gub is on
	# the floor, so `_coyote` is full and `_handle_jump` is the only reader.
	if not is_rolling():
		_jump_buffered = maxf(0.0, _jump_buffered - delta)
	_slide_cooldown = maxf(0.0, _slide_cooldown - delta)
	# The roll is a ground move. Leave the floor mid-roll — a dive that lands on
	# a ledge and carries over its edge — and the lock ends there, or the fall
	# would have no air control and ROLL_FRICTION instead of AIR_FRICTION.
	_roll_lock = maxf(0.0, _roll_lock - delta) if is_on_floor() else 0.0


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
	_slide_blend = move_toward(_slide_blend, 1.0 if is_sliding() else 0.0,
		CROUCH_TRANSITION * delta)
	_apply_capsule(pose_height())


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

	# Not while rolling out of a dive: a dive lands well above SLIDE_ENTRY_SPEED,
	# so without this a held crouch turns every dive landing into a slide, on top
	# of a roll that is already playing.
	var can_slide := wants_crouch and wants_sprint and is_on_floor() \
		and _slide_cooldown <= 0.0 and not is_rolling() \
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


## Vertical speed, in metres per second, for anything that reads the arc rather
## than simulating it — the animator scrubs both jump clips by this and records
## a dive's launch speed from it.
##
## Locally it is just `velocity.y`. On a remote Gub it is the replicated value
## and *not* the copy in `velocity`, which is one physics tick staler: the
## synchronizer applies an incoming packet during idle processing, in the same
## pass `GubAnimator._process` runs in, and `_follow_network` only copies
## `sync_velocity` into `velocity` on the next physics tick. On the one frame
## that matters — the frame a dive's serial arrives, when the launch speed is
## read once and used for the whole leap — reading `velocity` there gives the
## speed the body had *before* it dived.
func vertical_speed() -> float:
	return velocity.y if is_local() else sync_velocity.y


## True through the ROLL_LOCK window after landing from a dive. Local only —
## nothing on a remote Gub reads it, because a remote Gub is not simulated and
## its animator fires the roll off `sync_dive_serial` instead.
func is_rolling() -> bool:
	return _roll_lock > 0.0


func _handle_movement(delta: float) -> void:
	if is_sliding():
		return
	# Rolling out of a dive: the input is dropped and only a light friction acts,
	# so the body travels with the roll animation. Steering out of a tumble would
	# make the roll a free reposition rather than the price of the dive.
	if is_rolling():
		var rolling := Vector3(velocity.x, 0.0, velocity.z)
		rolling = rolling.move_toward(Vector3.ZERO, ROLL_FRICTION * delta)
		velocity.x = rolling.x
		velocity.z = rolling.z
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


## The speed this Gub is asking to travel at, which is also the animator's
## locomotion blend position when it gets there.
func target_speed() -> float:
	if is_crouching():
		return CROUCH_SPEED
	return RUN_SPEED if wants_sprint else WALK_SPEED


## One key, two moves. On the ground (or inside coyote time) this is an ordinary
## jump and goes through the buffer, so a press a frame early still fires on
## touchdown. Already airborne with the air jump unspent, it is the dive, and
## that has to happen *now* rather than being buffered — a dive that fired when
## you landed would be the opposite of what was asked for.
func request_jump() -> void:
	if _can_dive():
		_dive()
		return
	_jump_buffered = JUMP_BUFFER


## The dive is available once per airtime, and only from a real airtime:
## `_coyote` is still running for the twelfth of a second after walking off a
## ledge and is zeroed by a jump, so requiring it spent means the second press of
## a double-tap on flat ground jumps first and dives second, never dives twice.
func _can_dive() -> bool:
	if not alive or _air_jump_spent or is_lured():
		return false
	return not is_on_floor() and _coyote <= 0.0


func _dive() -> void:
	_air_jump_spent = true
	_jump_buffered = 0.0
	# Where you are asking to go, or where you are looking if you are asking for
	# nothing. A dive with no direction at all would be a very expensive hop.
	var direction := _wish_direction()
	if direction.length_squared() < 0.0001:
		direction = facing()
	velocity.x = direction.x * DIVE_FORWARD_SPEED
	velocity.z = direction.z * DIVE_FORWARD_SPEED
	# `maxf` and not `+=`: diving out of a fall should still lift, and a dive off
	# the top of a jump should not stack its way into orbit.
	velocity.y = maxf(velocity.y, 0.0) + DIVE_UP_VELOCITY
	sync_dive_serial += 1
	dived.emit()


func _handle_jump() -> void:
	if _jump_buffered <= 0.0 or _coyote <= 0.0:
		return
	if is_crouching() and not _has_headroom():
		return
	# Refused, not consumed: the buffer keeps running, so a jump pressed during
	# the roll fires on the frame the lock ends rather than being swallowed.
	if is_rolling():
		return
	_jump_buffered = 0.0
	_coyote = 0.0
	if is_sliding():
		_end_slide()
	velocity.y = JUMP_VELOCITY
	# Before the emit, so anything listening already sees the new value. The
	# animator does not use the signal — it is local-only — but it does watch
	# this counter, on every peer.
	sync_jump_serial += 1
	jumped.emit()


func _detect_landing(grounded_before: bool) -> void:
	var grounded_now := is_on_floor()
	if grounded_now and not grounded_before and _fall_speed > 3.0:
		landed.emit(_fall_speed)
	# A landing that ends an airtime the dive was spent in is a roll landing, and
	# `_air_jump_spent` is the only record of that — so it has to be read before
	# the line below gives the dive back. The airtime has to clear
	# ROLL_MIN_AIRTIME as well, because that is the same question the animator
	# asks before playing the roll, and the two have to answer it alike: a dive
	# into a wall two frames after take-off gets neither the lock nor the roll.
	if grounded_now and not grounded_before and _air_jump_spent \
			and _airtime >= ROLL_MIN_AIRTIME and ROLL_LOCK > 0.0:
		_roll_lock = ROLL_LOCK
	# Touching anything at all gives the dive back, including a ledge caught on
	# the way down. Tying it to `landed` instead would leave a Gub that stepped
	# gently off a rock unable to dive for the rest of the match.
	if grounded_now:
		_air_jump_spent = false
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


## The capsule height the two stance blends currently ask for. Two nested
## lerps and not one three-way blend: the crouch blend takes standing down to
## CROUCH_HEIGHT, and the slide blend takes whatever that produced down to
## SLIDE_HEIGHT. So a slide entered from a run (crouch blend still 0) and one
## entered from a crouch (crouch blend already 1) both end up prone, and both
## the way in and the way out are smooth — including the moment a slide ends
## with crouch still held, which is a 0.6 m change of target and would be a
## visible capsule pop if it were a switch instead of a blend.
func pose_height() -> float:
	return lerpf(lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch_blend),
		SLIDE_HEIGHT, _slide_blend)


func _has_headroom() -> bool:
	var space := get_world_3d().direct_space_state
	# Started at the middle of the capsule the body currently has, so the ray
	# always begins inside the Gub. Starting it at a fixed CROUCH_HEIGHT * 0.5
	# was the same point by accident and is not any more: while sliding the
	# capsule is only SLIDE_HEIGHT tall, and a start point above its top could
	# begin inside the very overhang it is asking about and report clear.
	var from := global_position + Vector3.UP * (pose_height() * 0.5)
	var query := PhysicsRayQueryParameters3D.create(
		from, global_position + Vector3.UP * (STAND_HEIGHT + 0.12))
	query.collision_mask = LAYER_WORLD | LAYER_DEPLOYABLE
	query.exclude = [get_rid()]
	return space.intersect_ray(query).is_empty()


## Height of the eyes, used to aim the camera and to spawn projectiles. It
## follows the same blend as the capsule, so the camera drops with the body
## through a crouch and lies down with it through a slide.
func eye_height() -> float:
	return pose_height() * 0.86


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
	# The same two blends the owner runs, off the replicated flags, so a remote
	# Gub is as hittable as the one whose screen it is being played on. The
	# combat range's dummies are remote Gubs.
	_slide_blend = move_toward(_slide_blend, 1.0 if sync_sliding else 0.0,
		CROUCH_TRANSITION * delta)
	_apply_capsule(pose_height())


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


## Spears that struck this Gub and are waiting for a corpse to be handed to.
## Each entry is `{"spear": Node3D, "bone": String}`. It is normally emptied
## within the same frame by `GubRagdoll`; anything still here at the next
## respawn belongs to a death that produced no corpse and is thrown away.
var _pending_spears: Array[Dictionary] = []


## Park a spear on this Gub until the corpse for this death exists.
func embed_spear(spear: Node3D, bone: String) -> void:
	_pending_spears.append({"spear": spear, "bone": bone})


## Hand every parked spear to the caller and forget them.
func take_embedded_spears() -> Array[Dictionary]:
	var taken := _pending_spears
	_pending_spears = []
	return taken


func _drop_pending_spears() -> void:
	for entry: Dictionary in _pending_spears:
		var spear: Node3D = entry["spear"]
		if is_instance_valid(spear):
			spear.queue_free()
	_pending_spears.clear()


func revive_at(spawn: Transform3D) -> void:
	_drop_pending_spears()
	alive = true
	velocity = Vector3.ZERO
	global_position = spawn.origin
	body_yaw = spawn.basis.get_euler().y
	_model_root.rotation.y = body_yaw
	_slide_time = 0.0
	_crouch_blend = 0.0
	_slide_blend = 0.0
	_lure_until = 0.0
	_air_jump_spent = false
	_jump_buffered = 0.0
	_airtime = 0.0
	_roll_lock = 0.0
	_apply_capsule(STAND_HEIGHT)
	# The replicated fields are seeded here, field by field, and deliberately
	# *not* by calling `_publish()`. `_publish` ends with
	# `sync_grounded = is_on_floor()`, which is only a true statement on the
	# peer that owns this Gub: a remote copy never calls `move_and_slide`, so
	# its `is_on_floor()` is permanently false. Worse, the value it writes never
	# changes afterwards — the owner was standing before it died and is standing
	# now, true to true — so ON_CHANGE replication has nothing to correct, and
	# every other client keeps the respawned Gub in the airborne pose for the
	# rest of the round. Spawn pads are on the ground, so this says so outright;
	# the owner's first real `_publish` follows one physics tick later.
	sync_position = spawn.origin
	sync_yaw = body_yaw
	sync_velocity = Vector3.ZERO
	sync_crouching = false
	sync_sliding = false
	sync_grounded = true
	respawned.emit()
