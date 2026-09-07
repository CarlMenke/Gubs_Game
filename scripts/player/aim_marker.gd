class_name AimMarker
extends MeshInstance3D
## The ring on the ground showing where a spear thrown right now would land.
##
## Spears drop — at a third of world gravity, but over twenty metres that is
## still most of a Gub's height, and the playtest question was exactly this:
## "I wish I knew where my spear was going, does it have drop?" A crosshair
## cannot answer that, because the crosshair is a point on a ray and the spear
## flies a parabola. So the answer is drawn in the world instead of on the HUD.
##
## The path is not approximated with a closed-form parabola. It is the
## projectile's own integration loop, one physics step at a time, with the same
## speed, the same gravity, the same collision mask and the same exclusion of
## the thrower — because the only thing worse than no drop indicator is one that
## disagrees with the spear. Euler integration is step-size dependent, so
## matching the step matters as much as matching the constants: predict at
## 30 Hz and the marker sits metres from where the spear actually lands.
##
## Local, cosmetic and off the network entirely. Only the Gub you are driving
## ever has one, nothing about it is replicated, and it exists only while the
## right mouse button is down.

## Radii of the two rings. The dark one is drawn first and slightly wider on
## both edges, so the yellow one always has an edge against whatever is behind
## it — the same trick the nameplate's outline plays, and for the same reason:
## this has to read on sunlit grass and on wet rock without changing colour.
const OUTLINE_INNER := 0.24
const OUTLINE_OUTER := 0.50
const RING_INNER := 0.29
const RING_OUTER := 0.45
const SEGMENTS := 32

## How high the ring's outer edge is drawn up into the air.
##
## A ring lying flat on the ground is the right idea and, on its own, close to
## useless: you look at it from eye height along a nearly flat throw, so it is
## foreshortened to a line about one pixel tall at the ranges anyone actually
## throws from. The band standing up off its rim is what gives the marker any
## screen area at all from behind the thrower — a vertical surface is never
## edge-on to a camera that is roughly level with it. Kept low so the thing
## still reads as a mark on the ground and not as a fence post.
const WALL_HEIGHT := 0.25

## The Gub's own yellow, the crosshair's colour (`UIPalette.GUB`). Hardcoded
## rather than imported: this is the one thing in `scripts/player` that would
## otherwise reach into `scripts/ui`, and the crosshair and the marker being the
## same yellow is what says they are two halves of one aim.
const RING_COLOUR := Color(1.00, 0.84, 0.26, 0.95)
const OUTLINE_COLOUR := Color(0.02, 0.03, 0.04, 0.70)

## How far off the surface the ring floats. Enough to clear z-fighting on a
## slope, small enough that it still reads as lying on the ground.
const LIFT := 0.035


func _ready() -> void:
	# Placed in world space from a predicted point; the Gub it hangs off is
	# moving and turning and must not drag it around.
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh = _build_rings()
	material_override = _make_material()
	visible = false


## Predict where a spear launched from `origin` along `direction` lands, and put
## the ring there. Hides itself if the throw hits nothing at all — off the edge
## of the island, or into the sky — because a marker that has to guess is worse
## than no marker.
func aim(origin: Vector3, direction: Vector3, exclude: RID) -> void:
	var hit := _predict(origin, direction, exclude)
	if hit.is_empty():
		visible = false
		return
	_place(hit["position"], hit["normal"])
	visible = true


func stow() -> void:
	visible = false


## The projectile's flight, run forward until something stops it.
##
## The step is read from the engine rather than written down, because the thing
## it has to match is `SpearProjectile._physics_process`'s `delta`. In practice
## this loop ends within a second — a spear aimed anywhere on the ground is down
## in well under sixty steps — and only a throw at the open sky or off the rim
## of the island runs the full lifetime before giving up.
func _predict(origin: Vector3, direction: Vector3, exclude: RID) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var step := 1.0 / maxf(1.0, float(Engine.physics_ticks_per_second))
	var steps := int(SpearProjectile.MAX_LIFETIME / step)
	var velocity := direction.normalized() * SpearProjectile.SPEED
	var point := origin

	for _i in steps:
		velocity.y -= SpearProjectile.DROP * step
		var next := point + velocity * step
		var query := PhysicsRayQueryParameters3D.create(point, next)
		query.collision_mask = SpearProjectile.LAYER_WORLD \
			| SpearProjectile.LAYER_PLAYER | SpearProjectile.LAYER_DEPLOYABLE
		query.collide_with_areas = false
		query.collide_with_bodies = true
		if exclude.is_valid():
			query.exclude = [exclude]
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			return hit
		point = next
	return {}


## Lay the ring flat on the surface it found. Built in the XZ plane, so aligning
## its +Y with the surface normal is the whole of it — which also means the ring
## leans over on a slope and against a wall instead of cutting into it.
func _place(point: Vector3, normal: Vector3) -> void:
	var up := normal if normal.length_squared() > 0.001 else Vector3.UP
	up = up.normalized()
	# Any perpendicular will do for the ring's own spin; a circle has no
	# orientation to get wrong. Two candidates so the cross product never
	# degenerates on a vertical or a horizontal surface.
	var reference := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var side := up.cross(reference).normalized()
	global_transform = Transform3D(Basis(side, up, side.cross(up)), point + up * LIFT)


func _build_rings() -> ImmediateMesh:
	var built := ImmediateMesh.new()
	_add_ring(built, OUTLINE_INNER, OUTLINE_OUTER, OUTLINE_COLOUR)
	_add_ring(built, RING_INNER, RING_OUTER, RING_COLOUR)
	_add_wall(built)
	return built


## The band standing up from the ring's rim, bright at the ground and gone by
## the top, so it reads as light coming off the spot rather than as a wall
## around it.
func _add_wall(into: ImmediateMesh) -> void:
	var top := Color(RING_COLOUR.r, RING_COLOUR.g, RING_COLOUR.b, 0.0)
	into.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in SEGMENTS + 1:
		var angle := TAU * float(i) / float(SEGMENTS)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		into.surface_set_color(RING_COLOUR)
		into.surface_add_vertex(direction * RING_OUTER)
		into.surface_set_color(top)
		into.surface_add_vertex(direction * RING_OUTER + Vector3.UP * WALL_HEIGHT)
	into.surface_end()


## One flat annulus as a triangle strip, alternating inner and outer rim. Built
## once in `_ready` and then only ever moved, because the ring never changes
## size — the whole point of it is that a landing spot is a landing spot.
func _add_ring(into: ImmediateMesh, inner: float, outer: float, tint: Color) -> void:
	into.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in SEGMENTS + 1:
		var angle := TAU * float(i) / float(SEGMENTS)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		into.surface_set_color(tint)
		into.surface_add_vertex(direction * inner)
		into.surface_set_color(tint)
		into.surface_add_vertex(direction * outer)
	into.surface_end()


## Unshaded and depth-tested. Unshaded because a marker that dims in shadow is
## least visible exactly where it is most needed; depth-tested because a landing
## spot behind a rock is not a landing spot you get to see, and drawing it
## through the rock would be the same wallhack the nameplate refuses to be.
func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	material.no_depth_test = false
	material.render_priority = 2
	return material
