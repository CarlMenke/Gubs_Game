class_name Ambience
extends RefCounted
## The things drifting through the air over Whisperbloom Hollow: fireflies,
## spores, falling leaves — and the hooks for the ambient loops that will play
## under them (4.9).
##
## All of it is `GPUParticles3D`. Every emitter here is a handful of draw calls
## and no CPU work at all, which is the only reason a night map can afford this
## much motion: the island itself never moves, so the drifting particles are
## doing all the work of making it feel like a place rather than a diorama.
##
## Everything is seeded, like the rest of the map, but nothing here is
## gameplay-relevant — two clients whose fireflies were out of step would not be
## playing different games. It is seeded because it costs nothing to be, and
## because "why is this frame different" is a question worth never having to ask.

## Ambient loops, by the bus they belong on. None of these files exist yet — see
## the note on `_build_audio` — and each one is skipped silently until it does.
const LOOPS := {
	"forest": "res://assets/audio/ambience/forest_night.ogg",
	"wind": "res://assets/audio/ambience/wind_high.ogg",
}


## Build every ambience emitter under `parent`.
##
## `canopy_points` comes from the prop scatter: leaves need somewhere to fall
## from, and the honest answer to "where are the trees" is "wherever the scatter
## put them", not a radius guessed after the fact.
static func build(parent: Node3D, island: IslandGenerator,
		canopy_points: PackedVector3Array, map_seed: int) -> void:
	var root := Node3D.new()
	root.name = "Ambience"
	parent.add_child(root)

	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed ^ 0x2B10FF

	_build_fireflies(root, island, rng)
	_build_spores(root, island)
	_build_leaves(root, island, canopy_points)
	_build_audio(root, island)


# --------------------------------------------------------------- fireflies ---

## Fireflies, in a few loose swarms rather than one map-wide cloud.
##
## Spreading two hundred particles over the whole island gives one every seven
## metres, which reads as dust. Four swarms of fifty over an eighteen-metre box
## each read as insects, and the gaps between them are what make the lit parts
## of the map feel populated.
static func _build_fireflies(parent: Node3D, island: IslandGenerator,
		rng: RandomNumberGenerator) -> void:
	var swarms := [
		Vector2(4.5, -5.0),          # over the mushroom grove
		Vector2(-6.0, -7.5),         # under the shrine knoll
		Vector2(9.5, 7.0),           # the far shoulder
		Vector2(-9.0, 6.5),
	]
	for i in swarms.size():
		var spot: Vector2 = swarms[i]
		var ground := island.height_at(spot.x, spot.y)
		if ground <= IslandGenerator.NO_LAND:
			continue

		var mat := ParticleProcessMaterial.new()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		mat.emission_box_extents = Vector3(8.5, 1.6, 8.5)
		mat.direction = Vector3(1.0, 0.2, 0.0)
		mat.spread = 180.0
		mat.initial_velocity_min = 0.05
		mat.initial_velocity_max = 0.32
		mat.gravity = Vector3.ZERO
		mat.damping_min = 0.1
		mat.damping_max = 0.4
		# Turbulence is what turns straight-line drift into a wander. It is the
		# single setting that decides whether these read as insects or as snow.
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.55
		mat.turbulence_noise_scale = 1.4
		mat.turbulence_noise_speed = Vector3(0.12, 0.05, 0.1)
		mat.scale_min = 0.5
		mat.scale_max = 1.1
		mat.color_ramp = _blink_ramp()

		var quad := QuadMesh.new()
		quad.size = Vector2(0.13, 0.13)
		quad.material = _glow_material(Color(0.85, 1.0, 0.45), 7.0)

		var swarm := GPUParticles3D.new()
		swarm.name = "Fireflies%d" % i
		swarm.draw_pass_1 = quad
		swarm.process_material = mat
		swarm.amount = 48
		swarm.lifetime = 9.0
		swarm.randomness = 0.85
		# Without a preprocess the swarm fades up from nothing over nine seconds
		# after every scene load, which is exactly the moment a player is
		# deciding what this place looks like.
		swarm.preprocess = 9.0
		swarm.position = Vector3(spot.x, ground + 1.7, spot.y)
		swarm.visibility_aabb = AABB(Vector3(-11, -4, -11), Vector3(22, 12, 22))
		swarm.rotation.y = rng.randf_range(0.0, TAU)
		parent.add_child(swarm)


# ------------------------------------------------------------------ spores ---

## Slow motes over the whole map, rising rather than falling.
##
## These are the layer doing the atmospheric work: they catch the torchlight at
## every depth, which is what gives the volumetric fog something to sit in front
## of and behind, and they are the reason the middle distance does not read as
## empty air.
static func _build_spores(parent: Node3D, island: IslandGenerator) -> void:
	var reach := island.extent()

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(reach * 0.8, 5.0, reach * 0.8)
	mat.direction = Vector3(0.4, 1.0, 0.15)
	mat.spread = 55.0
	mat.initial_velocity_min = 0.08
	mat.initial_velocity_max = 0.3
	# A whisper of lift, so the field slowly climbs instead of hanging still.
	mat.gravity = Vector3(0.05, 0.06, 0.02)
	mat.damping_min = 0.05
	mat.damping_max = 0.2
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.28
	mat.turbulence_noise_scale = 2.0
	mat.scale_min = 0.35
	mat.scale_max = 1.0
	mat.color_ramp = _fade_ramp(Color(0.72, 0.86, 0.95))

	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	quad.material = _glow_material(Color(0.7, 0.85, 0.95), 2.2)

	var spores := GPUParticles3D.new()
	spores.name = "Spores"
	spores.draw_pass_1 = quad
	spores.process_material = mat
	spores.amount = 260
	spores.lifetime = 22.0
	spores.randomness = 0.9
	spores.preprocess = 22.0
	spores.position = Vector3(0.0, 4.5, 0.0)
	spores.visibility_aabb = AABB(Vector3(-reach, -12, -reach),
		Vector3(reach * 2.0, 34, reach * 2.0))
	parent.add_child(spores)


# ------------------------------------------------------------------ leaves ---

## Leaves falling out of the canopy.
##
## Emitted from a **ring** rather than a box, sized and positioned from where the
## scatter actually put its trees. The trees sit toward the rim (`radial_power`
## in `PropScatter`), so a box emitter would drop most of its leaves over the
## open middle of the map, where there is nothing overhead for them to have come
## from — which the eye notices immediately even when it cannot say why.
static func _build_leaves(parent: Node3D, island: IslandGenerator,
		canopy_points: PackedVector3Array) -> void:
	if canopy_points.is_empty():
		return

	var inner := INF
	var outer := 0.0
	var height := 0.0
	for point: Vector3 in canopy_points:
		var radius := Vector2(point.x, point.z).length()
		inner = minf(inner, radius)
		outer = maxf(outer, radius)
		height += point.y
	height /= float(canopy_points.size())

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	mat.emission_ring_axis = Vector3.UP
	mat.emission_ring_radius = outer
	mat.emission_ring_inner_radius = maxf(inner, 4.0)
	mat.emission_ring_height = 4.0
	mat.direction = Vector3(0.6, -0.2, 0.2)
	mat.spread = 40.0
	mat.initial_velocity_min = 0.1
	mat.initial_velocity_max = 0.6
	# Light gravity plus heavy damping is a terminal velocity of well under a
	# metre a second. Real gravity here (24 m/s², see project.godot) would fling
	# the leaves at the ground like gravel.
	mat.gravity = Vector3(0.35, -1.1, 0.15)
	mat.damping_min = 0.6
	mat.damping_max = 1.4
	mat.angle_min = -180.0
	mat.angle_max = 180.0
	mat.angular_velocity_min = -55.0
	mat.angular_velocity_max = 55.0
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.5
	mat.turbulence_noise_scale = 1.8
	mat.scale_min = 0.5
	mat.scale_max = 1.0
	mat.color_ramp = _fade_ramp(Color(0.85, 0.78, 0.55))

	# Real kit petals, not billboards: a leaf that tumbles has to have two sides
	# to show, and the MegaKit's petals are thirty triangles each.
	var petal := PropScatter.load_kit_mesh("Petal_2")
	if petal == null:
		return

	var leaves := GPUParticles3D.new()
	leaves.name = "FallingLeaves"
	leaves.draw_pass_1 = petal
	leaves.process_material = mat
	leaves.amount = 70
	leaves.lifetime = 11.0
	leaves.randomness = 0.9
	leaves.preprocess = 11.0
	leaves.position = Vector3(0.0, height, 0.0)
	leaves.visibility_aabb = AABB(Vector3(-outer - 4.0, -height - 6.0, -outer - 4.0),
		Vector3(outer * 2.0 + 8.0, height + 12.0, outer * 2.0 + 8.0))
	parent.add_child(leaves)


# ------------------------------------------------------------------- audio ---

## PLAN 4.9 — ambient audio. **Stubbed on purpose.**
##
## The repository ships no audio at all (`find assets -name '*.ogg'` is empty),
## and inventing placeholder tones would be worse than silence: they would have
## to be found and deleted later, and in the meantime every playtest would be
## judging mixing decisions made against a sine wave.
##
## What is here instead is the wiring, so that dropping the files in is the whole
## job. Each loop is placed as a positioned, looping `AudioStreamPlayer3D` on the
## Ambience bus (which `default_bus_layout.tres` already defines and
## `Settings`/`AudioDirector` already have a volume slider for), and each is
## skipped silently while its file is missing.
##
## What is still needed when the audio arrives:
##   * `forest_night.ogg` — the bed, at the map centre, effectively unattenuated.
##   * `wind_high.ogg` — over the rim, quieter and further out, so walking to the
##     edge of the island is audible before it is visible.
##   * a water loop, which this map does not have a source for yet.
static func _build_audio(parent: Node3D, island: IslandGenerator) -> void:
	var placements := {
		"forest": {"at": Vector3(0.0, 3.0, 0.0), "range": island.extent() * 2.0, "db": -6.0},
		"wind": {"at": Vector3(0.0, 12.0, 0.0), "range": island.extent() * 2.4, "db": -12.0},
	}
	for key: String in LOOPS:
		var path: String = LOOPS[key]
		if not ResourceLoader.exists(path):
			continue
		var stream := load(path) as AudioStream
		if stream == null:
			continue
		var placement: Dictionary = placements[key]
		var player := AudioStreamPlayer3D.new()
		player.name = "Ambient_%s" % key
		player.stream = stream
		player.bus = "Ambience"
		player.unit_size = placement["range"]
		player.volume_db = placement["db"]
		player.autoplay = true
		player.position = placement["at"]
		parent.add_child(player)


# ---------------------------------------------------------------- materials ---

## Unshaded, additive, billboarded soft dot — the same treatment the torch flame
## uses, and the same generated texture, so there is exactly one of it in memory.
static func _glow_material(tint: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = Torch.soft_dot()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = energy
	mat.disable_receive_shadows = true
	return mat


## Alpha that rises, falls, rises and falls again over one lifetime. Fireflies
## do not fade in and out on a schedule — they blink — and two blinks per nine
## seconds is close enough that the eye stops counting.
static func _blink_ramp() -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0))
	gradient.set_color(1, Color(1, 1, 1, 0))
	gradient.add_point(0.16, Color(1.0, 1.0, 0.75, 1.0))
	gradient.add_point(0.34, Color(1.0, 1.0, 0.75, 0.05))
	gradient.add_point(0.58, Color(1.0, 1.0, 0.75, 0.9))
	gradient.add_point(0.80, Color(1.0, 1.0, 0.75, 0.08))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	return ramp


## In at birth, out at death, flat in between — so nothing ever pops.
static func _fade_ramp(tint: Color) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(tint.r, tint.g, tint.b, 0.0))
	gradient.set_color(1, Color(tint.r, tint.g, tint.b, 0.0))
	gradient.add_point(0.15, Color(tint.r, tint.g, tint.b, 1.0))
	gradient.add_point(0.8, Color(tint.r, tint.g, tint.b, 0.9))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	return ramp
