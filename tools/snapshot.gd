extends SceneTree
## Render a scene to a PNG and quit. Development tool, not shipped.
##
## Godot's `--headless` display driver uses the dummy rasteriser and produces no
## image, so this runs in a real (small, briefly visible) window instead and
## grabs the viewport once the scene has settled. That settling matters: sky
## shaders, GPU particles and any `_ready` that spawns geometry all need a few
## frames before the first frame is representative.
##
## Usage:
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://scenes/whatever.tscn out.png [warmup_frames]

const DEFAULT_WARMUP := 30

var _target: Node = null
var _out_path: String = "snapshot.png"
var _warmup: int = DEFAULT_WARMUP
var _frame: int = 0
var _failed: bool = false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("snapshot.gd: expected <scene.tscn> <out.png> [warmup_frames]")
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
	_frame += 1
	if _frame < _warmup:
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
