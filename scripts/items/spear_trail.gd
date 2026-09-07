class_name SpearTrail
extends MeshInstance3D
## The streak a thrown spear leaves behind it.
##
## A ribbon built by hand into an `ImmediateMesh` from the last few positions of
## the tip, rather than a particle emitter. Particles are the obvious choice and
## the wrong one here: the spear moves 0.7 m per physics tick, so a stream of
## billboards is a dotted line of blobs at exactly the speed it most needs to
## read as a continuous streak. A ribbon is also the cheaper thing — one draw
## call, no simulation — and the fight can have eight of these in the air.
##
## The ribbon is built in world space (`top_level`), because a strip that is
## rebuilt from world positions must not then be transformed again by the
## spear's own rotation as it turns to face its travel.

## How many past positions make up the ribbon. At 60 Hz this is 0.4 s of
## flight — about seventeen metres at 42 m/s.
##
## It was twelve, which is half that, and half that was not enough: the single
## loudest thing the playtesters said was that they could not see the spear at
## all. A fifth of a second of streak on an object that crosses the screen in
## well under a second is a flick you notice after it has gone past. Doubling it
## means that at any moment during a mid-range throw there is a line on screen
## running from roughly the thrower's hand to the spear, which is what makes the
## shot readable — both to whoever threw it and to whoever it is coming at.
##
## It is still short enough to outlive nothing: the ribbon is bounded by flight
## time, not by distance, so it shortens itself as the spear slows and is gone
## within 0.4 s of the impact.
const SAMPLES := 24
## Half-width of the ribbon at the head, tapering to nothing at the tail. Up
## from 0.055 for the same reason as `SAMPLES` — at twenty metres the old ribbon
## was under a pixel wide and the additive blend had nothing to add to.
const HALF_WIDTH := 0.09
## Below this the spear is stuck or barely moving and the trail is just a smear
## sitting on the ground.
const MIN_SPEED := 4.0

## Warm and near-white at the head rather than the pale blue it was. The arena
## is a night forest lit by torches: a cold blue streak sat in the same range as
## the sky and the fog and disappeared into both, and warm light is also what
## every other thing in this game that matters is coloured — the crosshair, the
## cooldown ring, the torches. `HEAD_ALPHA` is what the additive blend gets at
## the spear itself; the rest of the ribbon is scaled off it.
const COLOUR := Color(1.0, 0.87, 0.58)
const HEAD_ALPHA := 1.0
## How sharply the ribbon gives up its brightness behind the head. Squared —
## which is what this was — puts almost everything in the front quarter and
## wastes the extra length; this holds the streak together for about half its
## span and then drops it.
const FADE_POWER := 1.4

var _points: PackedVector3Array = PackedVector3Array()
var _mesh: ImmediateMesh
var _fading: bool = false


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh = ImmediateMesh.new()
	mesh = _mesh
	material_override = _make_material()


## Additive and unshaded: the trail is light, not a surface. Vertex colours carry
## the taper, so one material serves every spear in the air.
func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	material.no_depth_test = false
	material.albedo_color = Color(COLOUR.r, COLOUR.g, COLOUR.b, 1.0)
	return material


## Feed the trail one more tip position. Called from the spear's own integration
## so the samples land exactly on the flight path rather than a frame behind it.
func push_point(world_point: Vector3) -> void:
	_points.push_back(world_point)
	while _points.size() > SAMPLES:
		_points.remove_at(0)
	_rebuild()


## Stop adding points and let the ribbon shorten itself to nothing, so a spear
## that hits a wall does not leave a streak hanging in the air.
func begin_fade() -> void:
	_fading = true


func _process(_delta: float) -> void:
	if not _fading:
		return
	if _points.size() <= 2:
		queue_free()
		return
	_points.remove_at(0)
	_rebuild()


func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _points.size() < 2:
		return

	var camera := get_viewport().get_camera_3d()
	var eye := camera.global_position if camera != null else global_position

	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in _points.size():
		var point := _points[i]
		# Along the ribbon, from this sample to the next (or from the previous
		# one at the very end).
		var along: Vector3
		if i < _points.size() - 1:
			along = _points[i + 1] - point
		else:
			along = point - _points[i - 1]
		if along.length_squared() < 0.000001:
			continue
		# Widen across the view, so the ribbon faces the camera however the
		# spear is turning.
		var side := along.normalized().cross((point - eye).normalized())
		if side.length_squared() < 0.000001:
			continue
		side = side.normalized()

		# 0 at the oldest sample, 1 at the newest: the trail is brightest and
		# widest at the spear and vanishes behind it.
		var t := float(i) / float(_points.size() - 1)
		var width := HALF_WIDTH * t
		var tint := Color(COLOUR.r, COLOUR.g, COLOUR.b,
			pow(t, FADE_POWER) * HEAD_ALPHA)
		_mesh.surface_set_color(tint)
		_mesh.surface_add_vertex(point + side * width)
		_mesh.surface_set_color(tint)
		_mesh.surface_add_vertex(point - side * width)
	_mesh.surface_end()
