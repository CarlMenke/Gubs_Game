extends Node3D
## Lines the decimated meshes up under a neutral light so the results of
## `tools/decimate_assets.py` can be eyeballed. Development tool, not shipped.

const MODELS := [
	"res://art/generated/gub.glb",
	"res://art/generated/spear.glb",
	"res://art/generated/lure.glb",
	"res://art/generated/mushroom.glb",
]

## Which frame of which animation to pose the Gub in, so the preview shows the
## skin weights doing something rather than a T-pose.
@export var gub_animation: String = "Idle"
@export var gub_animation_time: float = 1.6
@export var spacing: float = 2.6


func _ready() -> void:
	var x := -spacing * (MODELS.size() - 1) * 0.5
	for path in MODELS:
		var packed := load(path) as PackedScene
		if packed == null:
			push_error("preview: missing %s" % path)
			continue
		var node := packed.instantiate() as Node3D
		add_child(node)

		# Normalise every model to roughly two metres tall so they can be
		# compared side by side regardless of their authored scale.
		var extent := _visual_height(node)
		if extent > 0.0:
			node.scale = Vector3.ONE * (2.0 / extent)
		node.position = Vector3(x, 0.0, 0.0)
		x += spacing

		_pose(node)

	_build_stage()


func _visual_height(node: Node3D) -> float:
	var tallest := 0.0
	for mesh in _find_meshes(node):
		var aabb := mesh.get_aabb()
		tallest = maxf(tallest, aabb.size.y)
	return tallest


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_find_meshes(child))
	return out


func _pose(node: Node3D) -> void:
	var player := node.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null:
		return
	if not player.has_animation(gub_animation):
		print("preview: %s has no animation '%s' (has %s)"
			% [node.name, gub_animation, player.get_animation_list()])
		return
	print("preview: posing %s with '%s' at %.2fs" % [node.name, gub_animation, gub_animation_time])
	player.play(gub_animation)
	player.advance(gub_animation_time)
	player.pause()


func _build_stage() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.1, 0.11)
	mat.roughness = 0.95
	plane.material = mat
	ground.mesh = plane
	add_child(ground)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -38, 0)
	key.light_energy = 2.0
	key.shadow_enabled = true
	add_child(key)

	var fill := OmniLight3D.new()
	fill.position = Vector3(-4, 2.5, 5)
	fill.light_energy = 3.0
	fill.omni_range = 22.0
	fill.light_color = Color(0.65, 0.8, 1.0)
	add_child(fill)

	var cam := Camera3D.new()
	cam.position = Vector3(0.4, 1.7, 8.6)
	cam.rotation_degrees = Vector3(-5, 0, 0)
	cam.fov = 45.0
	add_child(cam)
	cam.make_current()
