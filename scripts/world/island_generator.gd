class_name IslandGenerator
extends RefCounted
## Builds the landmasses of Whisperbloom Hollow from one integer seed.
##
## Every client runs this with `Net.config.map_seed` and must end up with the
## same island down to the vertex, because nothing about the terrain is
## replicated — a spear that clears a ridge on the host has to clear it on every
## other machine too. That is why nothing in here touches the global RNG: every
## random number comes from a local `RandomNumberGenerator` or a seeded
## `FastNoiseLite`, both of which are pure functions of the seed. See D-007 and
## D-013.
##
## The mesh is built in **polar** coordinates rather than on a square grid. A
## grid has to clip itself against the island outline, which leaves a staircase
## edge at cell resolution — and the outline is the single most-looked-at line on
## a floating island, since it is the one silhouetted against the sky. A polar
## ring lands exactly on the rim by construction, and it also gives the underside
## somewhere to weld to: the last surface ring *is* the first underside ring.
##
## The generator is also the map's height oracle. Prop scatter, landmark
## placement and spawn points all ask `height_at`/`slope_at` rather than
## ray-casting, so they can run before any collision shape exists.

## Returned by `height_at` for a point that is off every landmass. Far enough
## below anything real that callers can test it with a simple comparison, and
## deliberately not NAN, which propagates silently through arithmetic.
const NO_LAND := -1000.0

## Angular resolution. 144 sectors puts a vertex every 0.9 m on the main
## island's rim, which is under the width of a Gub and so reads as a curve.
const SECTORS := 144
## Radial rings on the top surface, and on the underside cone.
const SURFACE_RINGS := 30
const UNDERSIDE_RINGS := 14

## Terrain relief from noise, in metres, before the shaping terms. Kept low on
## purpose: this is a duelling map, and rolling ground that hides a crouched Gub
## at 15 m is ground that makes an instant-kill weapon feel arbitrary. The read
## comes from the hollow, the knoll and the props, not from noise.
const RELIEF := 1.15
## The rim lips downward over the last fifth of the radius, so the island reads
## as a torn-out chunk of world rather than as a table with a cloth on it. The
## drop is scaled by each landmass's radius: a fixed 1.6 m taken out of the last
## fifth of a 5 m islet is a 1.5:1 bank a Gub cannot climb, and the islets are
## where the bridges land.
const RIM_DROOP_START := 0.80
const RIM_DROOP := 1.6
const RIM_DROOP_REFERENCE := 19.0

## Colours, sitting just above the albedo floor D-009 asks for —
## Color(0.15, 0.18, 0.12) — and that floor turned out to be a ceiling too.
##
## Worth recording, because it cost most of an afternoon: the ground first
## rendered pure black, so these were doubled on the theory that the terrain was
## too dark to catch any sky ambient. It was not. The mesh was inside-out (see
## `_packed`) and simply was not being drawn. With the winding fixed, the doubled
## values made the ground the *brightest* surface in the frame — a big flat
## upward-facing plane collects more sky ambient than anything else on the
## island, so it needs a lower albedo than the props standing on it, not a
## higher one. These are back where D-009 put them.
## The green channel is roughly twice the red, which is more saturation than a
## grass albedo normally wants. It is there to survive the light: the sky's
## `forest_glow` band is a warm orange ring all the way round the horizon and the
## torches are warmer still, so a merely-greenish ground renders as sand. Under
## this light these read as grass; under a neutral one they would read as too
## green, and this map never sees a neutral one.
const GRASS_DARK := Color(0.098, 0.205, 0.088)
const GRASS_LIGHT := Color(0.170, 0.320, 0.130)
const GRASS_MOSS := Color(0.105, 0.258, 0.188)
const DIRT := Color(0.200, 0.163, 0.115)
## Bare earth where the top surface runs out at the rim. Separate from the rock
## below it: the two meet at the lip and want different values, warm dirt above
## and cold stone below, which is most of what makes the lip read as an edge.
const RIM_EARTH := Color(0.180, 0.148, 0.108)
## The rocky root is the one part allowed under the floor, and it needs to be:
## its whole job is to be a silhouette, and it is the one large surface on the
## map that faces *outward*, straight into the sky's bright horizon band. At the
## same albedo as the grass it came out paler than the ground above it — a
## floating island resting on a mound of clay — so it is deliberately about a
## third of it.
const ROCK_HIGH := Color(0.088, 0.085, 0.080)
const ROCK_LOW := Color(0.046, 0.046, 0.053)


## One floating chunk of ground: a top surface and the rocky root beneath it.
##
## Three of these make the map — the main island plus two outlying islets that
## the log bridges reach. Splitting the map up this way is what gives Phase 4.4
## its bridges something to bridge, and it is also the cheapest way to make an
## arena that reads as an island from every angle: you can see sky through the
## middle of it.
class Landmass extends RefCounted:
	var name: String = "Landmass"
	var centre: Vector2 = Vector2.ZERO
	## Mean rim radius, and how far the outline wanders from it.
	var base_radius: float = 19.0
	var rim_amp: float = 2.2
	var rim_phase: float = 0.0
	var base_height: float = 0.0
	## How far the rocky root hangs below the rim.
	var depth: float = 17.0
	## How much of the noise relief this chunk gets. The islets are small enough
	## that full relief would make them unwalkable.
	var relief_scale: float = 1.0

	## How far the rim lips down, in metres — proportional to the radius so a
	## small islet gets a small lip rather than a cliff.
	func rim_droop() -> float:
		return RIM_DROOP * clampf(base_radius / RIM_DROOP_REFERENCE, 0.3, 1.0)

	## Distance from the centre to the rim at this bearing.
	##
	## Two harmonics, both with integer frequencies so the outline closes
	## exactly at theta = TAU. A noise lookup would also work and would cost a
	## sample per vertex for an outline nobody can tell apart from this.
	func rim_radius(theta: float) -> float:
		return base_radius + rim_amp * (
			0.62 * sin(theta * 3.0 + rim_phase)
			+ 0.38 * sin(theta * 7.0 - rim_phase * 1.7))


## A smooth radial bump or basin laid over the noise. These are the map's
## deliberate shape — the hollow the place is named after, and the high ground
## Phase 4.10 wants — so they are constants rather than seeded: a landmark that
## moves when the seed changes cannot have a shrine built on it.
class Feature extends RefCounted:
	var centre: Vector2
	var radius: float
	## Positive raises, negative sinks.
	var height: float

	func _init(at: Vector2, size: float, amount: float) -> void:
		centre = at
		radius = size
		height = amount

	## Raised cosine: zero value *and* zero slope at the edge, so the feature
	## melts into the surrounding terrain instead of leaving a visible ring.
	func contribution(x: float, z: float) -> float:
		var d := Vector2(x, z).distance_to(centre)
		if d >= radius:
			return 0.0
		return height * 0.5 * (1.0 + cos(PI * d / radius))


var seed_value: int = 0
var landmasses: Array[Landmass] = []
var features: Array[Feature] = []

## The knoll's summit, published so the landmark pass can put the shrine on it
## without re-deriving where the high ground ended up.
var knoll_centre: Vector2 = Vector2.ZERO
var knoll_height: float = 0.0

var _relief_noise := FastNoiseLite.new()
var _detail_noise := FastNoiseLite.new()
var _tint_noise := FastNoiseLite.new()
var _crag_noise := FastNoiseLite.new()

var _grass_material: StandardMaterial3D
var _rock_material: StandardMaterial3D


func _init(map_seed: int) -> void:
	seed_value = map_seed
	_setup_noise()
	_setup_landmasses()
	_setup_features()
	_setup_materials()


func _setup_noise() -> void:
	# Distinct seeds per layer. Reusing one seed at different frequencies makes
	# the layers correlate: every ridge would also be a colour change.
	_relief_noise.seed = seed_value
	_relief_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_relief_noise.frequency = 0.028
	_relief_noise.fractal_octaves = 3
	_relief_noise.fractal_gain = 0.45

	_detail_noise.seed = seed_value + 7717
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = 0.11
	_detail_noise.fractal_octaves = 2

	_tint_noise.seed = seed_value + 3331
	_tint_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_tint_noise.frequency = 0.075
	_tint_noise.fractal_octaves = 2

	_crag_noise.seed = seed_value + 991
	_crag_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_crag_noise.frequency = 0.085
	_crag_noise.fractal_octaves = 3
	_crag_noise.fractal_gain = 0.52


## The main island plus two islets, positioned so the whole map fits the ~40–60 m
## span the fog in `arena_env.tres` was tuned against (D-009).
##
## Each islet is pushed out to sit a fixed *gap* beyond the main rim at its own
## bearing, rather than at a fixed distance from the origin. The rim wanders by
## ±2.2 m with the seed, so a fixed distance would have the islets welded to the
## island on one seed and marooned six metres further out on the next — and the
## bridge that spans the gap is a hand-built object with a length.
func _setup_landmasses() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var main := Landmass.new()
	main.name = "MainIsland"
	main.base_radius = 19.0
	main.rim_amp = 2.2
	main.rim_phase = rng.randf_range(0.0, TAU)
	# About half the island's width. Shallower than this and the underside reads
	# as the bottom of a bowl; the void starts at -45 (`MatchState.VOID_HEIGHT`)
	# so there is room for the root to be a real shape.
	main.depth = 21.0
	landmasses.append(main)

	# Bearings are fixed, not seeded: the bridges, the spawn ring and the
	# traversal read all assume "there is an islet out this way and another out
	# that way", and a seed that put both in the same place would make half the
	# map a dead end.
	#
	# They are also roughly a quarter-turn apart rather than opposite. Two
	# opposed islets put the map's long axis through both of them — main rim,
	# gap, islet, on each side — which measured 71 m across and blew straight
	# past the 40–60 m the fog in `arena_env.tres` is tuned for (D-009). At 90°
	# the long axis runs through only one islet and the map measures ~56 m, with
	# no islet made smaller to get there.
	var islet_plan := [
		{"name": "IsletEast", "bearing": 0.55, "radius": 5.4, "gap": 4.6, "height": 0.7, "depth": 9.0},
		{"name": "IsletNorth", "bearing": 2.15, "radius": 4.4, "gap": 5.2, "height": -1.9, "depth": 7.5},
	]
	for plan: Dictionary in islet_plan:
		var bearing: float = plan["bearing"]
		var islet := Landmass.new()
		islet.name = plan["name"]
		islet.base_radius = plan["radius"]
		islet.rim_amp = 0.75
		islet.rim_phase = rng.randf_range(0.0, TAU)
		islet.base_height = plan["height"]
		islet.depth = plan["depth"]
		# Small ground under a big spear: keep it nearly flat or it is a hazard.
		islet.relief_scale = 0.35
		var reach: float = main.rim_radius(bearing) + float(plan["gap"]) + islet.base_radius
		islet.centre = Vector2(cos(bearing), sin(bearing)) * reach
		landmasses.append(islet)


func _setup_features() -> void:
	# The hollow the place is named after. A shallow bowl in the middle means
	# the centre of the map is overlooked from every side, which is what makes
	# holding the rim worth something.
	features.append(Feature.new(Vector2.ZERO, 10.5, -2.1))

	# The high ground (4.10). Deliberately off-centre and on one flank, so it
	# commands the hollow without commanding the whole island.
	knoll_centre = Vector2(-7.4, -8.6)
	knoll_height = 4.1
	features.append(Feature.new(knoll_centre, 9.5, knoll_height))

	# A second, gentler shoulder on the far side, so the knoll is not the only
	# elevated ground and a spawn there is not automatically the worst one.
	features.append(Feature.new(Vector2(9.8, 6.2), 7.5, 1.9))


func _setup_materials() -> void:
	# Both terrain materials are colourless white with vertex colour driving the
	# albedo. That keeps the whole island to two draw materials with no texture
	# memory at all, and it lets the generator paint slope, height and patchiness
	# straight into the mesh instead of authoring a splat map for terrain that
	# does not exist until load time.
	_grass_material = StandardMaterial3D.new()
	_grass_material.vertex_color_use_as_albedo = true
	_grass_material.roughness = 0.95
	_grass_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	_rock_material = StandardMaterial3D.new()
	_rock_material.vertex_color_use_as_albedo = true
	_rock_material.roughness = 0.86
	_rock_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED


# ------------------------------------------------------------- the oracle ---

## Which landmass covers this point, or null if it is over the void.
func landmass_at(x: float, z: float) -> Landmass:
	for mass: Landmass in landmasses:
		var local := Vector2(x, z) - mass.centre
		var r := local.length()
		if r < mass.rim_radius(local.angle()):
			return mass
	return null


## Ground height at a world point, or `NO_LAND` over the void.
func height_at(x: float, z: float) -> float:
	var mass := landmass_at(x, z)
	if mass == null:
		return NO_LAND
	return _height_on(mass, x, z)


func is_land(x: float, z: float) -> bool:
	return landmass_at(x, z) != null


## Ground point as a Vector3, for callers that are about to place something.
func surface_point(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x, z), z)


func _height_on(mass: Landmass, x: float, z: float) -> float:
	var local := Vector2(x, z) - mass.centre
	var edge := mass.rim_radius(local.angle())
	var t := clampf(local.length() / maxf(edge, 0.001), 0.0, 1.0)

	# Relief is faded out toward the rim so the outline is a clean lip. Left in,
	# noise pokes through the droop and the silhouette turns to fur.
	var relief_fade := 1.0 - smoothstep(0.55, 1.0, t)
	var h := mass.base_height
	h += _relief_noise.get_noise_2d(x, z) * RELIEF * mass.relief_scale * relief_fade
	h += _detail_noise.get_noise_2d(x, z) * 0.22 * mass.relief_scale * relief_fade

	for feature: Feature in features:
		h += feature.contribution(x, z)

	h -= mass.rim_droop() * smoothstep(RIM_DROOP_START, 1.0, t)
	return h


## Steepness as a gradient magnitude (rise over run), for callers deciding
## whether something can stand here. 0.0 is flat, 1.0 is 45°.
##
## Sampled rather than differentiated because the height is a sum of noise,
## cosine features and a smoothstep, and the point of the number is "can a Gub
## walk on it", which is a question about a Gub-sized patch — not about the
## analytic tangent at an infinitesimal point.
func slope_at(x: float, z: float, span: float = 0.6) -> float:
	var here := height_at(x, z)
	if here <= NO_LAND:
		return 1.0
	var dx := _sample_or(x + span, z, here) - _sample_or(x - span, z, here)
	var dz := _sample_or(x, z + span, here) - _sample_or(x, z - span, here)
	return Vector2(dx, dz).length() / (2.0 * span)


## Ground normal at a world point. Props that lie on the ground — pebbles,
## fallen petals, path stones — are tilted onto this; props that grow out of it
## are not, because a leaning tree reads as a mistake rather than as terrain.
func normal_at(x: float, z: float, span: float = 0.6) -> Vector3:
	var here := height_at(x, z)
	if here <= NO_LAND:
		return Vector3.UP
	var dx := _sample_or(x + span, z, here) - _sample_or(x - span, z, here)
	var dz := _sample_or(x, z + span, here) - _sample_or(x, z - span, here)
	return Vector3(-dx, 2.0 * span, -dz).normalized()


func _sample_or(x: float, z: float, fallback: float) -> float:
	var h := height_at(x, z)
	return fallback if h <= NO_LAND else h


## How far this point is from the nearest rim of the landmass it sits on.
## Negative over the void. Used by everything that wants to keep off the edge.
func inset_at(x: float, z: float) -> float:
	var mass := landmass_at(x, z)
	if mass == null:
		return -1.0
	var local := Vector2(x, z) - mass.centre
	return mass.rim_radius(local.angle()) - local.length()


## Radius of a disc centred on the origin that contains every landmass. The
## preview cameras and the ambience volumes frame themselves off this rather
## than off a hard-coded number that would drift as the layout is tuned.
func extent() -> float:
	var far := 0.0
	for mass: Landmass in landmasses:
		far = maxf(far, mass.centre.length() + mass.base_radius + mass.rim_amp)
	return far


# -------------------------------------------------------------- the build ---

## Instantiate every landmass under `parent`: one MeshInstance3D and one
## StaticBody3D each.
func build_into(parent: Node3D) -> void:
	for mass: Landmass in landmasses:
		var chunk := _build_landmass(mass)
		parent.add_child(chunk)


func _build_landmass(mass: Landmass) -> Node3D:
	var root := Node3D.new()
	root.name = mass.name

	var surface := _build_surface(mass)
	var underside := _build_underside(mass)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
	# The root is drawn faceted while the ground above it is drawn smooth. That
	# is an art decision, not an oversight: the MegaKit's rocks and trees are
	# hard-edged low-poly, and a smoothly-shaded underside read as a mound of
	# clay that the props on top of it did not belong to. Faceting it also makes
	# the crag noise and the five buttress ribs actually visible — smooth normals
	# had been averaging them into nothing.
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _faceted(underside))
	mesh.surface_set_material(0, _grass_material)
	mesh.surface_set_material(1, _rock_material)

	var visual := MeshInstance3D.new()
	visual.name = "Terrain"
	visual.mesh = mesh
	# The underside is a closed cone seen only from outside and below; letting it
	# cast shadows buys nothing and doubles its cost in the moon's cascade.
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(visual)

	# Collision is the **top surface only**. The rocky root is decoration hanging
	# in a place no Gub can reach: anything that leaves the rim is already dead
	# by `MatchState._tick_void`, and a second concave shape of five thousand
	# triangles would be paid for on every broadphase query for nothing.
	var body := StaticBody3D.new()
	body.name = "Collider"
	body.collision_layer = 1  # world
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(_faces_from(surface))
	shape.shape = concave
	body.add_child(shape)
	root.add_child(body)

	return root


## The walkable top: a fan around a centre vertex, then concentric quad rings out
## to the rim.
func _build_surface(mass: Landmass) -> Array:
	var verts := PackedVector3Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Index 0 is the single centre vertex; ring `i` (1..SURFACE_RINGS) starts at
	# 1 + (i - 1) * SECTORS.
	verts.append(Vector3(mass.centre.x, _height_on(mass, mass.centre.x, mass.centre.y), mass.centre.y))
	colours.append(_ground_colour(mass, mass.centre.x, mass.centre.y, 0.0))
	uvs.append(Vector2.ZERO)

	for i in range(1, SURFACE_RINGS + 1):
		var t := float(i) / float(SURFACE_RINGS)
		for j in SECTORS:
			var theta := TAU * float(j) / float(SECTORS)
			var r := mass.rim_radius(theta) * t
			var x := mass.centre.x + cos(theta) * r
			var z := mass.centre.y + sin(theta) * r
			verts.append(Vector3(x, _height_on(mass, x, z), z))
			colours.append(_ground_colour(mass, x, z, t))
			uvs.append(Vector2(x, z) * 0.12)

	# Wound so that the *outward* (upward) side is the front face. See the note
	# on `_packed` for why that is the opposite of what it looks like it should
	# be, and what it costs to get wrong.
	for j in SECTORS:
		var a := 1 + j
		var b := 1 + (j + 1) % SECTORS
		indices.append_array([0, a, b])

	for i in range(1, SURFACE_RINGS):
		var inner := 1 + (i - 1) * SECTORS
		var outer := 1 + i * SECTORS
		for j in SECTORS:
			var jn := (j + 1) % SECTORS
			indices.append_array([inner + j, outer + j, outer + jn])
			indices.append_array([inner + j, outer + jn, inner + jn])

	return _packed(verts, colours, uvs, indices)


## The rocky root. Ring 0 duplicates the surface's rim ring exactly, so the two
## meshes share an edge with no crack — but as separate vertices, which is what
## gives the rim its hard crease between grass and rock.
func _build_underside(mass: Landmass) -> Array:
	var verts := PackedVector3Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var lowest := INF
	for k in range(0, UNDERSIDE_RINGS + 1):
		var s := float(k) / float(UNDERSIDE_RINGS)
		# Shrink close to linearly with a slight bulge under the rim, and drop
		# close to linearly too. The first pass used a steep power on both and
		# rendered as a shallow bowl with a sudden point on the bottom: nearly
		# all of the vertical extent was being spent where the radius was already
		# tiny, so the root looked like a hull rather than something torn out of
		# bedrock.
		var shrink: float = pow(1.0 - s, 0.85) * (1.0 + 0.20 * sin(PI * s))
		var drop: float = mass.depth * pow(s, 1.12)
		for j in SECTORS:
			var theta := TAU * float(j) / float(SECTORS)
			var edge := mass.rim_radius(theta)
			# Vertical buttresses: five ribs running down the root, strongest
			# halfway and gone at both ends so the rim still welds and the tip
			# still comes to a point. Integer harmonic, so it closes at TAU.
			var ribs := 1.0 + 0.24 * sin(theta * 5.0 + mass.rim_phase * 2.0) * sin(PI * s)
			var r := edge * shrink * ribs
			var x := mass.centre.x + cos(theta) * r
			var z := mass.centre.y + sin(theta) * r
			var rim_y := _height_on(mass, mass.centre.x + cos(theta) * edge,
				mass.centre.y + sin(theta) * edge)
			var y := rim_y - drop
			if k > 0:
				# Crag displacement, faded in from the rim so the seam stays
				# welded and faded out at the tip so it still comes to a point.
				var amount := sin(PI * s) * 2.1 * (mass.depth / 17.0)
				var n := _crag_noise.get_noise_3d(x * 1.1, y * 0.8, z * 1.1)
				var outward := Vector3(cos(theta), 0.0, sin(theta))
				var displaced := Vector3(x, y, z) + outward * n * amount
				displaced.y += _crag_noise.get_noise_3d(z * 1.4, x * 1.4, y) * amount * 0.7
				x = displaced.x
				y = displaced.y
				z = displaced.z
			lowest = minf(lowest, y)
			verts.append(Vector3(x, y, z))
			colours.append(_rock_colour(s, x, z))
			uvs.append(Vector2(theta * 2.0, s * mass.depth * 0.1))

	var tip_index := verts.size()
	verts.append(Vector3(mass.centre.x, lowest - mass.depth * 0.16, mass.centre.y))
	colours.append(ROCK_LOW)
	uvs.append(Vector2.ZERO)

	for k in range(0, UNDERSIDE_RINGS):
		var upper := k * SECTORS
		var lower := (k + 1) * SECTORS
		for j in SECTORS:
			var jn := (j + 1) % SECTORS
			# Wound the opposite way round from the surface: this shell is seen
			# from outside and below.
			indices.append_array([upper + j, lower + j, lower + jn])
			indices.append_array([upper + j, lower + jn, upper + jn])

	var last := UNDERSIDE_RINGS * SECTORS
	for j in SECTORS:
		var jn := (j + 1) % SECTORS
		indices.append_array([last + j, tip_index, last + jn])

	return _packed(verts, colours, uvs, indices)


## Grass, dirt and rock painted from slope, height and a low-frequency tint, so
## the ground has patches without a single texture being loaded.
func _ground_colour(mass: Landmass, x: float, z: float, t: float) -> Color:
	# Two scales of mottling. The broad one makes meadows and shaded patches; the
	# fine one gives the surface grain at the distance a player actually stands
	# from it, without which a metre of ground is one flat colour.
	var tint := _tint_noise.get_noise_2d(x, z) * 0.5 + 0.5
	tint = clampf(tint + _tint_noise.get_noise_2d(x * 7.0, z * 7.0) * 0.14, 0.0, 1.0)
	var colour := GRASS_DARK.lerp(GRASS_LIGHT, tint)
	colour = colour.lerp(GRASS_MOSS, clampf(_detail_noise.get_noise_2d(x * 0.6, z * 0.6)
		* 0.5 + 0.5, 0.0, 1.0) * 0.45)

	# Steep faces lose their grass. This is the term that makes the knoll read as
	# a hill rather than as a green blister — but the first thresholds were low
	# enough that the gentle shoulder counted as a cliff and the whole map went
	# the colour of sand.
	var steep := smoothstep(0.58, 1.05, slope_at(x, z, 0.9))
	colour = colour.lerp(DIRT, steep)

	# The last stretch before the rim turns to bare earth, which is what sells
	# the transition into the rocky root below. Measured in **metres** from the
	# lip rather than as a fraction of the radius: on a fraction, the same band
	# that is a two-metre skirt on the main island swallows an entire five-metre
	# islet, and the islets came out looking like sandbanks.
	var edge := mass.rim_radius((Vector2(x, z) - mass.centre).angle())
	var from_rim := (1.0 - t) * edge
	colour = colour.lerp(RIM_EARTH,
		1.0 - smoothstep(0.0, minf(1.8, edge * 0.12), from_rim))

	# Height darkening: the hollow sits in its own shade even before the fog and
	# the torches get to it, which is most of why the middle of the map reads as
	# lower than the rim from across the island.
	var relative := _height_on(mass, x, z) - mass.base_height
	colour = colour.darkened(clampf(-relative * 0.035, 0.0, 0.12))
	return colour


func _rock_colour(s: float, x: float, z: float) -> Color:
	var vein := _crag_noise.get_noise_2d(x * 2.0, z * 2.0) * 0.5 + 0.5
	var base := ROCK_HIGH.lerp(ROCK_LOW, smoothstep(0.0, 0.75, s))
	# Moss creeping over the lip, only in the first metre or so of the root.
	base = base.lerp(GRASS_MOSS.darkened(0.4), (1.0 - smoothstep(0.0, 0.09, s)) * 0.4)
	return base.lerp(base.darkened(0.25), vein)


# ------------------------------------------------------------- mesh plumbing ---

## Assemble a Godot surface array, generating smooth normals by accumulating the
## face normal of every triangle into its three vertices.
##
## `SurfaceTool` would do this too, but it would first re-index the mesh by
## hashing every vertex — work that is pure waste here, because the ring
## topology already says exactly which triangles share which vertex.
##
## **The cross product is `(c - a) x (b - a)`, not the other way round.** Godot
## draws a triangle front-face-first when its vertices are *clockwise* as seen
## from the front, which makes the outward normal of `(a, b, c)` the reverse of
## the one every textbook writes down. Building it the intuitive way produces a
## mesh that is inside-out: the top surface is culled when you look down at it,
## so you see straight through the island to the sky below, and — because the
## props standing on it are lit perfectly normally — it presents as a *lighting*
## bug. Two rounds of chasing ambient energy, albedo floors and shadow acne went
## past before a flat unshaded override showed the ground simply was not there.
static func _packed(verts: PackedVector3Array, colours: PackedColorArray,
		uvs: PackedVector2Array, indices: PackedInt32Array) -> Array:
	var normals := PackedVector3Array()
	normals.resize(verts.size())

	var i := 0
	while i < indices.size():
		var ia := indices[i]
		var ib := indices[i + 1]
		var ic := indices[i + 2]
		var face := (verts[ic] - verts[ia]).cross(verts[ib] - verts[ia])
		# Not normalised: the raw cross product is twice the triangle's area, so
		# accumulating it weights each face by how much of the surface it is.
		normals[ia] += face
		normals[ib] += face
		normals[ic] += face
		i += 3

	for n in normals.size():
		var v := normals[n]
		normals[n] = v.normalized() if v.length_squared() > 1e-12 else Vector3.UP

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Re-emit an indexed surface with one normal per triangle instead of one per
## vertex, for hard-edged low-poly shading. Costs three vertices per triangle
## instead of a shared ring, which for a few thousand triangles of scenery is a
## trade worth making for the silhouette it buys.
static func _faceted(arrays: Array) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var out_verts := PackedVector3Array()
	var out_normals := PackedVector3Array()
	var out_colours := PackedColorArray()
	var out_uvs := PackedVector2Array()

	var i := 0
	while i < indices.size():
		var ia := indices[i]
		var ib := indices[i + 1]
		var ic := indices[i + 2]
		# Same handedness as `_packed`: Godot front faces are clockwise.
		var face := (verts[ic] - verts[ia]).cross(verts[ib] - verts[ia]).normalized()
		if face.length_squared() < 0.5:
			face = Vector3.DOWN
		for index: int in [ia, ib, ic]:
			out_verts.append(verts[index])
			out_normals.append(face)
			out_colours.append(colours[index])
			out_uvs.append(uvs[index])
		i += 3

	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = out_verts
	out[Mesh.ARRAY_NORMAL] = out_normals
	out[Mesh.ARRAY_TEX_UV] = out_uvs
	out[Mesh.ARRAY_COLOR] = out_colours
	return out


## Expand an indexed surface array into the flat triangle soup that
## `ConcavePolygonShape3D` wants.
static func _faces_from(arrays: Array) -> PackedVector3Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for i in indices.size():
		faces[i] = verts[indices[i]]
	return faces
