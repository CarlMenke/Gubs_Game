class_name Lure
extends Node3D
## A thrown crystal that briefly drags every nearby Gub into it and holds them.
##
## The lure is the answer to cover. A Gub crouched behind a mushroom is
## unhittable; a lure lobbed past it pulls them out into the open for about a
## second, which is exactly long enough for a spear to be in the air already. It
## is deliberately not damaging — it creates the shot, it does not take it.
##
## Life cycle: FLYING (ballistic) → ARMED (a short fuse, so it can be dodged if
## you see it land) → PULLING → SPENT.
##
## The host owns every decision here. Movement is client-authoritative, so a
## caught Gub cannot be moved by the host directly; instead the host tells that
## client it is being pulled and the client's own movement code obeys.

const MODEL := preload("res://art/generated/lure.glb")

enum Phase { FLYING, ARMED, PULLING, SPENT }

## Emitted host-side the instant the lure fires, carrying the peer ids it caught.
## The pull itself is applied on each victim's own client (movement is
## client-authoritative), so this is the only place the *whole* victim list
## exists — which makes it what feedback and the testbeds have to listen to.
signal caught(victim_ids: Array)

const GRAVITY := 22.0
const MAX_FLIGHT := 5.0
const SPIN_SPEED := 5.0

## How brightly the crystal glows in each phase. The jump at arming is the
## warning that the pull is about to happen.
const GLOW_FLYING := 2.5
const GLOW_ARMED := 7.0
const GLOW_PULLING := 16.0

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_DEPLOYABLE := 8

var owner_peer_id: int = 0

var _phase: Phase = Phase.FLYING
var _velocity: Vector3 = Vector3.ZERO
var _timer: float = 0.0
var _flight_time: float = 0.0
var _model: Node3D
var _light: OmniLight3D

var _radius: float = 9.0
var _hold: float = 1.4
var _strength: float = 18.0
var _fuse: float = 0.35


func launch_from(origin: Vector3, velocity: Vector3, thrown_by: int,
		config: MatchConfig) -> void:
	owner_peer_id = thrown_by
	global_position = origin
	_velocity = velocity
	_radius = config.lure_radius
	_hold = config.lure_hold
	_strength = config.lure_pull_strength
	_fuse = config.lure_fuse


func _ready() -> void:
	_model = MODEL.instantiate() as Node3D
	# The source crystal is nearly two metres tall — fine as scenery, absurd as
	# something you throw underarm.
	_model.scale = Vector3.ONE * 0.30
	add_child(_model)

	_light = OmniLight3D.new()
	_light.light_color = Color(0.55, 0.85, 1.0)
	_light.light_energy = GLOW_FLYING
	_light.omni_range = 7.0
	_light.position = Vector3(0.0, 0.3, 0.0)
	add_child(_light)


func _physics_process(delta: float) -> void:
	match _phase:
		Phase.FLYING:
			_tick_flight(delta)
		Phase.ARMED:
			_tick_fuse(delta)
		Phase.PULLING:
			_tick_pull(delta)
		Phase.SPENT:
			pass


func _tick_flight(delta: float) -> void:
	_flight_time += delta
	if _flight_time > MAX_FLIGHT:
		_arm()
		return

	_velocity.y -= GRAVITY * delta
	var next := global_position + _velocity * delta

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position, next)
	query.collision_mask = LAYER_WORLD | LAYER_DEPLOYABLE
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		global_position = next
		if _model != null:
			_model.rotate_y(SPIN_SPEED * delta)
		return

	global_position = hit["position"] + Vector3(hit["normal"]) * 0.15
	_arm()


func _arm() -> void:
	_phase = Phase.ARMED
	_timer = _fuse
	_velocity = Vector3.ZERO
	if _light != null:
		_light.light_energy = GLOW_ARMED


func _tick_fuse(delta: float) -> void:
	_timer -= delta
	if _model != null:
		_model.rotate_y(SPIN_SPEED * 2.0 * delta)
	if _timer > 0.0:
		return
	_phase = Phase.PULLING
	_timer = _hold
	if _light != null:
		_light.light_energy = GLOW_PULLING
	_catch()


## Sweep once, at the moment the lure goes off. Deciding the victim list up
## front — rather than every frame — means running *out* of the radius after it
## fires does not save you, which is what makes the lure worth throwing at
## someone already behind cover.
func _catch() -> void:
	if not Net.is_host:
		return
	var victims: Array = []
	for gub in get_tree().get_nodes_in_group("gubs"):
		var target := gub as Gub
		if target == null or not target.alive:
			continue
		if target.global_position.distance_to(global_position) > _radius:
			continue
		# Line of sight, so a lure does not yank people through the island.
		if not _can_see(target):
			continue
		# Credit the lurer if this Gub dies shortly afterwards. Pulling someone
		# off the edge of the island is a kill the lure earned, but nothing the
		# void-death code could attribute on its own — it only sees a Gub that
		# fell. `note_attack` is what carries that intent forward.
		if target.peer_id != owner_peer_id:
			MatchState.note_attack(target.peer_id, owner_peer_id)
		victims.append(target.peer_id)
		# Exactly one of these, never both. Sending to yourself is refused
		# outright by a `call_remote` RPC, and sending to a peer that is not
		# connected — a fake roster entry in a testbed, or anyone who dropped
		# between the sweep and this line in a real match — is an error too.
		# Both used to be logged on every lure that caught the host or a
		# departing player.
		if target.peer_id == multiplayer.get_unique_id():
			_pull_target(global_position, _strength, _hold)
		elif multiplayer.get_peers().has(target.peer_id):
			_pull_target.rpc_id(target.peer_id, global_position, _strength, _hold)
	caught.emit(victims)


func _can_see(target: Gub) -> bool:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 0.2,
		target.global_position + Vector3.UP * target.eye_height())
	query.collision_mask = LAYER_WORLD
	query.exclude = [target.get_rid()]
	return space.intersect_ray(query).is_empty()


## Received by the client that owns the caught Gub. Its own movement code is what
## actually applies the pull — see `Gub._apply_lure`.
@rpc("any_peer", "call_remote", "reliable")
func _pull_target(centre: Vector3, strength: float, duration: float) -> void:
	for gub in get_tree().get_nodes_in_group("gubs"):
		var target := gub as Gub
		if target != null and target.is_local():
			target.apply_lure(centre, strength, duration)


func _tick_pull(delta: float) -> void:
	_timer -= delta
	if _model != null:
		_model.rotate_y(SPIN_SPEED * 4.0 * delta)
	if _light != null:
		# Pulse while it holds, so the effect has an obvious duration.
		_light.light_energy = GLOW_PULLING * (0.7 + 0.3 * sin(_timer * 22.0))
	if _timer > 0.0:
		return
	_spend()


func _spend() -> void:
	_phase = Phase.SPENT
	var fade := create_tween()
	fade.set_parallel(true)
	if _model != null:
		fade.tween_property(_model, "scale", Vector3.ZERO, 0.35)
	if _light != null:
		fade.tween_property(_light, "light_energy", 0.0, 0.35)
	fade.chain().tween_callback(queue_free)


func phase() -> Phase:
	return _phase
