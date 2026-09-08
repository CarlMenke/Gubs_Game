extends Node3D
## Look at a hand-made map, and check it is standable. Development tool, not
## shipped.
##
## A static map is the opposite problem from the island. `tools/preview_island`
## exists because Whisperbloom Hollow does not exist until `arena.gd` runs it;
## Rust exists on disk, and the problem is that nobody can *see* it from a
## terminal — and the eight spawn pads were typed in as coordinates by somebody
## who could not see it either. So this does two things at once:
##
##   * **Renders** the map from an orthographic top-down or side view with a
##     coloured marker on every spawn pad, or from eye height on one of those
##     pads looking at the middle of the arena, which is the only framing a
##     player will ever actually have.
##   * **Checks** every pad against the physics the match will use: a ray down
##     onto layer 1 that has to find a floor, and a Gub-sized capsule that has
##     to fit where the Gub will stand. Those two are the whole difference
##     between "the marker looks fine in the render" and "the marker is inside
##     a shipping container".
##
## The `probe` view scans the floor on a grid instead and prints it as three
## ASCII maps: how high the ground is, whether a Gub fits standing there, and
## how far you could see toward the middle of the map from it. The third one is
## the one that earns its place — two of Rust's first eight pads passed every
## geometric test and opened onto a container wall a metre in front of them.
## That is how the pads in `rust.tscn` were found, and it is the thing to run
## again after any change to the geometry.
##
## Usage:
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://tools/preview_map.tscn out.png <ticks> <view> [map=res://map.tscn]
##
##   views: top  side  front  probe  pad0 .. pad7
##
## Everything before the render is printed, so this is also a headless check —
## `tools/smoke_test.sh` greps it for `preview_map: PASS`.

## The map this looks at unless a `res://…` argument names another one. Static
## maps are the kind of thing there will be more than one of, and the second one
## should not need a second copy of this file.
const DEFAULT_MAP := "res://scenes/world/maps/rust.tscn"

## What a Gub is, physically. Taken from `Gub` rather than typed, so a change to
## the character's size fails this check instead of quietly invalidating it.
const CAPSULE_RADIUS := Gub.CAPSULE_RADIUS
const CAPSULE_HEIGHT := Gub.STAND_HEIGHT
## Where the capsule's centre sits above the Gub's origin — the offset on the
## `Collision` node in `gub.tscn`. A test run at the pad itself would be a
## capsule buried half a metre in the floor and would fail on every pad.
const CAPSULE_LIFT := 0.775

const LAYER_WORLD := 1

## How far below a marker a floor is allowed to be before the pad counts as
## hanging in the air. The markers are lifted 0.12 m off the ground, so 2.5 m is
## a wide margin around a number that should be almost exactly that.
const FLOOR_REACH := 2.5
const FLOOR_LIFT := 2.0

## Two pads closer together than this are one pad with a rounding error in it.
const PAD_SEPARATION := 6.0

## A map that comes out under this many triangles did not import — the arena is
## 96,301 of them and there is no way to lose a third of that by accident.
const MIN_TRIANGLES := 90000

## The grid the `probe` view walks, in metres. Two is fine enough to find a
## four-metre gap between containers and coarse enough that the map fits in a
## terminal.
const PROBE_STEP := 2.0
## Probing starts here rather than from the sky, so a catwalk six metres up does
## not hide the floor underneath it. Every walkable surface in this arena is
## below 3 m except the catwalks and the tower, and spawns belong on neither.
const PROBE_CEILING := 3.0
const PROBE_FLOOR := -3.0

const VIEWS := ["top", "side", "front", "probe"]

var _view: String = "top"
var _map_path: String = DEFAULT_MAP
var _map: StaticMap
var _spawns: Array[Transform3D] = []
var _centre: Vector3 = Vector3.ZERO
var _bounds: AABB
var _checks: int = 0
var _failures: int = 0
var _reported: bool = false


func _ready() -> void:
	# `map=res://…` rather than a bare path. `get_cmdline_user_args()` hands back
	# everything after the `--`, which under `tools/snapshot.gd` starts with the
	# path of *this* scene — so a rule of "any argument that looks like a scene
	# is the map" makes this tool load itself, for as many frames as the stack
	# will hold.
	for arg: String in OS.get_cmdline_user_args():
		if VIEWS.has(arg) or arg.begins_with("pad"):
			_view = arg
		elif arg.begins_with("map="):
			_map_path = arg.trim_prefix("map=")

	var packed := load(_map_path) as PackedScene
	if packed == null:
		_fail("the map scene loads (%s)" % _map_path)
		return
	var instanced := packed.instantiate()
	# Renamed exactly as `arena.gd` renames it, so anything that reads the node
	# name — the map's own build log line, most obviously — says the same thing
	# here as it does in a match.
	instanced.name = "Map"
	add_child(instanced)
	_map = instanced as StaticMap
	if _map == null:
		_fail("the map's root is a StaticMap")
		return

	_bounds = _world_bounds()
	_centre = Vector3(_bounds.get_center().x, 1.7, _bounds.get_center().z)
	_spawns = _map.spawn_points()
	_draw_pads()
	_build_camera()
	print("preview_map: %s — bounds %s to %s, centre %s" % [_map_path,
		_vec(_bounds.position), _vec(_bounds.end), _vec(_centre)])


## The physics has to have ticked at least once before the map's static body is
## in the broadphase, so every query below waits for it rather than running from
## `_ready` and reporting an empty world.
func _physics_process(_delta: float) -> void:
	if _reported:
		return
	if Engine.get_physics_frames() < 3:
		return
	_reported = true
	if _view == "probe":
		_probe()
	_check_build()
	_check_spawns()
	print("preview_map: %d checks, %d failures" % [_checks, _failures])
	print("preview_map: %s" % ("PASS" if _failures == 0 else "FAIL"))


# ------------------------------------------------------------------ checks ---

## The map built the thing the match needs from it.
func _check_build() -> void:
	_want("the geometry imported (%d triangles)" % _map.triangles,
		_map.triangles > MIN_TRIANGLES)
	_want("collision was built (%d shapes)" % _map.shapes, _map.shapes > 0)
	var body := _map.get_node_or_null("Collision") as StaticBody3D
	if _want("there is a Collision body", body != null):
		_want("collision is on layer 1, world", body.collision_layer == LAYER_WORLD)
		_want("the world scans for nothing itself", body.collision_mask == 0)
	_want("the map brought an Environment",
		_map.get_node_or_null("Environment") is WorldEnvironment)
	_want("the map brought a Sun", _map.get_node_or_null("Sun") is DirectionalLight3D)
	_want("eight spawn pads", _spawns.size() == MatchConfig.MAX_PLAYERS)


## Every pad, against the physics a Gub will actually meet there.
func _check_spawns() -> void:
	var space := get_world_3d().direct_space_state
	for i in _spawns.size():
		var pad := _spawns[i]
		var at := pad.origin

		# A floor under it. Cast from above rather than from the pad itself: a
		# marker sunk a centimetre into the ground would start the ray inside
		# the triangle it needs to find and report nothing at all.
		var ray := PhysicsRayQueryParameters3D.create(
			at + Vector3.UP * FLOOR_LIFT, at + Vector3.UP * (FLOOR_LIFT - FLOOR_REACH))
		ray.collision_mask = LAYER_WORLD
		var hit := space.intersect_ray(ray)
		var floor_y := INF if hit.is_empty() else float(hit["position"].y)
		var drop := INF if hit.is_empty() else at.y - floor_y
		_want("pad %d stands on a floor (%.2f m below it)" % [i, drop], not hit.is_empty())

		# And room to stand. The same capsule `gub.tscn` carries, at the height
		# `gub.tscn` carries it at.
		var capsule := CapsuleShape3D.new()
		capsule.radius = CAPSULE_RADIUS
		capsule.height = CAPSULE_HEIGHT
		var shape := PhysicsShapeQueryParameters3D.new()
		shape.shape = capsule
		shape.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * CAPSULE_LIFT)
		shape.collision_mask = LAYER_WORLD
		var overlaps := space.intersect_shape(shape, 4)
		_want("pad %d is not inside anything" % i, overlaps.is_empty())

		# Facing the middle. Not a rendering nicety: a player whose first frame
		# is a wall has to turn around before they can read the map.
		var want_yaw := Gub.yaw_towards(
			(_centre - at).normalized() * Vector3(1.0, 0.0, 1.0))
		var off := rad_to_deg(absf(angle_difference(pad.basis.get_euler().y, want_yaw)))
		_want("pad %d faces the middle (%.0f deg off)" % [i, off], off < 60.0)

		for j in range(i + 1, _spawns.size()):
			var gap := at.distance_to(_spawns[j].origin)
			_want("pads %d and %d are apart (%.1f m)" % [i, j, gap],
				gap >= PAD_SEPARATION)

		# How far a Gub standing here can actually see down its own nose.
		# Reported rather than asserted: Rust is a yard full of shipping
		# containers and some pads are always going to open onto one, but a pad
		# with three metres of sightline is a pad that should be moved, and
		# there is no way to notice that from a coordinate.
		var eye := at + Vector3.UP * 1.45
		var look := PhysicsRayQueryParameters3D.create(
			eye, eye + (pad.basis * Vector3.FORWARD).normalized() * 60.0)
		look.collision_mask = LAYER_WORLD
		var wall := space.intersect_ray(look)
		var sight := 60.0 if wall.is_empty() else eye.distance_to(wall["position"])

		print("  pad %d  %s  yaw %6.1f deg  floor y %.3f (%.2f below)  sees %5.1f m" % [
			i, _vec(at), rad_to_deg(pad.basis.get_euler().y), floor_y, drop, sight])


# ------------------------------------------------------------------- probe ---

## Walk the floor on a grid and print what is there.
##
## Two maps, because the two questions are different. The first is *how high the
## ground is*, which is what tells the main plane at 1.70 apart from the second
## tier and the catwalk footings. The second is *whether a Gub fits*, which is
## the one that matters and which no amount of looking at heights will answer —
## a pad can be on perfectly flat floor and still be inside a barrel.
func _probe() -> void:
	var space := get_world_3d().direct_space_state
	var capsule := CapsuleShape3D.new()
	capsule.radius = CAPSULE_RADIUS
	capsule.height = CAPSULE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = LAYER_WORLD

	var x0 := floorf(_bounds.position.x / PROBE_STEP) * PROBE_STEP
	var z0 := floorf(_bounds.position.z / PROBE_STEP) * PROBE_STEP
	var columns := int((_bounds.end.x - x0) / PROBE_STEP) + 1
	var rows := int((_bounds.end.z - z0) / PROBE_STEP) + 1

	var heights: Array[String] = []
	var clearance: Array[String] = []
	var sightlines: Array[String] = []
	for r in rows:
		var z := z0 + float(r) * PROBE_STEP
		var height_row := ""
		var clear_row := ""
		var sight_row := ""
		for c in columns:
			var x := x0 + float(c) * PROBE_STEP
			var ray := PhysicsRayQueryParameters3D.create(
				Vector3(x, PROBE_CEILING, z), Vector3(x, PROBE_FLOOR, z))
			ray.collision_mask = LAYER_WORLD
			var hit := space.intersect_ray(ray)
			if hit.is_empty():
				height_row += " "
				clear_row += " "
				sight_row += " "
				continue
			var y := float(hit["position"].y)
			height_row += _height_glyph(y)
			query.transform = Transform3D(Basis.IDENTITY,
				Vector3(x, y + 0.12 + CAPSULE_LIFT, z))
			var free := space.intersect_shape(query, 1).is_empty()
			clear_row += "." if free else "#"
			sight_row += "#" if not free else _sight_glyph(
				_sight_from(space, Vector3(x, y + 0.12, z)))
		heights.append(height_row)
		clearance.append(clear_row)
		sightlines.append(sight_row)

	print("probe: x %.0f .. %.0f, z %.0f .. %.0f, step %.1f m" % [
		x0, x0 + float(columns - 1) * PROBE_STEP, z0,
		z0 + float(rows - 1) * PROBE_STEP, PROBE_STEP])
	print("probe: heights — '-' is the main plane at 1.7, digits are whole metres,")
	print("       ' ' is no floor within reach of the scan")
	_print_grid(heights, x0, z0, columns)
	print("probe: clearance — '.' a Gub fits, '#' something is in the way")
	_print_grid(clearance, x0, z0, columns)
	print("probe: sightline toward the middle at eye height, in fives of metres —")
	print("       '0' is a wall in your face, '9' is forty-five metres of yard")
	_print_grid(sightlines, x0, z0, columns)


## How far a Gub standing here could see toward the middle of the map. The one
## thing a top-down picture cannot tell you and a coordinate certainly cannot:
## a pad can be on flat open floor with a container three metres in front of it.
func _sight_from(space: PhysicsDirectSpaceState3D, foot: Vector3) -> float:
	var eye := foot + Vector3.UP * 1.45
	var toward := (_centre + Vector3.UP * 0.6) - eye
	if toward.length() < 0.5:
		return 60.0
	var ray := PhysicsRayQueryParameters3D.create(eye, eye + toward.normalized() * 60.0)
	ray.collision_mask = LAYER_WORLD
	var hit := space.intersect_ray(ray)
	return 60.0 if hit.is_empty() else eye.distance_to(hit["position"])


func _sight_glyph(metres: float) -> String:
	return "0123456789"[clampi(int(metres / 5.0), 0, 9)]


func _height_glyph(y: float) -> String:
	if y < 0.5:
		return "_"
	if y < 1.9:
		return "-"   # the main walkable plane, ~1.70
	if y < 2.4:
		return "="   # the second tier, ~2.0
	return "0123456789ABCDEFGH"[clampi(int(y), 2, 17)]


func _print_grid(grid: Array[String], x0: float, z0: float, columns: int) -> void:
	var ruler := "      "
	for c in columns:
		ruler += "|" if int(x0 + float(c) * PROBE_STEP) % 10 == 0 else " "
	print(ruler)
	for r in grid.size():
		print("%5d %s" % [int(z0 + float(r) * PROBE_STEP), grid[r]])
	print(ruler)


# ----------------------------------------------------------------- drawing ---

## A coloured ball on every pad and a stick out of the front of it, so the
## render answers "where are they" and "which way do they face" at once.
func _draw_pads() -> void:
	var pads := Node3D.new()
	pads.name = "Pads"
	add_child(pads)
	for i in _spawns.size():
		var pad := _spawns[i]
		# Hue spread across the eight, so a pad can be named from the picture.
		var tint := Color.from_hsv(float(i) / float(_spawns.size()), 0.9, 1.0)
		var ball := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.55
		sphere.height = 1.1
		ball.mesh = sphere
		ball.material_override = _flat(tint)
		ball.position = pad.origin + Vector3.UP * 1.0
		pads.add_child(ball)

		var stick := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.16, 0.16, 2.6)
		stick.mesh = box
		stick.material_override = _flat(tint.darkened(0.35))
		# Pushed forward along the pad's own -Z, which is the direction
		# `revive_at` will point the Gub in.
		stick.transform = Transform3D(pad.basis, pad.origin + Vector3.UP * 1.0)
		stick.translate_object_local(Vector3(0.0, 0.0, -1.7))
		pads.add_child(stick)


## Take one pad's ball and stick back out of the picture. They are added in
## pairs, in order, so a pad's two nodes are the two at twice its index.
func _hide_pad(index: int) -> void:
	var pads := get_node_or_null("Pads")
	if pads == null:
		return
	for i in [index * 2, index * 2 + 1]:
		if i < pads.get_child_count():
			(pads.get_child(i) as Node3D).visible = false


func _flat(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = tint
	# Drawn on top of the geometry: a marker hidden behind a container tells you
	# nothing, and the point of the shot is to see all eight at once.
	material.no_depth_test = true
	return material


# ----------------------------------------------------------------- framing ---

func _build_camera() -> void:
	var camera := Camera3D.new()
	camera.far = 400.0
	add_child(camera)
	var span := maxf(_bounds.size.x, _bounds.size.z) + 6.0

	if _view.begins_with("pad"):
		var index := clampi(int(_view.trim_prefix("pad")), 0, maxi(0, _spawns.size() - 1))
		if _spawns.is_empty():
			return
		# The camera stands *in* this pad's marker, so that one marker comes back
		# out again — otherwise the shot is a full-screen coloured stick and the
		# view it was taken for is behind it.
		_hide_pad(index)
		# Eye height on the pad, looking where the Gub spawned there is looking.
		var eye := _spawns[index].origin + Vector3.UP * 1.45
		camera.fov = 75.0
		camera.look_at_from_position(eye, _centre + Vector3.UP * 0.6, Vector3.UP)
		camera.make_current()
		return

	# Orthographic, and as close to the geometry as the framing allows: `size`
	# does the framing, so distance buys nothing but fog. Sixty metres back put
	# the whole arena behind a wall of haze and made the map look like it was
	# lit wrong when it was only far away.
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = span
	match _view:
		"side":
			# Across the short axis from +X, so the catwalk tiers and the
			# tower's 27 m read as heights rather than as clutter.
			camera.look_at_from_position(
				Vector3(_bounds.end.x + 8.0, 12.0, _centre.z),
				Vector3(_centre.x, 12.0, _centre.z), Vector3.UP)
		"front":
			camera.look_at_from_position(
				Vector3(_centre.x, 12.0, _bounds.end.z + 8.0),
				Vector3(_centre.x, 12.0, _centre.z), Vector3.UP)
		_:
			# Straight down. `Vector3.UP` is degenerate as an up vector for a
			# camera that is already looking along it, so -Z is used instead,
			# which also puts the far end of the arena at the top of the image.
			camera.look_at_from_position(
				Vector3(_centre.x, _bounds.end.y + 8.0, _centre.z),
				Vector3(_centre.x, 0.0, _centre.z), Vector3.FORWARD)
	camera.make_current()


# ----------------------------------------------------------------- harness ---

## The world-space box the geometry occupies, from the meshes rather than from
## the collision body — the collision is built *from* the meshes, so measuring
## it instead would be measuring this tool's own output.
func _world_bounds() -> AABB:
	var box := AABB()
	var first := true
	for node in _meshes(_map):
		var world := node.global_transform * node.get_aabb()
		if first:
			box = world
			first = false
		else:
			box = box.merge(world)
	return box


func _meshes(from: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var node := from as MeshInstance3D
	if node != null and node.mesh != null:
		out.append(node)
	for child in from.get_children():
		out.append_array(_meshes(child))
	return out


func _want(what: String, ok: bool) -> bool:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL  %s" % what)
	return ok


func _fail(what: String) -> void:
	_reported = true
	_checks += 1
	_failures += 1
	print("  FAIL  %s" % what)
	print("preview_map: %d checks, %d failures" % [_checks, _failures])
	print("preview_map: FAIL")


func _vec(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]
