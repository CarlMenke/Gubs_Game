extends SceneTree
## Print the node tree, animations and mesh stats of an imported scene.
## Usage: Godot --headless --path . --script tools/inspect_scene.gd -- res://path.glb

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for path in args:
		var packed := load(path) as PackedScene
		if packed == null:
			print("!! could not load ", path)
			continue
		var root_node := packed.instantiate()
		print("\n===== ", path)
		_dump(root_node, 0)
		for player in _find(root_node, "AnimationPlayer"):
			var ap := player as AnimationPlayer
			print("  AnimationPlayer '", ap.name, "' libraries=", ap.get_animation_library_list())
			for anim in ap.get_animation_list():
				var a := ap.get_animation(anim)
				print("    %-24s len=%.2f loop=%s tracks=%d" % [anim, a.length, a.loop_mode, a.get_track_count()])
		for skel in _find(root_node, "Skeleton3D"):
			var s := skel as Skeleton3D
			print("  Skeleton3D '", s.name, "' bones=", s.get_bone_count())
			var names := []
			for i in s.get_bone_count():
				names.append(s.get_bone_name(i))
			print("    ", ", ".join(names))
		root_node.free()
	quit()

func _dump(node: Node, depth: int) -> void:
	var extra := ""
	if node is MeshInstance3D and node.mesh != null:
		var faces := 0
		for si in node.mesh.get_surface_count():
			faces += node.mesh.surface_get_arrays(si)[Mesh.ARRAY_INDEX].size() / 3
		extra = "  [%d tris, %d surfaces, aabb %s]" % [faces, node.mesh.get_surface_count(),
			str(node.mesh.get_aabb().size).pad_decimals(2)]
	print("  ", "  ".repeat(depth), node.name, " : ", node.get_class(), extra)
	for child in node.get_children():
		_dump(child, depth + 1)

func _find(node: Node, cls: String) -> Array:
	var out := []
	if node.is_class(cls):
		out.append(node)
	for child in node.get_children():
		out.append_array(_find(child, cls))
	return out
