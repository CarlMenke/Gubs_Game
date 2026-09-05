extends SceneTree
## Numbers about the generated island that a screenshot cannot give you.
## Development tool, not shipped.
##
## A render says whether Whisperbloom Hollow looks right. It does not say whether
## a fifth of the walkable surface is too steep to run up, whether two spawn pads
## are eight metres apart, or how many triangles the scatter actually cost. This
## prints all of that, for one seed or for a sweep of them — because the map is a
## function of `Net.config.map_seed` (D-007) and "it works on the default seed"
## is not the same claim as "it works".
##
## Usage:
##   Godot --headless --path . --script tools/island_report.gd -- [seed] [count]

const DEFAULT_SEED := 20260904


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var first: int = int(args[0]) if args.size() >= 1 else DEFAULT_SEED
	var count: int = maxi(1, int(args[1])) if args.size() >= 2 else 1

	for i in count:
		_report(first + i * 977)
	quit()


func _report(map_seed: int) -> void:
	var island := IslandGenerator.new(map_seed)
	print("\n===== seed %d" % map_seed)
	print("  extent %.1f m across, %d landmasses" % [island.extent() * 2.0,
		island.landmasses.size()])
	for mass: IslandGenerator.Landmass in island.landmasses:
		print("    %-12s centre %6.1f,%6.1f  radius %.1f  base_y %+.1f  depth %.1f" % [
			mass.name, mass.centre.x, mass.centre.y, mass.base_radius,
			mass.base_height, mass.depth])

	_sample_surface(island)
	_mesh_stats(island)


## Walk a grid over the whole map and describe the ground: how high it goes, how
## steep it gets, and how much of it a Gub could actually run on.
func _sample_surface(island: IslandGenerator) -> void:
	var reach := island.extent()
	var step := 0.5
	var land := 0
	var walkable := 0
	var steep := 0
	var lowest := INF
	var highest := -INF
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			var h := island.height_at(x, z)
			if h > IslandGenerator.NO_LAND:
				land += 1
				lowest = minf(lowest, h)
				highest = maxf(highest, h)
				min_x = minf(min_x, x)
				max_x = maxf(max_x, x)
				min_z = minf(min_z, z)
				max_z = maxf(max_z, z)
				# tan(45°) = 1.0 is Godot's default floor_max_angle, so anything
				# past it is a wall as far as a CharacterBody3D is concerned.
				var slope := island.slope_at(x, z)
				if slope < 0.7:
					walkable += 1
				elif slope >= 1.0:
					steep += 1
			z += step
		x += step

	var area := float(land) * step * step
	# The span that matters is the real footprint, not the bounding disc: the
	# fog in `arena_env.tres` was tuned against "40-60 m across" (D-009), and an
	# off-centre islet inflates a disc radius without widening the map.
	print("  footprint %.1f x %.1f m  area %.0f m²  y from %+.2f to %+.2f (range %.2f)" % [
		max_x - min_x, max_z - min_z, area, lowest, highest, highest - lowest])
	print("  slope    %.1f%% comfortable (<35°), %.2f%% unwalkable (>=45°)" % [
		100.0 * float(walkable) / maxf(1.0, float(land)),
		100.0 * float(steep) / maxf(1.0, float(land))])


func _mesh_stats(island: IslandGenerator) -> void:
	var root := Node3D.new()
	island.build_into(root)
	var tris := 0
	var verts := 0
	for chunk in root.get_children():
		var visual := chunk.get_node_or_null("Terrain") as MeshInstance3D
		if visual == null:
			continue
		for s in visual.mesh.get_surface_count():
			var arrays := visual.mesh.surface_get_arrays(s)
			var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			verts += points.size()
			# The faceted underside carries no index buffer at all, so its
			# triangle count is its vertex count over three.
			var indices: Variant = arrays[Mesh.ARRAY_INDEX]
			tris += (int((indices as PackedInt32Array).size()) if indices != null
				else points.size()) / 3
	print("  terrain  %d triangles, %d vertices" % [tris, verts])

	# Which way the top surface faces. Getting this wrong is not a subtle bug and
	# it is not a visible one either: a terrain whose normals point down is lit
	# by the *lower* hemisphere of the sky — the void colour — so it renders
	# pure black while every prop standing on it lights normally, and it looks
	# for all the world like a fog problem.
	var terrain := (root.get_child(0) as Node3D).get_node("Terrain") as MeshInstance3D
	for surface in terrain.mesh.get_surface_count():
		var arrays := terrain.mesh.surface_get_arrays(surface)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var up := 0
		for i in normals.size():
			if normals[i].y > 0.0:
				up += 1
		if normals.size() == 0:
			continue
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var mean := Color(0, 0, 0)
		for c: Color in colours:
			mean += c
		if colours.size() > 0:
			mean /= float(colours.size())
		print("  surface %d: %d/%d normals up; v1 %v n %v; %d colours, mean %s" % [
			surface, up, normals.size(), points[1], normals[1], colours.size(),
			mean.to_html(false)])
		var mat := terrain.mesh.surface_get_material(surface) as StandardMaterial3D
		print("           material albedo %s vertex_color_as_albedo=%s format=%d" % [
			mat.albedo_color.to_html(false), mat.vertex_color_use_as_albedo,
			terrain.mesh.surface_get_format(surface)])
	root.free()
