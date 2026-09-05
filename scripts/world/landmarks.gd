class_name Landmarks
extends RefCounted
## The hand-placed half of Whisperbloom Hollow: shrine, mushroom grove, rock
## arch, log bridges, stone paths and the steps up the high ground.
##
## D-007 says the map is generated, and it is — but a map that is *only*
## generated has no landmarks, and a map with no landmarks cannot be talked
## about. "Meet me at the arch" is the difference between an arena and a field of
## noise. So everything in here is placed by hand in map coordinates and then
## dropped onto whatever height the generator produced there, which keeps the
## layout designed while keeping the terrain seeded.
##
## The pass runs **before** the prop scatter and publishes `keepouts`, so no tree
## ever grows through the shrine floor and no boulder ever lands on a bridge.
## It also publishes `torch_spots`, because the places worth lighting are exactly
## the places worth building (4.5), and `path_nodes` for the traversal report.

const LAYER_WORLD := 1

## Where the bridges reach. Bearings match `IslandGenerator._setup_landmasses`;
## the actual anchor points are solved against the real rims at build time, so
## the bridge still lands on ground when the seed moves the outline.
const EAST_BEARING := 0.55
const NORTH_BEARING := 2.15

## Deck height above the two rims a bridge connects, and how wide it is. 1.9 m of
## walkable width is about two Gubs abreast: enough that crossing is not a
## balance minigame, narrow enough that being caught on one is bad news.
const BRIDGE_RISE := 0.35
const BRIDGE_WIDTH := 1.9
const LOG_RADIUS := 0.42

## Path stones are laid this far apart along the spine routes.
const PATH_SPACING := 1.15


## Somewhere a torch should stand, produced by whichever landmark wants lighting.
class TorchSpot extends RefCounted:
	var position: Vector3
	## Shadow-casting torches are the expensive ones — a shadow map each, every
	## frame, for a light that flickers. Only the landmarks get them.
	var shadows: bool
	var height_scale: float

	func _init(at: Vector3, casts_shadow: bool = false, tall: float = 1.0) -> void:
		position = at
		shadows = casts_shadow
		height_scale = tall


var island: IslandGenerator
var keepouts: Array[PropScatter.Keepout] = []
var torch_spots: Array[TorchSpot] = []
## The centre-line of every stone path, in order. `tools/island_report.gd` walks
## these to check the map is actually traversable.
var path_nodes: PackedVector3Array = PackedVector3Array()

var _rng := RandomNumberGenerator.new()
var _stone: StandardMaterial3D
var _wood: StandardMaterial3D
var _crystal: StandardMaterial3D


func _init(from_island: IslandGenerator, map_seed: int) -> void:
	island = from_island
	_rng.seed = map_seed ^ 0x1A4D3A2
	_build_materials()


func _build_materials() -> void:
	_stone = StandardMaterial3D.new()
	_stone.albedo_color = Color(0.235, 0.235, 0.245)
	_stone.roughness = 0.88
	_stone.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	_wood = StandardMaterial3D.new()
	_wood.albedo_color = Color(0.225, 0.175, 0.128)
	_wood.roughness = 0.94
	_wood.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	# The one emissive material on the island that is not a flame. Well over the
	# environment's 1.45 glow threshold (D-009) so the shrine blooms and reads as
	# the map's landmark from anywhere on it.
	_crystal = StandardMaterial3D.new()
	_crystal.albedo_color = Color(0.45, 0.85, 0.95)
	_crystal.emission_enabled = true
	_crystal.emission = Color(0.35, 0.85, 0.95)
	_crystal.emission_energy_multiplier = 4.5
	_crystal.roughness = 0.25


## Build everything under `parent`. Order matters only in that the paths are laid
## last, so they can be routed to whatever the other landmarks decided.
func build(parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "Landmarks"
	parent.add_child(root)

	_build_shrine(root)
	_build_grove(root)
	_build_arch(root)
	_build_bridges(root)
	_build_paths(root)


# ------------------------------------------------------------------ shrine ---

## A stone circle on the knoll, with a lit crystal in the middle.
##
## This is the map's high ground (4.10) and its focal point at once. Putting the
## brightest object in the arena on the most commanding position is deliberate:
## it makes holding the high ground *visible* to everyone below, so taking it is
## a decision other players can see being made.
func _build_shrine(parent: Node3D) -> void:
	var centre := island.knoll_centre
	var base := island.surface_point(centre.x, centre.y)

	var shrine := Node3D.new()
	shrine.name = "Shrine"
	shrine.position = base
	parent.add_child(shrine)

	# Floor: kit path stones laid in two rings. Individually they are 1-2 m
	# discs, so a ring of eight at 2.4 m reads as a paved circle.
	_lay_ring(shrine, base, 0.0, 1, "RockPath_Round_Wide", 0.9)
	_lay_ring(shrine, base, 2.35, 8, "RockPath_Round_Wide", 0.8)
	_lay_ring(shrine, base, 4.1, 12, "RockPath_Round_Small_1", 0.85)

	# Standing stones: boulders stretched vertically. Five, not four — an odd
	# count reads as built rather than as an axis-aligned prop.
	var pillar_mesh := PropScatter.load_kit_mesh("Rock_Medium_2")
	for i in 5:
		var angle := TAU * float(i) / 5.0 + 0.4
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * 3.3
		var spot := island.surface_point(base.x + offset.x, base.z + offset.z)
		var stone := MeshInstance3D.new()
		stone.mesh = pillar_mesh
		stone.position = spot - base - Vector3.UP * 0.5
		stone.scale = Vector3(0.34, 1.55, 0.34) * _rng.randf_range(0.9, 1.12)
		stone.rotation.y = _rng.randf_range(0.0, TAU)
		stone.rotation.z = _rng.randf_range(-0.05, 0.05)
		shrine.add_child(stone)
		_convex_body(shrine, stone)

	var crystal := ShrineCrystal.new()
	crystal.position = Vector3.UP * 1.9
	crystal.build(_crystal)
	shrine.add_child(crystal)

	var glow := OmniLight3D.new()
	glow.light_color = Color(0.42, 0.82, 0.95)
	glow.light_energy = 3.2
	glow.omni_range = 13.0
	glow.omni_attenuation = 1.5
	glow.light_volumetric_fog_energy = 2.0
	glow.position = Vector3.UP * 1.9
	shrine.add_child(glow)

	for i in 4:
		var angle := TAU * float(i) / 4.0 + 0.9
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * 4.6
		torch_spots.append(TorchSpot.new(
			island.surface_point(base.x + offset.x, base.z + offset.z),
			i < 2, 1.15))

	keepouts.append(PropScatter.Keepout.new(centre, 5.4, true))
	keepouts.append(PropScatter.Keepout.new(centre, 8.0, false))
	path_nodes.append(base)


# ------------------------------------------------------------------- grove ---

## The whisperblooms themselves: a stand of oversized glowing fungus in the
## hollow. Scaling the kit's mushrooms 3-6x turns a piece of ground cover into
## architecture, which is the cheapest fantasy landmark there is.
func _build_grove(parent: Node3D) -> void:
	var centre := Vector2(6.4, -6.1)
	var grove := Node3D.new()
	grove.name = "MushroomGrove"
	parent.add_child(grove)

	var caps := ["Mushroom_Laetiporus", "Mushroom_Common"]
	for i in 11:
		var angle := _rng.randf_range(0.0, TAU)
		var dist := sqrt(_rng.randf()) * 4.4
		var spot := centre + Vector2(cos(angle), sin(angle)) * dist
		var mesh := PropScatter.load_kit_mesh(caps[i % caps.size()])
		if mesh == null:
			continue

		var cap := MeshInstance3D.new()
		cap.mesh = mesh
		cap.position = island.surface_point(spot.x, spot.y) - Vector3.UP * 0.08
		var big := _rng.randf_range(2.4, 5.6)
		cap.scale = Vector3(big, big * _rng.randf_range(0.85, 1.25), big)
		cap.rotation.y = _rng.randf_range(0.0, TAU)
		# Override rather than replace: the kit's own albedo texture stays, and
		# only the emission channel is added, so the caps glow in their own
		# colours instead of turning into flat lozenges.
		cap.set_surface_override_material(0, _glowing(mesh, 0))
		grove.add_child(cap)

		if i % 3 == 0:
			var spore := OmniLight3D.new()
			spore.light_color = Color(0.55, 0.42, 0.95)
			spore.light_energy = 2.0
			spore.omni_range = 7.5
			spore.omni_attenuation = 1.7
			spore.light_volumetric_fog_energy = 2.0
			spore.position = cap.position + Vector3.UP * (mesh.get_aabb().size.y * big * 0.9)
			grove.add_child(spore)

	torch_spots.append(TorchSpot.new(
		island.surface_point(centre.x + 5.6, centre.y + 1.2), true))
	# Only the sparse layers are excluded: grass and clover growing between the
	# stalks is exactly what a grove should look like.
	keepouts.append(PropScatter.Keepout.new(centre, 6.0, false))
	path_nodes.append(island.surface_point(centre.x, centre.y))


## A copy of a kit material with emission switched on, so a prop can glow without
## losing the texture that makes it look like itself.
func _glowing(mesh: Mesh, surface: int) -> StandardMaterial3D:
	var source := mesh.surface_get_material(surface) as StandardMaterial3D
	var mat := (source.duplicate() if source != null else StandardMaterial3D.new()) as StandardMaterial3D
	mat.emission_enabled = true
	mat.emission = Color(0.42, 0.68, 0.95)
	# Below the 1.45 glow threshold on purpose: the caps should read as lit from
	# within, not bloom like the torches do.
	mat.emission_energy_multiplier = 1.15
	return mat


# -------------------------------------------------------------------- arch ---

## Two leaning pillars and a lintel, straddling the path out to the east bridge.
## A gateway is the clearest possible signal that a route exists, and this one
## also gives the map a piece of hard cover a thrown spear cannot pass.
func _build_arch(parent: Node3D) -> void:
	var bearing := EAST_BEARING - 0.55
	var mass := island.landmasses[0]
	var out := Vector2(cos(bearing), sin(bearing))
	var centre := out * (mass.rim_radius(bearing) - 6.5)

	var arch := Node3D.new()
	arch.name = "RockArch"
	parent.add_child(arch)

	var across := Vector2(-out.y, out.x)
	var pillar_mesh := PropScatter.load_kit_mesh("Rock_Medium_3")
	var tops: Array[Vector3] = []
	for side: float in [-1.0, 1.0]:
		var foot := centre + across * (2.6 * side)
		# Leaning inward, so the two pillars point at each other and the lintel
		# looks carried rather than balanced. The lean is applied as a rotation
		# about the axis perpendicular to it, *outside* the random spin about the
		# pillar's own axis — composing two Euler angles instead would make the
		# lean direction depend on the spin, and half the seeds would lean the
		# pillars apart.
		var lean_direction := Vector3(-across.x, 0.0, -across.y) * side
		var lean_axis := Vector3.UP.cross(lean_direction).normalized()
		var basis := Basis(lean_axis, 0.13) 			* Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
		var pillar := MeshInstance3D.new()
		pillar.mesh = pillar_mesh
		pillar.transform = Transform3D(basis.scaled(Vector3(0.5, 2.1, 0.5)),
			island.surface_point(foot.x, foot.y) - Vector3.UP * 0.5)
		arch.add_child(pillar)
		_convex_body(arch, pillar)
		tops.append(pillar.position + Vector3.UP * 4.3)

	var lintel := MeshInstance3D.new()
	lintel.mesh = PropScatter.load_kit_mesh("Rock_Medium_1")
	lintel.position = (tops[0] + tops[1]) * 0.5
	lintel.scale = Vector3(0.42, 0.4, 2.1)
	lintel.rotation.y = atan2(across.x, across.y)
	arch.add_child(lintel)
	_convex_body(arch, lintel)

	for side: float in [-1.0, 1.0]:
		var foot := centre + across * (4.2 * side)
		torch_spots.append(TorchSpot.new(
			island.surface_point(foot.x, foot.y), side > 0.0))

	keepouts.append(PropScatter.Keepout.new(centre, 5.0, false))
	path_nodes.append(island.surface_point(centre.x, centre.y))


# ----------------------------------------------------------------- bridges ---

func _build_bridges(parent: Node3D) -> void:
	for index in range(1, island.landmasses.size()):
		var islet := island.landmasses[index]
		var bearing := EAST_BEARING if index == 1 else NORTH_BEARING
		var out := Vector2(cos(bearing), sin(bearing))

		# Anchor a little *inside* each rim rather than on it: the rim is the
		# part the droop takes down, so a bridge that ends exactly on the lip
		# ends on a slope.
		var main := island.landmasses[0]
		var from := out * (main.rim_radius(bearing) - 1.1)
		var to_local := (from - islet.centre).normalized()
		var towards := islet.centre + to_local * (islet.rim_radius(to_local.angle()) - 1.0)
		_build_bridge(parent, "LogBridge%d" % index, from, towards)


func _build_bridge(parent: Node3D, label: String, from: Vector2, to: Vector2) -> void:
	var bridge := Node3D.new()
	bridge.name = label
	parent.add_child(bridge)

	var start := island.surface_point(from.x, from.y) + Vector3.UP * BRIDGE_RISE
	var end := island.surface_point(to.x, to.y) + Vector3.UP * BRIDGE_RISE
	var span := end - start
	var length := span.length()
	var mid := (start + end) * 0.5
	var across := Vector3(-span.z, 0.0, span.x).normalized()

	# Two felled trunks side by side. Each is a cylinder aimed along the span:
	# CylinderMesh runs along local +Y, so the basis is built with the span as
	# its Y axis rather than by composing two Euler rotations.
	var up := span.normalized()
	var right := across
	var forward := right.cross(up).normalized()
	var aim := Basis(right, up, forward)

	for side: float in [-1.0, 1.0]:
		var log_mesh := CylinderMesh.new()
		log_mesh.top_radius = LOG_RADIUS
		log_mesh.bottom_radius = LOG_RADIUS * 1.08
		log_mesh.height = length
		log_mesh.radial_segments = 10
		log_mesh.material = _wood
		var trunk := MeshInstance3D.new()
		trunk.mesh = log_mesh
		trunk.transform = Transform3D(aim, mid + across * (BRIDGE_WIDTH * 0.25 * side))
		bridge.add_child(trunk)

	# The collider is a flat box across the tops of the logs, not the logs
	# themselves. Walking on a cylinder means a CharacterBody3D sliding off a
	# curved surface all the way across, which feels like ice; a deck flush with
	# the log tops is what the player thinks they are standing on anyway.
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var deck := BoxShape3D.new()
	deck.size = Vector3(BRIDGE_WIDTH, 0.3, length)
	shape.shape = deck
	body.add_child(shape)
	# Box depth runs along local Z, so this basis puts the span on Z instead.
	body.transform = Transform3D(Basis(right, up.cross(right).normalized(), up),
		mid + Vector3.UP * (LOG_RADIUS - 0.15))
	bridge.add_child(body)

	# A torch at each end. Bridges are the only chokepoints on the map and the
	# only place a player is committed to a straight line — they need to be
	# readable from across the island, both to cross and to watch.
	torch_spots.append(TorchSpot.new(start + across * 1.5, true))
	torch_spots.append(TorchSpot.new(end - across * 1.5, false))

	keepouts.append(PropScatter.Keepout.new(from, 3.2, true))
	keepouts.append(PropScatter.Keepout.new(to, 3.2, true))
	path_nodes.append(start)
	path_nodes.append(end)


# ------------------------------------------------------------------- paths ---

## Stone routes between the landmarks, plus steps up the knoll.
##
## The paths are the traversal pass (4.10) made visible: every one of them is a
## route somebody has to take, and laying stones along it both proves the route
## exists and tells a player at a glance where they can get to.
func _build_paths(parent: Node3D) -> void:
	var routes := [
		[Vector2(1.5, 1.0), island.knoll_centre],
		[Vector2(1.5, 1.0), Vector2(6.4, -6.1)],
		[Vector2(1.5, 1.0), Vector2(cos(EAST_BEARING), sin(EAST_BEARING))
			* (island.landmasses[0].rim_radius(EAST_BEARING) - 2.0)],
		[Vector2(1.5, 1.0), Vector2(cos(NORTH_BEARING), sin(NORTH_BEARING))
			* (island.landmasses[0].rim_radius(NORTH_BEARING) - 2.0)],
	]

	var paths := Node3D.new()
	paths.name = "Paths"
	parent.add_child(paths)

	var stones := ["RockPath_Round_Small_1", "RockPath_Round_Small_2",
		"RockPath_Round_Small_3", "RockPath_Square_Small_1", "RockPath_Square_Small_2"]
	for route: Array in routes:
		var from: Vector2 = route[0]
		var to: Vector2 = route[1]
		var length := from.distance_to(to)
		var steps := int(length / PATH_SPACING)
		for i in range(steps + 1):
			var t := float(i) / float(maxi(steps, 1))
			# A gentle sideways bow, so the route is a path rather than a
			# surveyor's line. The bow is a half-sine, so both ends land exactly.
			var lateral := (to - from).orthogonal().normalized() * sin(t * PI) * 1.6
			var spot := from.lerp(to, t) + lateral
			spot += Vector2(_rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.3, 0.3))
			if not island.is_land(spot.x, spot.y):
				continue
			_lay_stone(paths, spot, stones[_rng.randi_range(0, stones.size() - 1)],
				_rng.randf_range(0.65, 0.95))
			keepouts.append(PropScatter.Keepout.new(spot, 1.4, false))
		path_nodes.append(island.surface_point(to.x, to.y))

		# Torches every few metres along the longer routes only. A lantern-lit
		# path is the map's readability; a lantern every metre is a runway.
		var lamps := int(length / 9.0)
		for i in range(1, lamps + 1):
			var t := float(i) / float(lamps + 1)
			var spot := from.lerp(to, t) + (to - from).orthogonal().normalized() * 2.6
			if island.is_land(spot.x, spot.y):
				torch_spots.append(TorchSpot.new(island.surface_point(spot.x, spot.y)))


func _lay_ring(parent: Node3D, base: Vector3, radius: float, count: int,
		model: String, size: float) -> void:
	for i in count:
		var angle := TAU * float(i) / float(count) + float(count) * 0.31
		var spot := Vector2(base.x, base.z) + Vector2(cos(angle), sin(angle)) * radius
		_lay_stone(parent, spot, model, size, base)


## One flat stone, laid on the ground and tilted onto it.
func _lay_stone(parent: Node3D, spot: Vector2, model: String, size: float,
		origin: Vector3 = Vector3.ZERO) -> void:
	var mesh := PropScatter.load_kit_mesh(model)
	if mesh == null:
		return
	var node := MeshInstance3D.new()
	node.mesh = mesh
	var up := island.normal_at(spot.x, spot.y)
	var forward := Vector3.FORWARD.rotated(Vector3.UP, _rng.randf_range(0.0, TAU))
	var right := up.cross(forward).normalized()
	var basis := Basis(right, up, right.cross(up).normalized()).scaled(Vector3.ONE * size)
	# Sunk a few centimetres so the stones are set into the ground rather than
	# resting on top of it like counters.
	node.transform = Transform3D(basis,
		island.surface_point(spot.x, spot.y) - origin - Vector3.UP * 0.05)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)


## A static body carrying the simplified convex hull of a mesh instance, matched
## to that instance's own transform.
func _convex_body(parent: Node3D, from: MeshInstance3D) -> void:
	var convex := from.mesh.create_convex_shape(true, true)
	if convex == null:
		return
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	body.transform = from.transform
	var shape := CollisionShape3D.new()
	shape.shape = convex
	body.add_child(shape)
	parent.add_child(body)


## The shrine's crystal: a faceted bipyramid that turns and bobs.
##
## Built as an inner class because it is the only thing on the island that needs
## a `_process`, and a whole script file for eight lines of animation would be
## harder to find than it is worth.
class ShrineCrystal extends Node3D:
	var _phase: float = 0.0
	var _base_y: float = 0.0

	func build(material: StandardMaterial3D) -> void:
		var visual := MeshInstance3D.new()
		visual.mesh = _bipyramid(0.42, 1.05)
		visual.material_override = material
		add_child(visual)
		_base_y = position.y

	func _process(delta: float) -> void:
		_phase += delta
		rotate_y(delta * 0.42)
		position.y = _base_y + sin(_phase * 0.9) * 0.11

	## Six-sided bipyramid with flat shading — no smooth normals, because the
	## whole point of a gem is that the facets catch the torchlight separately.
	static func _bipyramid(radius: float, half_height: float) -> ArrayMesh:
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var sides := 6
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var p0 := Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
			var p1 := Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
			for tip: Vector3 in [Vector3.UP * half_height, Vector3.DOWN * half_height]:
				var wind: Array[Vector3] = []
				# Wound the opposite way for the lower half, so both cones face
				# outward from a single triangle list.
				wind.assign([p0, p1, tip] if tip.y > 0.0 else [p1, p0, tip])
				var face := (wind[1] - wind[0]).cross(wind[2] - wind[0]).normalized()
				for v: Vector3 in wind:
					verts.append(v)
					normals.append(face)

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh
