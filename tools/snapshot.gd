extends SceneTree
## Render a scene to a PNG and quit. Development tool, not shipped.
##
## Godot's `--headless` display driver uses the dummy rasteriser and produces no
## image, so this runs in a real (small, briefly visible) window instead and
## grabs the viewport once the scene has settled. That settling matters: sky
## shaders, GPU particles and any `_ready` that spawns geometry all need a few
## frames before the first frame is representative.
##
## The frame rate is pinned to the physics rate on purpose. Uncapped, this loop
## runs at several hundred frames a second on a fast card, so `warmup_frames`
## would mean a different amount of *game* time on every machine — and a scene
## that scripts itself off `_physics_process` (the combat range fires its throw
## on frame 20) would be caught at a different moment each run. Capped, one
## warmup frame is one physics tick, everywhere.
##
## Usage:
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://scenes/whatever.tscn out.png [warmup_physics_ticks]

const DEFAULT_WARMUP := 30

var _target: Node = null
var _out_path: String = "snapshot.png"
var _warmup: int = DEFAULT_WARMUP
var _failed: bool = false


func _initialize() -> void:
	Engine.max_fps = int(ProjectSettings.get_setting(
		"physics/common/physics_ticks_per_second", 60))

	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("snapshot.gd: expected <scene.tscn> <out.png> [warmup_physics_ticks]")
		_failed = true
		return

	var scene_path: String = args[0]
	_out_path = args[1]
	if args.size() >= 3:
		_warmup = maxi(1, int(args[2]))

	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("snapshot.gd: could not load %s" % scene_path)
		_failed = true
		return

	_target = packed.instantiate()
	root.add_child(_target)
	print("snapshot: rendering %s for %d frames" % [scene_path, _warmup])


func _process(_delta: float) -> bool:
	if _failed:
		return true
	# Counted in *physics* ticks, not draw calls. The first few draws are slow
	# (scene load, shader compilation) and the physics engine catches up by
	# running several ticks inside one of them, so counting draws would fire the
	# shot a good half-second early and blame the scene for it.
	if Engine.get_physics_frames() < _warmup:
		return false

	# The viewport texture is only valid after the frame has actually been drawn.
	await process_frame
	RenderingServer.force_draw()
	var image := root.get_texture().get_image()
	if image == null:
		push_error("snapshot: viewport produced no image")
		return true

	var err := image.save_png(_out_path)
	if err != OK:
		push_error("snapshot: could not write %s (error %d)" % [_out_path, err])
	else:
		print("snapshot: wrote %s (%dx%d)" % [_out_path, image.get_width(), image.get_height()])
	return true
