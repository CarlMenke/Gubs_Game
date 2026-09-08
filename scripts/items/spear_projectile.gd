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
## How long a spear that struck a Gub waits for a corpse to claim it before
## giving up and removing itself. The host adopts it within the same frame; a
## client has to wait for the death to arrive over the network. Anything still
## unclaimed after this hit someone who did not die — a team-mate with friendly
## fire off, or a kill the host declined — and must not be left in them.
const ADOPTION_GRACE := 0.75

## How much brighter the spear burns while it is in the air.
##
## The trail says where the spear *has been*; this is what makes the spear
## itself findable at the head of it. A thrown stick is a thin, dark, fast thing
## against a dark forest, and the playtest verdict on that was blunt: "you can't
## see the spear". Lighting it is a cheat and a deliberate one — the same cheat
## as the trail, and the alternative is a weapon whose whole skill ceiling is
## reading a flight nobody can see.
##
## A *multiplier* rather than an absolute, because of how everything in
## `art/generated` is built: the models carry a **black albedo and a pre-shaded
## emission texture**, so their entire visible colour is already emission. There
## is no glow to switch on here, only one to turn up. The same fact rules out
## tinting it — the material's emission operator is multiply, so handing it a
## warm colour would *darken* the texture's blue rather than adding warmth.
##
## The number was picked by eye against `resources/config/default_env.tres`,
## which tonemaps with ACES at a white point of 6.0. Values that sound bright in
## the abstract do very little through that curve: at 1.25 the spear was
## indistinguishable from an unlit one. Here the brightest parts of the shaft
## clear the environment's 1.05 bloom threshold, so the spear reads as lit
## rather than as a stick, and stops well short of a lightsaber.
##
## It comes off the moment the spear stops. A spear standing in the dirt or
## sticking out of a corpse is scenery and has to read as scenery; a glowing one
## would turn every miss into a beacon and every body into a lamp.
const GLOW_BOOST := 3.0
## Only reached by a surface that was not emissive to begin with. Nothing on the
## shipping spear is, but a material with no emission has nothing to multiply and
## would otherwise "glow" black.
const GLOW_COLOUR := Color(1.0, 0.94, 0.76)

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
## Set once a corpse has taken ownership of this spear.
var _embedded: bool = false
## Seconds spent waiting for a corpse to claim this spear.
var _pending_age: float = 0.0
## The velocity this spear was carrying at the moment it struck something.
## `_velocity` is zeroed on impact, so without this the momentum of the hit is
## gone by the time anyone downstream asks about it.
var _impact_velocity: Vector3 = Vector3.ZERO
var _model: Node3D
var _thrower: Gub
var _trail: SpearTrail
## The mesh nodes currently carrying the in-flight glow override.
var _glowing: Array[MeshInstance3D] = []


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
	_light_up()

	_trail = SpearTrail.new()
	add_child(_trail)
	_trail.push_point(global_position)


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
		if _trail != null:
			_trail.push_point(global_position)
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
			var bone := _nearest_bone(victim, point)
			_stick_in(victim, point, bone)
			struck_gub.emit(victim, point, bone)
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
		return "Spine1"
	var best := "Spine1"
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


## Bury the spear in the Gub it just killed and hand it to the corpse.
##
## Freeing it here instead — which is what used to happen — threw away the
## clearest read in the game: a body on the ground with a spear through it says
## who died and roughly how, from across the arena, for as long as the corpse
## lasts. The ragdoll does not exist yet at this moment (the kill has not been
## reported), so the spear parks itself on the victim and `GubRagdoll` collects
## it while it is building the body. If no corpse ever appears — a void death,
## or a client that never sees one — `Gub` drops it on its next respawn.
func _stick_in(victim: Gub, point: Vector3, bone: String) -> void:
	_stuck = true
	_stuck_age = 0.0
	_pending_age = 0.0
	_impact_velocity = _velocity
	global_position = point + _velocity.normalized() * BURY_DEPTH
	_velocity = Vector3.ZERO
	_stop_glowing()
	AudioDirector.play_3d_varied(AudioDirector.SPEAR_HIT_BODY, point)
	if _trail != null:
		_trail.begin_fade()
		_trail = null
	# Hidden until a corpse claims it. Whether this hit is a kill at all is the
	# host's decision and has not been made yet — with friendly fire off, a
	# spear thrown at a team-mate stops here and nobody dies. Staying visible
	# through that would leave a spear sticking out of a living player forever.
	# On the host, adoption happens inside the same frame, so this is invisible
	# in both senses.
	visible = false
	victim.embed_spear(self, bone)


func _stick(normal: Vector3) -> void:
	_stuck = true
	set_process_priority(0)
	_impact_velocity = _velocity
	_stop_glowing()
	AudioDirector.play_3d_varied(AudioDirector.SPEAR_HIT_WORLD, global_position)
	if _trail != null:
		_trail.begin_fade()
		_trail = null
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
	# A spear that ended up in a body is owned by the corpse and disappears when
	# the corpse does; only one stuck in the scenery times itself out.
	if _embedded:
		return
	if not visible:
		# Waiting to be adopted. If that never happens, the Gub it struck did
		# not die and this spear has no business existing any more.
		_pending_age += delta
		if _pending_age > ADOPTION_GRACE:
			queue_free()
		return
	_stuck_age += delta
	if _stuck_age < STUCK_LINGER:
		return
	var fade := 1.0 - clampf((_stuck_age - STUCK_LINGER) / STUCK_FADE, 0.0, 1.0)
	if fade <= 0.0:
		queue_free()
		return
	if _model != null:
		_model.scale = Vector3.ONE * maxf(fade, 0.01)


## Put the flight glow on every surface of the model.
##
## A copy of the imported material per spear, the same way `GubRagdoll` takes
## its own copy to fade a corpse out — and for the same reason. The imported
## material is shared by every spear in the game, the one in your hand
## included, so lighting *it* up would light up all of them and leave them lit.
##
## One small material per throw, held by the projectile and freed with it. A
## single glowing copy cached and handed to every spear would be marginally
## cheaper and would be a mutable global living past the end of the match, which
## is a much worse trade than a duplicate of a material on a two-surface stick.
func _light_up() -> void:
	for node in _model_meshes():
		var lit := false
		for surface in node.mesh.get_surface_count():
			# Null means a material this cannot copy — a shader material, say.
			# That surface simply does not glow, rather than being replaced by
			# something that would throw its texture away.
			var source := node.get_active_material(surface) as BaseMaterial3D
			if source == null:
				continue
			var glow := source.duplicate() as BaseMaterial3D
			if not glow.emission_enabled:
				glow.emission_enabled = true
				glow.emission = GLOW_COLOUR
				glow.emission_energy_multiplier = 1.0
			glow.emission_energy_multiplier *= GLOW_BOOST
			node.set_surface_override_material(surface, glow)
			lit = true
		if lit:
			_glowing.append(node)


## ...and take it off again, which is what makes a landed spear look landed.
func _stop_glowing() -> void:
	for node in _glowing:
		if not is_instance_valid(node) or node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			node.set_surface_override_material(surface, null)
	_glowing.clear()


func _model_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [_model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var mesh_node := node as MeshInstance3D
		if mesh_node != null and mesh_node.mesh != null:
			out.append(mesh_node)
		stack.append_array(node.get_children())
	return out


func _face_travel() -> void:
	if _velocity.length_squared() < 0.001:
		return
	# look_at points -Z at the target, which is the direction of flight.
	look_at(global_position + _velocity, Vector3.UP)


## Where the spear is right now, for trails and audio.
func velocity() -> Vector3:
	return _velocity


## What the spear was doing at the instant it hit, direction *and* speed. This
## is what carries the weight of a throw into the corpse: a spear caught at the
## top of a long arc has shed most of its speed and should shove a body far less
## than one that arrives flat from ten metres.
func impact_velocity() -> Vector3:
	return _impact_velocity


func is_stuck() -> bool:
	return _stuck


## Called by `GubRagdoll` once the spear has been re-parented onto a physical
## bone, so it stops running its own fade-out timer.
func mark_embedded() -> void:
	_embedded = true
	visible = true
