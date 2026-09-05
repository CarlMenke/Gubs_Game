extends Node3D
## Fixed-camera viewer for Whisperbloom Hollow. Development tool, not shipped.
##
## The island is generated (D-007), so there is no editor viewport to judge it
## in — the map does not exist until something runs `arena.gd`. This scene is
## that something: it loads the **real** `scenes/world/arena.tscn`, never a
## simplified copy, and then frames it from a named camera.
##
## Every framing is solved from the arena's own data (`island.extent()`,
## `landmarks.torch_spots`, the spawn ring) rather than from typed coordinates,
## so the shots keep pointing at the shrine after somebody moves the shrine.
##
## Add `match` as a second argument to run the **real match path** as well: an
## offline session on `Net`, a fake roster, and Gubs spawned by `MatchState`
## through `register_arena`. That is the check that matters — it is the
## difference between "the island renders" and "the island is a level".
##
## Usage:
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://tools/preview_island.tscn out.png <ticks> <view> [match]
##
##   views: wide  under  eye  shrine  grove  arch  bridge  spawns  hollow

const ARENA := preload("res://scenes/world/arena.tscn")

## Peer ids for the stand-in players, well outside anything ENet hands out —
## the same trick `tools/combat_range.gd` uses (D-011).
const DUMMY_BASE := 900
const DUMMY_COUNT := 5

const VIEWS := ["wide", "under", "eye", "shrine", "grove", "arch", "bridge",
	"spawns", "hollow"]

## Lighting diagnostics. The map is lit almost entirely by ambient and torches,
## which makes "this surface is black" ambiguous between four different causes —
## no ambient reaching it, inverted normals, shadow acne, or an albedo that is
## simply too dark. These flags take one suspect out of the picture at a time.
const FLAGS := {
	"noshadow": "turn the moon's shadows off",
	"noon": "moon at daylight energy, to see the geometry plainly",
	"nofog": "volumetric fog off, so surfaces are judged unmediated",
	"flatterrain": "terrain in flat unshaded magenta, to see where it actually is",
	"notorch": "every torch light off, leaving only the moon and the sky ambient",
	"hud": "keep the match HUD, to judge it over the real map rather than a testbed",
}

var _view: String = "wide"
var _run_match: bool = false
var _flags: Dictionary = {}
var _arena: Arena
var _frames: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for arg: String in args:
		if VIEWS.has(arg):
			_view = arg
		elif arg == "match":
			_run_match = true
		elif FLAGS.has(arg):
			_flags[arg] = true

	# The session has to exist before the arena's `_ready` runs, because that is
	# where `register_arena` is called and where the host starts the warmup.
	if _run_match:
		_start_session()

	_arena = ARENA.instantiate() as Arena
	# This tool exists to judge the island, and a crosshair and a kill feed over
	# the shot are in the way of that — so the HUD is off unless asked for. Set
	# before `add_child`, because the HUD is built in the arena's own `_ready`.
	# `hud` turns it back on, which is the only way to see the two together.
	_arena.show_hud = _flags.has("hud")
	add_child(_arena)

	_apply_diagnostics()
	_build_camera()
	if _run_match:
		_report_roster()


## Reach into the built arena and switch things off. Only ever runs when a flag
## was passed, so the default render is always the real one.
func _apply_diagnostics() -> void:
	if _flags.is_empty():
		return
	var moon := _arena.get_node_or_null("Moon") as DirectionalLight3D
	if moon != null:
		if _flags.has("noshadow"):
			moon.shadow_enabled = false
		if _flags.has("noon"):
			moon.light_energy = 3.0
			moon.light_color = Color(1, 1, 1)
	if _flags.has("notorch"):
		for torch in _arena.get_node("Torches").get_children():
			(torch.get_node("Light") as OmniLight3D).visible = false
	if _flags.has("flatterrain"):
		var flat := StandardMaterial3D.new()
		flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flat.albedo_color = Color(1.0, 0.0, 0.7)
		for chunk in _arena.get_node("Terrain").get_children():
			(chunk.get_node("Terrain") as MeshInstance3D).material_override = flat
	if _flags.has("nofog"):
		var world := _arena.get_node_or_null("Environment") as WorldEnvironment
		if world != null:
			# Duplicated, so a diagnostic run can never write through to the
			# shared `arena_env.tres` on disk.
			world.environment = world.environment.duplicate()
			world.environment.volumetric_fog_enabled = false
	print("preview_island: diagnostics %s" % ", ".join(_flags.keys()))


func _start_session() -> void:
	Net.start_offline()
	for i in DUMMY_COUNT:
		Net.players[DUMMY_BASE + i] = {
			"name": "Gub %d" % (i + 1), "team": 0, "ready": true,
		}
	Net.roster_changed.emit()
	var config := Net.config
	config.warmup_time = 0.0
	config.spawn_protection = 0.0
	config.time_limit = 0


# ------------------------------------------------------------------ framing ---

## Solve this view's camera from what the arena actually built.
func _build_camera() -> void:
	var framing := _framing()
	var camera := Camera3D.new()
	add_child(camera)
	camera.fov = framing["fov"]
	camera.far = 500.0
	camera.look_at_from_position(framing["eye"], framing["look"], Vector3.UP)
	# Claimed after the arena — and after any Gub — so it wins the viewport over
	# a `GubCamera` that has made itself current.
	camera.make_current()


func _framing() -> Dictionary:
	var island := _arena.island
	var reach := island.extent()
	var shrine := _ground(island.knoll_centre)
	var grove := _ground(Vector2(6.4, -6.1))
	var centre := _ground(Vector2.ZERO)

	match _view:
		"under":
			# From below and outside: the only view that shows the rocky root,
			# which is half of what makes this read as a *floating* island.
			return {"eye": Vector3(reach * 0.9, -20.0, reach * 1.1),
				"look": Vector3(0.0, -6.0, 0.0), "fov": 62.0}
		"eye":
			# Standing on the first spawn pad, looking across the map. This is
			# the only framing in the list a player will ever actually have.
			var pad := _arena.spawn_points[0].origin + Vector3.UP * 1.55
			return {"eye": pad, "look": centre + Vector3.UP * 1.2, "fov": 75.0}
		"shrine":
			return {"eye": shrine + Vector3(9.0, 1.2, 9.5),
				"look": shrine + Vector3.UP * 2.0, "fov": 55.0}
		"grove":
			return {"eye": grove + Vector3(7.5, 2.4, 6.5),
				"look": grove + Vector3.UP * 1.6, "fov": 58.0}
		"arch":
			var arch := _ground(Vector2(cos(Landmarks.EAST_BEARING - 0.55),
				sin(Landmarks.EAST_BEARING - 0.55))
				* (island.landmasses[0].rim_radius(Landmarks.EAST_BEARING - 0.55) - 6.5))
			var inward := (centre - arch).normalized()
			return {"eye": arch - inward * 11.0 + Vector3.UP * 2.2,
				"look": arch + Vector3.UP * 2.6, "fov": 60.0}
		"bridge":
			var islet := island.landmasses[1]
			var anchor := _ground(Vector2(cos(Landmarks.EAST_BEARING),
				sin(Landmarks.EAST_BEARING))
				* (island.landmasses[0].rim_radius(Landmarks.EAST_BEARING) - 6.0))
			var far := _ground(islet.centre)
			return {"eye": anchor + Vector3.UP * 2.0,
				"look": far + Vector3.UP * 1.4, "fov": 68.0}
		"spawns":
			# High and steep, so all eight pads and the ground between them are
			# in one frame and the spread can be judged rather than trusted.
			# Kept as close as that allows: the volumetric fog is tuned for
			# distances *on* a 40-60 m island (D-009), and a camera forty metres
			# off the map renders almost pure haze.
			return {"eye": Vector3(0.0, reach * 0.72, reach * 0.34),
				"look": centre, "fov": 72.0}
		"hollow":
			return {"eye": centre + Vector3(13.0, 3.0, 13.0),
				"look": centre + Vector3.UP * 1.0, "fov": 70.0}
		_:
			# `wide`: the establishing shot. Low enough that the horizon and the
			# island's underside are both in frame, which is where the sky and
			# the silhouette have to work together — and no further out than the
			# fog can see through, for the reason given under `spawns`.
			return {"eye": Vector3(-reach * 0.52, 9.0, reach * 0.78),
				"look": Vector3(0.0, -2.5, 0.0), "fov": 62.0}


func _ground(at: Vector2) -> Vector3:
	var here := _arena.island.surface_point(at.x, at.y)
	return here if here.y > IslandGenerator.NO_LAND else Vector3(at.x, 0.0, at.y)


# ------------------------------------------------------------------- match ---

func _report_roster() -> void:
	print("preview_island: phase=%d gubs=%d spawns=%d" % [
		MatchState.phase, MatchState.gubs.size(), _arena.spawn_points.size()])
	var closest := INF
	for i in _arena.spawn_points.size():
		var origin := _arena.spawn_points[i].origin
		for j in range(i + 1, _arena.spawn_points.size()):
			closest = minf(closest, origin.distance_to(_arena.spawn_points[j].origin))
		print("  spawn %d at %v (ground %.2f, slope %.2f, inset %.1f)" % [
			i, origin, _arena.island.height_at(origin.x, origin.z),
			_arena.island.slope_at(origin.x, origin.z),
			_arena.island.inset_at(origin.x, origin.z)])
	# Two pads closer together than this and a full lobby opens the match inside
	# each other's spear range with spawn protection as the only thing in the way.
	print("  closest pair %.1f m" % closest)


## Every Gub's height above the ground it should be standing on. The one thing a
## still frame cannot tell you is whether the Gubs are *falling* — at spawn they
## are a few centimetres up by design, and by tick 30 they should have settled.
## A Gub still descending here is a Gub on its way to `VOID_HEIGHT`.
func _physics_process(_delta: float) -> void:
	_frames += 1
	if not _run_match or (_frames != 5 and _frames != 60 and _frames != 150):
		return
	for peer_id: int in MatchState.gubs:
		var gub: Gub = MatchState.gubs[peer_id]
		if not is_instance_valid(gub):
			continue
		var ground := _arena.island.height_at(gub.global_position.x, gub.global_position.z)
		print("  f%-4d %-8s y=%+.2f ground=%+.2f  above=%+.2f grounded=%s" % [
			_frames, gub.display_name, gub.global_position.y, ground,
			gub.global_position.y - ground, gub.is_on_floor()])
