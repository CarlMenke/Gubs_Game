extends Node3D
## Stand-in stage for judging `arena_sky.tres` + `arena_env.tres` before the real
## island exists. Development tool, not shipped.
##
## Nothing here is map geometry — it is the minimum needed to tell whether the
## environment is doing its job: a floating slab so the horizon line and the void
## below it are both in frame, three torches for the warm/cool contrast the map
## is built around, dark cones to check silhouettes read against the sky, and the
## Gub plus a saturated yellow ball to catch glow blow-out.
##
## Usage (the extra arg is read straight off the command line, so this works
## through `tools/snapshot.gd` without teaching it about views):
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://tools/preview_sky.tscn out.png 45 [horizon|up|edge]

const ENV_PATH := "res://resources/config/arena_env.tres"
const GUB_PATH := "res://art/generated/gub.glb"

## Where the sky's moon sits. Must match `moon_direction` in `arena_sky.tres`:
## the shader reads the DirectionalLight3D when one exists, and a mismatch would
## put the moon disc somewhere the moonlight is not coming from.
const MOON_DIR := Vector3(-0.42, 0.38, -0.82)

const ISLAND_RADIUS := 22.0

## Camera framings. Each is [position, look-at target].
const VIEWS := {
	"horizon": [Vector3(0.0, 3.1, 17.0), Vector3(0.0, 3.6, -10.0)],
	"up": [Vector3(0.0, 2.0, 11.0), Vector3(0.0, 12.0, -10.0)],
	"edge": [Vector3(12.0, 4.5, 16.0), Vector3(-2.0, -1.5, -6.0)],
}

@export var view: String = "horizon"


func _ready() -> void:
	_pick_view_from_cmdline()
	_build_environment()
	_build_island()
	_build_silhouettes()
	_build_torches()
	_build_exposure_targets()
	_build_camera()


func _pick_view_from_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if VIEWS.has(arg):
			view = arg


func _build_environment() -> void:
	var world := WorldEnvironment.new()
	world.environment = load(ENV_PATH)
	add_child(world)

	# The moon light. Aimed at the origin from the sky's moon direction so that
	# LIGHT0_DIRECTION inside the sky shader resolves to MOON_DIR exactly.
	var moon := DirectionalLight3D.new()
	add_child(moon)
	moon.position = MOON_DIR.normalized() * 60.0
	moon.look_at(Vector3.ZERO, Vector3.UP)
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.light_energy = 0.30
	moon.light_specular = 0.35
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 90.0
	moon.light_volumetric_fog_energy = 0.6


func _build_island() -> void:
	# A slab, not an infinite plane: the sky below the horizon is half the art
	# direction and a ground plane would hide all of it.
	var slab := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = ISLAND_RADIUS
	mesh.bottom_radius = ISLAND_RADIUS * 0.55
	mesh.height = 9.0
	mesh.radial_segments = 48
	slab.mesh = mesh
	slab.position = Vector3(0.0, -4.5, 0.0)
	slab.material_override = _matte(Color(0.17, 0.20, 0.13), 0.95)
	add_child(slab)


func _build_silhouettes() -> void:
	var dark := _matte(Color(0.06, 0.075, 0.055), 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240912
	for i in 14:
		var angle := rng.randf_range(0.0, TAU)
		var dist := rng.randf_range(13.0, ISLAND_RADIUS - 1.0)
		var height := rng.randf_range(4.5, 8.0)

		var trunk := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.05
		cone.bottom_radius = rng.randf_range(0.6, 1.1)
		cone.height = height
		cone.radial_segments = 10
		trunk.mesh = cone
		trunk.material_override = dark
		trunk.position = Vector3(cos(angle) * dist, height * 0.5, sin(angle) * dist)
		add_child(trunk)


func _build_torches() -> void:
	for offset in [Vector3(-4.0, 0.0, 2.0), Vector3(5.5, 0.0, -1.5), Vector3(0.5, 0.0, -11.0)]:
		var post := MeshInstance3D.new()
		var pole := CylinderMesh.new()
		pole.top_radius = 0.08
		pole.bottom_radius = 0.12
		pole.height = 2.4
		post.mesh = pole
		post.material_override = _matte(Color(0.09, 0.07, 0.05), 1.0)
		post.position = offset + Vector3.UP * 1.2
		add_child(post)

		var flame := MeshInstance3D.new()
		var bulb := SphereMesh.new()
		bulb.radius = 0.16
		bulb.height = 0.4
		flame.mesh = bulb
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.65, 0.28)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.56, 0.20)
		# Well over the environment's 1.45 glow threshold — a flame is the one
		# thing on the island that is meant to bloom hard.
		mat.emission_energy_multiplier = 9.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flame.material_override = mat
		flame.position = offset + Vector3.UP * 2.5
		add_child(flame)

		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.62, 0.28)
		light.light_energy = 6.5
		light.omni_range = 16.0
		light.omni_attenuation = 1.6
		light.shadow_enabled = true
		light.light_volumetric_fog_energy = 2.0
		light.position = offset + Vector3.UP * 2.5
		add_child(light)


func _build_exposure_targets() -> void:
	# The Gub is the brightest thing that is *not* supposed to bloom, so the
	# glow threshold is judged against him. Real mesh if it has been imported,
	# a ball of the same yellow if not.
	var gub := (load(GUB_PATH) as PackedScene)
	if gub != null:
		var node := gub.instantiate() as Node3D
		add_child(node)
		# Normalised by measured height rather than the project's 0.35 import
		# scale, so a re-import of the mesh cannot silently change the size of
		# the thing the glow threshold is judged against.
		var tall := _visual_height(node)
		if tall > 0.0:
			node.scale = Vector3.ONE * (1.8 / tall)
		node.position = Vector3(-2.6, 0.0, 3.4)
		node.rotation.y = 2.6

	var ball := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	ball.mesh = sphere
	var yellow := StandardMaterial3D.new()
	yellow.albedo_color = Color(1.0, 0.86, 0.16)
	yellow.roughness = 0.62
	ball.material_override = yellow
	ball.position = Vector3(1.6, 0.9, 3.0)
	add_child(ball)


func _build_camera() -> void:
	var framing: Array = VIEWS.get(view, VIEWS["horizon"])
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 75.0
	cam.far = 800.0
	cam.position = framing[0]
	cam.look_at(framing[1], Vector3.UP)
	cam.current = true


func _visual_height(node: Node) -> float:
	var tallest := 0.0
	if node is MeshInstance3D:
		tallest = (node as MeshInstance3D).get_aabb().size.y
	for child in node.get_children():
		tallest = maxf(tallest, _visual_height(child))
	return tallest


func _matte(albedo: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.roughness = roughness
	mat.metallic = 0.0
	return mat
