class_name StaticMap
extends Node3D
## The wrapper a hand-made map scene puts around its geometry, and the only
## thing `arena.gd` knows about one.
##
## Whisperbloom Hollow is generated (D-007), so it can answer questions about
## itself: `IslandGenerator` is a height oracle, and the spawn ring is *solved*
## against it. A bought `.glb` answers nothing — it is a pile of triangles — so
## the scene wrapped around it has to state the things the match needs instead.
## The arena reads exactly two things from a static map, where to put people and
## where the bottom is, and both are stated by the scene rather than derived.
##
## What the scene cannot state is collision, because an imported `.glb` has none
## and the importer's `-col` name suffix cannot be trusted on this geometry
## (D-031). So this script builds it, at load, in world space — that and a
## culling pass over the imported materials is the whole of the code here.
##
## The contract a map scene has to satisfy, which `arena.gd` will push an error
## rather than guess at:
##
## - The scene's **root** is a `Node3D` carrying this script. `arena.gd`
##   instances it, renames it `Map` and parents it to the arena, so the map is
##   in the tree before `spawn_points()` is called — which is what makes
##   `global_transform` on the markers mean anything.
## - **Geometry somewhere under the root.** Every `MeshInstance3D` in the
##   subtree is swept into the trimesh body this script builds on physics
##   layer 1, `world`. That is the layer Gubs, spears, deployables and the
##   camera probe all collide against (`project.godot` names it). A map on any
##   other layer is a map players fall straight through, and it will look like
##   the map failed to load.
## - A **`WorldEnvironment` child named `Environment`** and a
##   **`DirectionalLight3D` named `Sun`**. `arena.gd` builds neither for a
##   static map on purpose: the island's environment and its 0.30-energy moon
##   are tuned around torches being the key light (D-009), and dropping a
##   daylit arena into a moonlit night makes both look broken.
## - An optional **`Lights`** node for anything else the map needs lit.
## - A **`Spawns`** node holding **eight `Marker3D` children** — one per
##   `MatchConfig.MAX_PLAYERS`, so a full lobby never opens with two Gubs on one
##   pad — each **facing inward**. A player whose first frame looks at a wall
##   has to turn around before they can read anything, which is the same reason
##   the island's solved pads face the middle of the map.
## - **`void_height`**, below which a fall is a death. Exported rather than
##   taken from `MatchState.VOID_HEIGHT` because that constant is -45, which is
##   a property of a floating island with a deep rocky underside; a ground-level
##   arena wants a floor a few metres down, and a Gub that walks off the edge of
##   one should be dead before the fall becomes boring.

## The ring `spawn_points()` invents when a map ships without any. Eight, the
## same count a real map owes, so the rest of the match behaves normally while
## the map is being shouted at.
const FALLBACK_COUNT := MatchConfig.MAX_PLAYERS
const FALLBACK_RADIUS := 8.0

## The physics layer the world lives on. Named `world` in `project.godot`, and
## the one layer every collider in the game agrees to look for.
const LAYER_WORLD := 1

## How wide a collision cell is, in metres. Mesh instances are grouped by which
## cell their world-space bounding box centres in, and each group becomes one
## `ConcavePolygonShape3D` — so a 42 x 64 m arena comes out as a dozen or so
## shapes rather than as one shape covering everything or 148 covering nothing.
##
## Grouping is by instance, not by triangle. Every prop in this map is already a
## spatially local lump of geometry, so bucketing whole instances gets nearly
## the tightness that bucketing triangles would — and it does it in 148
## iterations of GDScript instead of 96,301, leaving the actual vertex work to
## the engine's own `Transform3D * PackedVector3Array`.
const COLLISION_CELL := 16.0

## Anything below this has left the map and is not coming back. `arena.gd` hands
## it to `MatchState.set_void_height()`; the default matches
## `MatchState.VOID_HEIGHT` so a map that never touches it behaves as the island
## does. Written as a literal rather than read from the autoload because an
## export default is evaluated by the editor and the import step, where an
## autoload is not something that can be relied on to exist.
@export var void_height: float = -45.0

## What the build actually did — for the log line, and for `tools/preview_map.gd`
## to assert on. A map that comes out with no triangles in it is a map whose
## `.glb` did not import, and that is worth being able to fail a check over
## rather than discovering by walking into it.
var triangles: int = 0
var shapes: int = 0
var meshes: int = 0
var build_msec: int = 0


func _ready() -> void:
	var started := Time.get_ticks_msec()
	var instances := _mesh_instances()
	_face_the_camera(instances)
	_build_collision(instances)
	build_msec = Time.get_ticks_msec() - started
	print("%s: %d triangles from %d meshes into %d collision shapes in %d ms" % [
		name, triangles, meshes, shapes, build_msec])


# --------------------------------------------------------------- collision ---

## Build the map's collision, in world space, at load (D-031).
##
## The obvious thing — a `CollisionShape3D` under each mesh carrying that mesh's
## `create_trimesh_shape()` — does not work on this geometry. A third of the
## nodes in the arena carry a non-uniform scale and five carry a negative one,
## and a `ConcavePolygonShape3D` is not reliably scaled by the transform of the
## node above it: the physics server takes a single scale off the shape's owner,
## and a non-uniform one comes out wrong. That is the difference between a
## container you can stand on and one you fall through the corner of.
##
## So the vertices are baked instead. Every triangle is transformed into world
## space by its own instance's `global_transform` and handed to a body that has
## no transform of its own, and the scaling problem stops existing rather than
## being worked around. `backface_collision` is on because five instances have a
## negative determinant and their triangles therefore arrive wound the other
## way — without it a spear passes straight through the tower supports.
func _build_collision(instances: Array[MeshInstance3D]) -> void:
	var body := StaticBody3D.new()
	body.name = "Collision"
	# Layer 1 and nothing else, and a mask of nothing: the world is a thing that
	# gets collided *with*. A static body that also scans for contacts is one
	# paying for a broadphase query nothing ever reads.
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	add_child(body)
	# The triangles below are already where they belong, so the body must not
	# carry a transform of its own on top of them.
	body.global_transform = Transform3D.IDENTITY

	var cells: Dictionary = {}
	for node in instances:
		var faces := node.mesh.get_faces()
		if faces.is_empty():
			continue
		var xform := node.global_transform
		var cell := Vector3i((xform * node.get_aabb()).get_center() / COLLISION_CELL)
		var bucket: PackedVector3Array = cells.get(cell, PackedVector3Array())
		# The engine's own bulk transform. The same loop written out in GDScript
		# is 289,000 iterations and about a third of a second.
		bucket.append_array(xform * faces)
		cells[cell] = bucket
		triangles += faces.size() / 3

	for cell: Vector3i in cells:
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(cells[cell])
		var holder := CollisionShape3D.new()
		holder.name = "Cell%d_%d_%d" % [cell.x, cell.y, cell.z]
		holder.shape = shape
		body.add_child(holder)
	shapes = cells.size()


# --------------------------------------------------------------- materials ---

## Turn back-face culling back on, which the importer turned off for us.
##
## Every material in this map arrives `doubleSided` and therefore
## `CULL_DISABLED`, so the renderer rasterises the inside of every container,
## barrel and oil tank in the arena and then throws it away behind the outside.
## Forcing `CULL_BACK` costs one property write and is most of the avoidable
## frame cost of a map that is otherwise a single static mesh set.
##
## Two exceptions, both of which have to stay double-sided:
##
## - **Anything actually transparent** — the chain-link `Net` and the `Solid
##   Glass` in the doors. A net culled to its front faces is a net you can see
##   through from one side only, which reads as a hole in the world.
## - **The five negatively scaled instances** (`SM _ Tank Container _001` and
##   the four `SM _ Tower Support`s). A negative determinant reverses the
##   winding the rasteriser sees, so back-face culling turns them inside out.
##   They get a duplicate of their material with culling left off, rather than a
##   fix to the geometry, because the geometry is imported and any fix to it
##   would not survive the next re-import.
func _face_the_camera(instances: Array[MeshInstance3D]) -> void:
	for node in instances:
		var flipped := node.global_transform.basis.determinant() < 0.0
		for surface in node.mesh.get_surface_count():
			var material := node.mesh.surface_get_material(surface) as BaseMaterial3D
			if material == null:
				continue
			# Transparent materials are left exactly as imported, on both paths.
			if material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				continue
			if flipped:
				# Per instance, so the shared material is not dragged back to
				# double-sided for the hundred-odd nodes that are the right way
				# round.
				var kept := material.duplicate() as BaseMaterial3D
				kept.cull_mode = BaseMaterial3D.CULL_DISABLED
				node.set_surface_override_material(surface, kept)
			else:
				# Written through to the imported resource rather than
				# overridden: it is shared by every instance that uses it, the
				# assignment is idempotent, and an override per surface would be
				# 148 more materials for a one-property change.
				material.cull_mode = BaseMaterial3D.CULL_BACK


## Every `MeshInstance3D` under the map that has a mesh, in tree order.
##
## Read once and handed to both passes: walking 150 nodes twice would not be
## expensive, but the two passes have to agree about what the map is made of,
## and one list is how that stays true.
func _mesh_instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_collect_meshes(self, out)
	meshes = out.size()
	return out


func _collect_meshes(from: Node, into: Array[MeshInstance3D]) -> void:
	var node := from as MeshInstance3D
	if node != null and node.mesh != null:
		into.append(node)
	for child in from.get_children():
		_collect_meshes(child, into)


# ------------------------------------------------------------------ spawns ---

## Where the match should put people, in world space.
##
## Read off the markers rather than solved, which is the whole difference
## between a static map and a generated one: on a hand-made arena the designer
## already knows where a fair spawn is, and no amount of ray-casting will find
## a better answer than the person who built the geometry.
##
## Must be called after the map is in the tree — `global_transform` on a node
## outside it is its local transform wearing a disguise.
func spawn_points() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var root := get_node_or_null("Spawns")
	if root != null:
		for child in root.get_children():
			var marker := child as Marker3D
			# Anything else under `Spawns` is a note to the designer, not a pad.
			if marker != null:
				out.append(marker.global_transform)

	if not out.is_empty():
		return out

	# Loud, and then survivable. A map with no spawns would otherwise hand
	# `MatchState` an empty list, every Gub would be created at the world
	# origin, and the report would be "everyone spawns inside each other"
	# rather than "the map forgot its Spawns node".
	push_error("StaticMap: '%s' has no Marker3D under a `Spawns` node; "
		% name + "falling back to a ring at the origin")
	return _fallback_spawns()


## A ring at the origin, facing inward. Somewhere to stand, not a playable
## layout — it exists so the arena still registers and the error above is the
## first thing anybody reads.
func _fallback_spawns() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in FALLBACK_COUNT:
		var bearing := TAU * float(i) / float(FALLBACK_COUNT)
		var here := Vector3(cos(bearing), 0.0, sin(bearing)) * FALLBACK_RADIUS
		var yaw := Gub.yaw_towards(-here.normalized())
		out.append(Transform3D(Basis(Vector3.UP, yaw), here))
	return out
