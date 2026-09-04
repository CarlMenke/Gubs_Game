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
## Cooldowns are therefore tracked twice on purpose. The local copy exists so the
## HUD can show a sweeping timer without waiting for a round trip; the host's
## copy is the one that counts.

signal cooldowns_changed()

const SPEAR := preload("res://scripts/items/spear_projectile.gd")
const MUSHROOM := preload("res://scenes/items/shield_mushroom.tscn")
const LURE := preload("res://scenes/items/lure.tscn")

## Where the throw leaves the hand, relative to the Gub. The spear is aimed at
## whatever the crosshair is over, not simply pushed along the camera's forward
## axis, so what you point at is what you hit even up close.
const THROW_OFFSET := Vector3(0.34, 0.0, 0.0)
## Anything nearer than this is treated as "straight ahead"; without it, aiming
## at a wall a metre away would make the Gub throw at its own feet.
const MIN_AIM_DISTANCE := 3.0
const MAX_AIM_DISTANCE := 220.0

## How far in front the mushroom is planted, and how far the lure is lobbed if
## the crosshair is on open sky.
const MUSHROOM_DISTANCE := 2.1
const LURE_SPEED := 17.0

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
	if _gub == null or not _gub.is_local() or not _gub.alive:
		return
	if SceneFlow.cursor_is_free():
		return
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


# ------------------------------------------------------------------- spear ---

func try_throw_spear() -> void:
	if spear_cooldown() > 0.0:
		return
	var origin := _throw_origin()
	var direction := (_aim_point() - origin).normalized()
	if direction.length_squared() < 0.001:
		return

	# Predict locally so the animation and the empty hand happen on the same
	# frame as the click, then ask the host to make it real.
	_spear_ready_at = _now() + _config.spear_recharge
	cooldowns_changed.emit()

	if Net.is_host:
		_host_throw_spear(origin, direction)
	else:
		_request_throw_spear.rpc_id(1, origin, direction)


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


@rpc("authority", "call_remote", "reliable")
func _do_throw_spear(origin: Vector3, direction: Vector3) -> void:
	_spear_ready_at = _now() + _config.spear_recharge
	cooldowns_changed.emit()

	var animator := _gub.get_node_or_null("AnimationTree") as GubAnimator
	if animator != null:
		animator.play_throw()
	if _gub.held_spear != null:
		_gub.held_spear.set_carried(false)
		_regrow_spear()

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


func _on_spear_struck_gub(victim: Gub, point: Vector3, bone: String,
		spear: SpearProjectile) -> void:
	# Only the host's copy of a spear is allowed to decide anything.
	if not spear.authoritative or not Net.is_host:
		return
	MatchState.report_kill(victim.peer_id, _gub.peer_id, Gub.Cause.SPEAR,
		point, spear.velocity().normalized(), bone)


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

func try_throw_lure() -> void:
	if lure_cooldown() > 0.0:
		return
	var origin := _throw_origin()
	var direction := (_aim_point() - origin).normalized()
	_lure_ready_at = _now() + _config.lure_cooldown
	cooldowns_changed.emit()
	if Net.is_host:
		_host_throw_lure(origin, direction)
	else:
		_request_lure.rpc_id(1, origin, direction)


@rpc("any_peer", "call_remote", "reliable")
func _request_lure(origin: Vector3, direction: Vector3) -> void:
	if not Net.is_host or multiplayer.get_remote_sender_id() != _gub.peer_id:
		return
	_host_throw_lure(origin, direction)


func _host_throw_lure(origin: Vector3, direction: Vector3) -> void:
	if not _gub.alive or _now() < _server_lure_ready_at:
		return
	if origin.distance_to(_gub.global_position) > 3.0:
		origin = _throw_origin()
	_server_lure_ready_at = _now() + _config.lure_cooldown
	_do_throw_lure.rpc(origin, direction.normalized())
	_do_throw_lure(origin, direction.normalized())


@rpc("authority", "call_remote", "reliable")
func _do_throw_lure(origin: Vector3, direction: Vector3) -> void:
	_lure_ready_at = _now() + _config.lure_cooldown
	cooldowns_changed.emit()

	var animator := _gub.get_node_or_null("AnimationTree") as GubAnimator
	if animator != null:
		animator.play_throw()

	var lure := LURE.instantiate()
	_spawn_root().add_child(lure)
	lure.call("launch_from", origin, direction * LURE_SPEED, _gub.peer_id, _config)


# ------------------------------------------------------------------- shared ---

## Everything a Gub spawns goes into one container so the arena can clear the
## lot between rounds without hunting through the scene tree.
func _spawn_root() -> Node:
	var root := get_tree().get_first_node_in_group("spawned_items")
	return root if root != null else get_tree().current_scene


## Called when a round restarts: wipe cooldowns so nobody starts a round unarmed.
func reset() -> void:
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
