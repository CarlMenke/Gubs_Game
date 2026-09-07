class_name GubCombat
extends Node
## The three things a Gub can do to another Gub: throw a spear, plant a mushroom
## to hide behind, and lob a lure that drags people out from behind theirs.
##
## Authority split (docs/DECISIONS.md D-004): the owning client decides *when* it
## wants to act and plays its own feedback immediately, but the host decides
## whether the action actually happens. A client that lies about its cooldown
## gets its request dropped — the host keeps its own timers and is the only one
## that broadcasts.
##
## Which is why **this node belongs to the host and not to the Gub around it**.
## `MatchState._create_gub` hands the Gub to its owner and then hands this one
## child back to peer 1, because the `_do_*` broadcasts below are sent by the
## host and Godot checks an `@rpc("authority")` against whoever owns the node it
## arrives at. The `_request_*` calls go the other way and are `any_peer` with a
## sender check, so the owner can still ask. See D-024.
##
## Cooldowns are therefore tracked twice on purpose. The local copy exists so the
## HUD can show a sweeping timer without waiting for a round trip; the host's
## copy is the one that counts.
##
## The spear is the one ability that does *not* happen on the click. A click
## starts the windup animation; the spear leaves the hand THROW_RELEASE_TIME
## later, and the aim is read at that moment rather than at the click, so a
## target that moves while you wind up has to be led. See D-025.

signal cooldowns_changed()

const SPEAR := preload("res://scripts/items/spear_projectile.gd")
const MUSHROOM := preload("res://scenes/items/shield_mushroom.tscn")
const LURE := preload("res://scenes/items/lure.tscn")

## How long after the click the spear actually leaves the hand.
##
## Measured off the clip rather than guessed. `SpearThrow` is 1.53 s, and
## tracking the `hand.R` bone against the spine through it says: the arm draws
## back until 0.39 s, whips up over the shoulder to its highest at 0.54 s,
## crosses in front of the body at 0.55 s and reaches furthest forward at
## 0.60 s. A thrown object separates at peak forward hand speed, which is the
## 0.54-0.60 s stretch, so the spear goes at 0.57 s — by 0.60 the hand is
## already decelerating and the throw would read as a push.
##
## The throw OneShot's 0.10 s fade-in needs no allowance on top: the clip barely
## moves for its first 0.21 s, so the blend is long finished before anything the
## eye is following depends on it.
const THROW_RELEASE_TIME := 0.57

## Where the throw leaves the hand, relative to the Gub. The spear is aimed at
## whatever the crosshair is over, not simply pushed along the camera's forward
## axis, so what you point at is what you hit even up close.
const THROW_OFFSET := Vector3(0.34, 0.0, 0.0)
## Anything nearer than this is treated as "straight ahead"; without it, aiming
## at a wall a metre away would make the Gub throw at its own feet.
const MIN_AIM_DISTANCE := 3.0
const MAX_AIM_DISTANCE := 220.0

## How far in front the mushroom is planted.
const MUSHROOM_DISTANCE := 2.1

## Launch speed of the lure. With LURE_GRAVITY this sets the furthest it can be
## thrown at all — `s^2 / g`, about 22 m on the flat, which is a deliberate
## limit: the lure is a tool for pulling someone out of nearby cover, not for
## reaching across the island.
const LURE_SPEED := 22.0
## Must match `Lure.GRAVITY`, which integrates the flight. The arc is solved
## here and flown there, so if these disagree the lure lands somewhere other
## than where the thrower aimed.
const LURE_GRAVITY := 22.0

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_DEPLOYABLE := 8

var _gub: Gub
var _config: MatchConfig

## Local, predictive. Drives the HUD.
var _spear_ready_at: float = 0.0
var _mushroom_ready_at: float = 0.0
var _lure_ready_at: float = 0.0

## Host-side, authoritative. Never trusted from the wire.
var _server_spear_ready_at: float = 0.0
var _server_mushroom_ready_at: float = 0.0
var _server_lure_ready_at: float = 0.0

var _active_mushrooms: Array[Node] = []

## The ring on the ground while aiming. Local, cosmetic, and made on first use
## rather than in `_ready`, because seven of every eight Gubs in a match are
## somebody else's and must never build one.
var _aim_marker: AimMarker = null

## When the spear currently being wound up leaves the hand, or 0 for "no throw
## in progress". Only ever set on the throwing client: the host is told about
## the throw when it happens, not while it is being aimed.
var _windup_release_at: float = 0.0


func _ready() -> void:
	_gub = get_parent() as Gub
	if _gub == null:
		push_error("GubCombat expects to be a child of a Gub")
		return
	_config = Net.config


func _now() -> float:
	return Time.get_ticks_msec() * 0.001


# -------------------------------------------------------------------- input ---

func _process(_delta: float) -> void:
	if _gub == null:
		return
	# Before the guards below, not after: a Gub that dies or is respawned in the
	# middle of a windup has a throw to *cancel*, and the guards are exactly the
	# conditions under which it has to be cancelled.
	_tick_windup()
	if not _gub.is_local() or not _gub.alive:
		_stow_aim_marker()
		return
	if SceneFlow.cursor_is_free():
		_stow_aim_marker()
		return
	_tick_aim_marker()
	if Input.is_action_just_pressed("throw_spear"):
		try_throw_spear()
	if Input.is_action_just_pressed("place_mushroom"):
		try_place_mushroom()
	if Input.is_action_just_pressed("throw_lure"):
		try_throw_lure()


func spear_cooldown() -> float:
	return maxf(0.0, _spear_ready_at - _now())


func mushroom_cooldown() -> float:
	return maxf(0.0, _mushroom_ready_at - _now())


func lure_cooldown() -> float:
	return maxf(0.0, _lure_ready_at - _now())


func has_spear() -> bool:
	return spear_cooldown() <= 0.0


## The whole spear cycle: the windup you have already committed to, plus the
## recharge that follows it. The HUD divides by this rather than by the recharge
## alone, so the ring sweeps from the click instead of sitting full through the
## windup and then jumping down when the spear finally goes.
func spear_cycle() -> float:
	return THROW_RELEASE_TIME + _config.spear_recharge


## True between the click and the release. The held spear is still in the hand
## through this window, which is the point of it.
func is_winding_up() -> bool:
	return _windup_release_at > 0.0


# ------------------------------------------------------------------- aiming ---

## The point the crosshair is over, or a point far along the view ray if it is
## over nothing. This is what makes a throw land where the reticle is instead of
## parallel to it.
func _aim_point() -> Vector3:
	var rig := _gub.get_node_or_null("CameraRig") as GubCamera
	if rig == null:
		return _gub.global_position + _gub.facing() * 30.0
	var ray := rig.aim_ray()
	var origin: Vector3 = ray["origin"]
	var direction: Vector3 = ray["direction"]

	var space := _gub.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction * MAX_AIM_DISTANCE)
	query.collision_mask = LAYER_WORLD | LAYER_PLAYER | LAYER_DEPLOYABLE
	query.exclude = [_gub.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return origin + direction * MAX_AIM_DISTANCE
	var point: Vector3 = hit["position"]
	if origin.distance_to(point) < MIN_AIM_DISTANCE:
		return origin + direction * MIN_AIM_DISTANCE
	return point


func _throw_origin() -> Vector3:
	var basis := Basis(Vector3.UP, _gub.body_yaw)
	return _gub.global_position + Vector3.UP * _gub.eye_height() \
		+ basis * THROW_OFFSET


# ------------------------------------------------------- the drop indicator ---

## Keep the landing ring in step with where the Gub is pointing.
##
## Only while aiming, and only with a spear to throw — including the half second
## you are winding one up, because through the windup the aim is still live and
## is exactly what the release is about to read. A ring under an empty hand
## would be a promise the cooldown is not keeping.
##
## Deliberately gated on the aim button rather than shown all the time. Spears
## drop, and judging that drop is where a lot of the skill in the fight lives
## (D-014, D-025); a marker on screen at all times turns the throw from a thing
## you read into a thing you line up. Holding the button is the price of the
## answer, and it costs you the wider field of view while you ask.
func _tick_aim_marker() -> void:
	var rig := _gub.get_node_or_null("CameraRig") as GubCamera
	if rig == null or not rig.is_aiming() or not (has_spear() or is_winding_up()):
		_stow_aim_marker()
		return
	if _aim_marker == null:
		_aim_marker = AimMarker.new()
		_aim_marker.name = "AimMarker"
		# Hung off the Gub so it is freed with it and hidden with it, but the
		# marker is `top_level`, so the body walking and turning underneath does
		# not drag the ring around with it.
		_gub.add_child(_aim_marker)

	# The same two calls the release makes, in the same order, so the ring is
	# answering the question the throw is actually going to be asked.
	var origin := _throw_origin()
	var direction := (_aim_point() - origin).normalized()
	if direction.length_squared() < 0.001:
		_stow_aim_marker()
		return
	_aim_marker.aim(origin, direction, _gub.get_rid())


func _stow_aim_marker() -> void:
	if _aim_marker != null:
		_aim_marker.stow()


# ------------------------------------------------------------------- spear ---

## A click starts the throw; it does not make it. The arm goes back now and the
## spear leaves the hand THROW_RELEASE_TIME later, at which point the aim is
## sampled and the host is asked. Nothing about *where* the spear goes is
## decided here, which is the whole change: a target that walks during your
## windup has to be led.
func try_throw_spear() -> void:
	if spear_cooldown() > 0.0 or is_winding_up():
		return

	_windup_release_at = _now() + THROW_RELEASE_TIME
	# The input has been spent whether or not the spear has left yet, so the ring
	# starts sweeping on the click. A crosshair that sits ready through half a
	# second of windup only invites the second click that will be refused.
	_spear_ready_at = _now() + spear_cycle()
	cooldowns_changed.emit()

	# Everyone else has to see the arm come back too, or the windup is a tell
	# only the thrower gets. The thrower plays it here and the host relays it to
	# the rest, because a client cannot address the other peers itself (D-024).
	_play_windup()
	if Net.is_host:
		_host_throw_windup()
	else:
		_request_throw_windup.rpc_id(1)


## The release. Runs on the throwing client only, THROW_RELEASE_TIME after the
## click, and is the first moment anything about the aim is read.
func _tick_windup() -> void:
	if _windup_release_at <= 0.0:
		return
	# Dead, respawned, or no longer ours: the throw is off. The windup animation
	# is already playing and is left alone — it is cosmetic and fades out on its
	# own — but no spear comes out of it.
	if not _gub.alive or not _gub.is_local():
		_windup_release_at = 0.0
		return
	if _now() < _windup_release_at:
		return
	_windup_release_at = 0.0

	var origin := _throw_origin()
	var direction := (_aim_point() - origin).normalized()
	if direction.length_squared() < 0.001:
		return
	if Net.is_host:
		_host_throw_spear(origin, direction)
	else:
		_request_throw_spear.rpc_id(1, origin, direction)


func _play_windup() -> void:
	var animator := _gub.get_node_or_null("AnimationTree") as GubAnimator
	if animator != null:
		animator.play_throw()


@rpc("any_peer", "call_remote", "reliable")
func _request_throw_windup() -> void:
	if not Net.is_host or multiplayer.get_remote_sender_id() != _gub.peer_id:
		return
	_host_throw_windup()


## Deliberately not gated on the host's cooldown. This is a cosmetic tell, and
## refusing it would only hide the wind-up from everyone while the throw that
## follows is checked properly anyway; a Gub that winds up and produces no spear
## is a truthful picture of a client that asked for a throw it could not have.
func _host_throw_windup() -> void:
	if not _gub.alive:
		return
	_do_throw_windup.rpc()
	_do_throw_windup()


@rpc("authority", "call_remote", "reliable")
func _do_throw_windup() -> void:
	# The thrower already played this on its own click. Playing it again when the
	# host's relay lands would restart the arm half a round trip in and leave the
	# animation running behind the spear it is supposed to be launching.
	if _gub == null or _gub.is_local():
		return
	_play_windup()


@rpc("any_peer", "call_remote", "reliable")
func _request_throw_spear(origin: Vector3, direction: Vector3) -> void:
	if not Net.is_host or multiplayer.get_remote_sender_id() != _gub.peer_id:
		return
	_host_throw_spear(origin, direction)


func _host_throw_spear(origin: Vector3, direction: Vector3) -> void:
	if not _gub.alive or _now() < _server_spear_ready_at:
		return
	# The client picks the aim, but not the spawn point: clamping the origin to
	# somewhere near the Gub stops a modified client throwing from across the map.
	if origin.distance_to(_gub.global_position) > 3.0:
		origin = _throw_origin()
	_server_spear_ready_at = _now() + _config.spear_recharge
	_do_throw_spear.rpc(origin, direction.normalized())
	_do_throw_spear(origin, direction.normalized())


## The release, on every machine. No `play_throw()` here any more: the windup
## started the animation THROW_RELEASE_TIME ago on every peer and firing the
## OneShot again would snap the arm back to the start of the throw at the exact
## moment the spear leaves it.
@rpc("authority", "call_remote", "reliable")
func _do_throw_spear(origin: Vector3, direction: Vector3) -> void:
	_spear_ready_at = _now() + _config.spear_recharge
	cooldowns_changed.emit()

	if _gub.held_spear != null:
		_gub.held_spear.set_carried(false)
		_regrow_spear()

	AudioDirector.play_3d_varied(AudioDirector.SPEAR_THROW, origin)
	var spear := SPEAR.launch(_spawn_root(), _gub, origin, direction, Net.is_host)
	spear.struck_gub.connect(_on_spear_struck_gub.bind(spear))
	_gub.threw_spear.emit(origin, direction)


## The spear grows back in the hand when the cooldown ends. An empty hand is how
## other players read that you are harmless, so the timing has to be honest.
func _regrow_spear() -> void:
	await get_tree().create_timer(_config.spear_recharge).timeout
	if is_instance_valid(_gub) and _gub.held_spear != null:
		_gub.held_spear.set_carried(true)
		cooldowns_changed.emit()
		# Only the Gub whose hand it is needs to hear this — it is a readiness
		# cue for the player, not an event in the world that gives your
		# position away to everyone nearby.
		if _gub.is_local():
			AudioDirector.play_2d(AudioDirector.SPEAR_READY)


func _on_spear_struck_gub(victim: Gub, point: Vector3, bone: String,
		spear: SpearProjectile) -> void:
	# Only the host's copy of a spear is allowed to decide anything.
	if not spear.authoritative or not Net.is_host:
		return
	# The full velocity, not a direction: its magnitude is what makes the corpse
	# fly rather than sag, and a spear that has dropped out of a long arc should
	# shove one much less than a flat throw from close range.
	MatchState.report_kill(victim.peer_id, _gub.peer_id, Gub.Cause.SPEAR,
		point, spear.impact_velocity(), bone)


# ---------------------------------------------------------------- mushroom ---

func try_place_mushroom() -> void:
	if mushroom_cooldown() > 0.0:
		return
	_mushroom_ready_at = _now() + _config.mushroom_cooldown
	cooldowns_changed.emit()
	if Net.is_host:
		_host_place_mushroom()
	else:
		_request_mushroom.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _request_mushroom() -> void:
	if not Net.is_host or multiplayer.get_remote_sender_id() != _gub.peer_id:
		return
	_host_place_mushroom()


func _host_place_mushroom() -> void:
	if not _gub.alive or _now() < _server_mushroom_ready_at:
		return
	var spot := _mushroom_spot()
	if spot == Vector3.INF:
		return
	_server_mushroom_ready_at = _now() + _config.mushroom_cooldown
	_do_place_mushroom.rpc(spot, _gub.body_yaw)
	_do_place_mushroom(spot, _gub.body_yaw)


## Find the ground just in front of the Gub. Returns `Vector3.INF` when there is
## nowhere sensible — at a cliff edge, or with a wall in the way — so that a
## mushroom is never planted in mid-air over the void.
func _mushroom_spot() -> Vector3:
	var space := _gub.get_world_3d().direct_space_state
	var ahead := _gub.global_position + _gub.facing() * MUSHROOM_DISTANCE \
		+ Vector3.UP * 0.9

	var blocked := PhysicsRayQueryParameters3D.create(
		_gub.global_position + Vector3.UP * 0.9, ahead)
	blocked.collision_mask = LAYER_WORLD | LAYER_DEPLOYABLE
	blocked.exclude = [_gub.get_rid()]
	if not space.intersect_ray(blocked).is_empty():
		return Vector3.INF

	var down := PhysicsRayQueryParameters3D.create(ahead, ahead + Vector3.DOWN * 3.5)
	down.collision_mask = LAYER_WORLD
	var ground := space.intersect_ray(down)
	if ground.is_empty():
		return Vector3.INF
	return ground["position"]


@rpc("authority", "call_remote", "reliable")
func _do_place_mushroom(spot: Vector3, yaw: float) -> void:
	_mushroom_ready_at = _now() + _config.mushroom_cooldown
	cooldowns_changed.emit()

	_prune_mushrooms()
	# Planting past the cap retires your oldest, rather than refusing — a
	# refused ability with a spent cooldown is the most annoying outcome.
	while _active_mushrooms.size() >= _config.mushroom_max_active:
		var oldest: Node = _active_mushrooms.pop_front()
		if is_instance_valid(oldest):
			oldest.call("wither")

	var mushroom := MUSHROOM.instantiate()
	_spawn_root().add_child(mushroom)
	mushroom.call("plant", spot, yaw, _config.mushroom_lifetime, _gub.peer_id)
	_active_mushrooms.append(mushroom)


func _prune_mushrooms() -> void:
	_active_mushrooms = _active_mushrooms.filter(func(m): return is_instance_valid(m))


# -------------------------------------------------------------------- lure ---

## The lure is thrown at a *point*, not along a direction, because it is slow
## enough for gravity to matter: fired flat at the crosshair it dropped after
## about five metres regardless of where you were aiming, which made it
## impossible to place. The host solves the arc that actually lands on the aim
## point — see `_lob_velocity`.
func try_throw_lure() -> void:
	if lure_cooldown() > 0.0:
		return
	var origin := _throw_origin()
	var target := _aim_point()
	_lure_ready_at = _now() + _config.lure_cooldown
	cooldowns_changed.emit()
	if Net.is_host:
		_host_throw_lure(origin, target)
	else:
		_request_lure.rpc_id(1, origin, target)


@rpc("any_peer", "call_remote", "reliable")
func _request_lure(origin: Vector3, target: Vector3) -> void:
	if not Net.is_host or multiplayer.get_remote_sender_id() != _gub.peer_id:
		return
	_host_throw_lure(origin, target)


func _host_throw_lure(origin: Vector3, target: Vector3) -> void:
	if not _gub.alive or _now() < _server_lure_ready_at:
		return
	if origin.distance_to(_gub.global_position) > 3.0:
		origin = _throw_origin()
	_server_lure_ready_at = _now() + _config.lure_cooldown
	# The client chooses a point; the host chooses the velocity. Sending a
	# velocity over the wire instead would let a modified client fling a lure at
	# any speed it liked.
	var velocity := _lob_velocity(origin, target)
	_do_throw_lure.rpc(origin, velocity)
	_do_throw_lure(origin, velocity)


## Launch velocity that carries a projectile of speed `LURE_SPEED` from `from`
## to `to` under `LURE_GRAVITY`.
##
## Of the two arcs that hit any reachable point, this picks the flatter one: it
## arrives sooner and reads as a thrown object rather than a mortar shell. If
## the point is out of range there is no solution at all, and the throw falls
## back to 45 degrees — the angle that goes furthest — aimed the right way, so
## an over-ambitious throw still travels as far as it possibly can instead of
## dropping at the thrower's feet.
func _lob_velocity(from: Vector3, to: Vector3) -> Vector3:
	var delta := to - from
	var flat := Vector3(delta.x, 0.0, delta.z)
	var distance := flat.length()
	if distance < 0.05:
		return Vector3.UP * LURE_SPEED
	var forward := flat / distance

	var speed_sq := LURE_SPEED * LURE_SPEED
	# Solving `y = x·tanθ − g·x² / (2·s²·cos²θ)` for θ gives this discriminant;
	# negative means no launch angle at this speed reaches the point.
	var discriminant := speed_sq * speed_sq - LURE_GRAVITY * (
		LURE_GRAVITY * distance * distance + 2.0 * delta.y * speed_sq)
	if discriminant < 0.0:
		return (forward + Vector3.UP).normalized() * LURE_SPEED

	var angle := atan2(speed_sq - sqrt(discriminant), LURE_GRAVITY * distance)
	return (forward * cos(angle) + Vector3.UP * sin(angle)) * LURE_SPEED


@rpc("authority", "call_remote", "reliable")
func _do_throw_lure(origin: Vector3, velocity: Vector3) -> void:
	_lure_ready_at = _now() + _config.lure_cooldown
	cooldowns_changed.emit()

	var animator := _gub.get_node_or_null("AnimationTree") as GubAnimator
	if animator != null:
		animator.play_throw()

	var lure := LURE.instantiate()
	_spawn_root().add_child(lure)
	AudioDirector.play_3d_varied(AudioDirector.LURE_THROW, origin)
	lure.call("launch_from", origin, velocity, _gub.peer_id, _config)


## The host telling this Gub's own client that a lure has caught it.
##
## The pull has to be applied by the victim's client because movement is
## client-authoritative and the host cannot simply move a body it does not own
## (D-004). `Lure` decides *who*; this is *where the answer is delivered*, and it
## is delivered here rather than on the lure that fired it because an RPC is
## addressed by node **path**. A lure has no path two machines agree on: every
## peer builds its own copy into `spawned_items`, and the moment a second one is
## in the air Godot disambiguates the duplicate name with a counter local to that
## process. `Players/Gub_<peer>/Combat` is a name both ends already have, and it
## is owned by the host, which is what makes "authority" the right mode for it.
@rpc("authority", "call_remote", "reliable")
func apply_lure_pull(centre: Vector3, strength: float, duration: float) -> void:
	if _gub != null:
		_gub.apply_lure(centre, strength, duration)


# ------------------------------------------------------------------- shared ---

## Everything a Gub spawns goes into one container so the arena can clear the
## lot between rounds without hunting through the scene tree.
func _spawn_root() -> Node:
	var root := get_tree().get_first_node_in_group("spawned_items")
	return root if root != null else get_tree().current_scene


## Called when a round restarts: wipe cooldowns so nobody starts a round unarmed.
## A throw that was still winding up when the round ended is dropped with them —
## respawning with a spear already half thrown is nobody's idea of a fresh start.
func reset() -> void:
	_windup_release_at = 0.0
	_spear_ready_at = 0.0
	_mushroom_ready_at = 0.0
	_lure_ready_at = 0.0
	_server_spear_ready_at = 0.0
	_server_mushroom_ready_at = 0.0
	_server_lure_ready_at = 0.0
	_prune_mushrooms()
	if _gub != null and _gub.held_spear != null:
		_gub.held_spear.set_carried(true)
	cooldowns_changed.emit()
