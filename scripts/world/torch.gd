class_name Torch
extends Node3D
## A standing torch: post, flame, and the light that makes the map visible.
##
## Torches are the **key light** of Whisperbloom Hollow. The moon is 0.30 energy
## of cold fill (D-009) and the sky ambient averages near-black, so everything a
## player can actually see the shape of is something a torch is shining on. That
## makes torch placement level design rather than decoration, and it makes the
## flicker gameplay-visible: a Gub crossing a torch pool is lit, and then is not.
##
## The flicker is a sum of sines rather than noise, seeded off a per-torch phase.
## Sines are cheap, they never sit still, and — because each torch gets its own
## phase — sixteen of them never pulse together, which is the tell that gives a
## scripted flicker away.

## Base energy and reach of the light. Tuned against the fog — `arena_env.tres`
## runs volumetric fog at 0.032 density and the light has to punch a visible cone
## through it — and, much more importantly, against each other.
##
## The first pass ran 15 m of reach from fourteen torches on a 50 m island, and
## the pools met everywhere: the whole map came out evenly orange, which is worse
## than evenly dark. Torches are the key light (D-009), so what they light and
## what they leave alone *is* the lighting design, and that only exists if there
## is unlit ground between them. At 10.5 m a torch owns a clearing and nothing
## more, and a Gub crossing between two of them goes dark on the way.
## Energy is low for an OmniLight because the ground it lands on is a big flat
## upward-facing plane and the environment is tonemapped for a night: at 5.6 the
## earth within four metres of a torch blew out to cream and the flame stopped
## being the brightest thing in its own pool.
const LIGHT_ENERGY := 2.6
const LIGHT_RANGE := 10.5
## D-009: torch OmniLights want about this much volumetric fog energy, which is
## what turns the light into a visible halo rather than a bright patch of ground.
const FOG_ENERGY := 2.0

const POST_HEIGHT := 2.1
## Where the flame sits, relative to the torch's foot.
const FLAME_HEIGHT := 2.35

## How far the light dips and swells, as a fraction of `LIGHT_ENERGY`.
const FLICKER_DEPTH := 0.16

var _phase: float = 0.0
var _time: float = 0.0
var _light: OmniLight3D
var _core: MeshInstance3D
var _core_material: StandardMaterial3D
var _base_energy: float = LIGHT_ENERGY

static var _flame_texture: GradientTexture2D
static var _flame_ramp: GradientTexture1D
static var _shrink_curve: CurveTexture


## Build a torch. `phase` decorrelates this one's flicker from its neighbours and
## comes from the map seed, so every client's torches flicker in step — which
## matters, because a torch pool is cover information.
static func create(phase: float, shadows: bool = false, tall: float = 1.0) -> Torch:
	var torch := Torch.new()
	torch._phase = phase
	torch._build(shadows, tall)
	return torch


func _build(shadows: bool, tall: float) -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.155, 0.115, 0.082)
	wood.roughness = 0.95
	wood.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.055
	post_mesh.bottom_radius = 0.085
	post_mesh.height = POST_HEIGHT * tall
	post_mesh.radial_segments = 8
	post_mesh.material = wood
	var post := MeshInstance3D.new()
	post.name = "Post"
	post.mesh = post_mesh
	post.position = Vector3.UP * (POST_HEIGHT * tall * 0.5)
	# Leaned a hair off vertical. Nothing on this island was put up with a
	# spirit level, and a rank of perfectly upright posts says otherwise.
	post.rotation = Vector3(sin(_phase) * 0.035, _phase, cos(_phase * 1.7) * 0.035)
	add_child(post)

	var basket_mesh := CylinderMesh.new()
	basket_mesh.top_radius = 0.17
	basket_mesh.bottom_radius = 0.075
	basket_mesh.height = 0.30
	basket_mesh.radial_segments = 8
	basket_mesh.material = wood
	var basket := MeshInstance3D.new()
	basket.name = "Basket"
	basket.mesh = basket_mesh
	basket.position = Vector3.UP * (POST_HEIGHT * tall + 0.06)
	add_child(basket)

	var flame_y := FLAME_HEIGHT * tall

	# The bright core. Unshaded and far over the environment's 1.45 glow
	# threshold, so it is the thing in frame that is allowed to bloom hard.
	_core_material = StandardMaterial3D.new()
	_core_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_material.albedo_color = Color(1.0, 0.72, 0.34)
	_core_material.emission_enabled = true
	_core_material.emission = Color(1.0, 0.58, 0.22)
	_core_material.emission_energy_multiplier = 8.0
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.115
	core_mesh.height = 0.30
	core_mesh.radial_segments = 8
	core_mesh.rings = 5
	_core = MeshInstance3D.new()
	_core.name = "Core"
	_core.mesh = core_mesh
	_core.material_override = _core_material
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core.position = Vector3.UP * flame_y
	add_child(_core)

	add_child(_build_flame(flame_y))

	_light = OmniLight3D.new()
	_light.name = "Light"
	_light.light_color = Color(1.0, 0.63, 0.30)
	_light.light_energy = LIGHT_ENERGY
	_light.omni_range = LIGHT_RANGE
	_light.omni_attenuation = 1.7
	_light.light_volumetric_fog_energy = FOG_ENERGY
	_light.light_specular = 0.5
	# Shadows are the expensive half of a torch — a cube map re-rendered every
	# frame for a light that never stops moving. Only the landmark torches get
	# them; the path lamps light the ground and let the landmark torches draw the
	# silhouettes.
	_light.shadow_enabled = shadows
	_light.shadow_bias = 0.04
	_light.position = Vector3.UP * flame_y
	add_child(_light)


## The flame itself: a small upward puff of soft billboards.
##
## A quad with a radial alpha gradient, not a sphere. At the sizes involved a
## flame particle is twenty pixels across, and twenty pixels of shaded geometry
## is a hard-edged blob, while twenty pixels of soft alpha is fire.
func _build_flame(flame_y: float) -> GPUParticles3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.34, 0.44)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Additive, so overlapping particles build to a white-hot centre the way a
	# flame does instead of compositing into a flat orange smear.
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = soft_dot()
	mat.disable_receive_shadows = true
	mat.no_depth_test = false
	quad.material = mat

	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 12.0
	process.initial_velocity_min = 0.35
	process.initial_velocity_max = 0.85
	# Positive gravity: hot air rises, and this is the only place in the project
	# where that sign is not a bug.
	process.gravity = Vector3(0.0, 1.15, 0.0)
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.085
	process.scale_min = 0.55
	process.scale_max = 1.0
	process.scale_curve = _shrink()
	process.color_ramp = _fire_ramp()
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.22
	process.turbulence_noise_scale = 2.4

	var flame := GPUParticles3D.new()
	flame.name = "Flame"
	flame.draw_pass_1 = quad
	flame.process_material = process
	flame.amount = 22
	flame.lifetime = 0.75
	flame.preprocess = 1.0
	flame.position = Vector3.UP * flame_y
	# Local coordinates: a torch never moves, and local particles let Godot skip
	# re-transforming the whole system when the parent's transform is touched.
	flame.local_coords = true
	# Generous, because the AABB is computed once from the emitter's own extent
	# and a flame that leaves it pops out of existence at the screen edge.
	flame.visibility_aabb = AABB(Vector3(-0.6, -0.3, -0.6), Vector3(1.2, 2.0, 1.2))
	return flame


func _process(delta: float) -> void:
	_time += delta
	# Three incommensurate rates: a slow breath, a mid-rate wobble and a fast
	# crackle. Any two of them would loop audibly-often; three do not.
	var flicker := 1.0 \
		+ FLICKER_DEPTH * 0.52 * sin(_time * 2.7 + _phase) \
		+ FLICKER_DEPTH * 0.30 * sin(_time * 7.3 + _phase * 2.1) \
		+ FLICKER_DEPTH * 0.18 * sin(_time * 17.9 + _phase * 0.6)
	_light.light_energy = _base_energy * flicker
	_core_material.emission_energy_multiplier = 8.0 * flicker
	# The light source drifts inside the flame rather than sitting at its centre,
	# which is what makes long shadows swing instead of merely brightening.
	_light.position = Vector3(
		sin(_time * 3.1 + _phase) * 0.05,
		_light.position.y,
		cos(_time * 2.3 + _phase * 1.4) * 0.05)


# ------------------------------------------------------- shared sub-resources ---

## A soft round dot, built once and shared by every flame in the map (and by the
## fireflies in `Ambience`). Generating it beats shipping a PNG: it is eight
## lines, it cannot go missing, and it is exactly the gradient we want.
static func soft_dot() -> GradientTexture2D:
	if _flame_texture != null:
		return _flame_texture
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	# Squared falloff: a linear one leaves a visible disc edge once dozens of
	# these are added together.
	gradient.add_point(0.45, Color(1, 1, 1, 0.55))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 64
	texture.height = 64
	_flame_texture = texture
	return texture


## White-hot at birth, orange in the middle, gone by the end.
static func _fire_ramp() -> GradientTexture1D:
	if _flame_ramp != null:
		return _flame_ramp
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 0.92, 0.62, 1.0))
	gradient.set_color(1, Color(0.85, 0.16, 0.03, 0.0))
	gradient.add_point(0.35, Color(1.0, 0.52, 0.14, 0.85))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	_flame_ramp = ramp
	return ramp


## Particles start near full size and taper, so the flame narrows as it rises.
static func _shrink() -> CurveTexture:
	if _shrink_curve != null:
		return _shrink_curve
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.62))
	curve.add_point(Vector2(0.22, 1.0))
	curve.add_point(Vector2(1.0, 0.05))
	var texture := CurveTexture.new()
	texture.curve = curve
	_shrink_curve = texture
	return texture
