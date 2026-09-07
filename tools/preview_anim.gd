extends Node3D
## Contact sheet: one Gub per sampled moment of a clip, so a whole animation can
## be judged from a single snapshot. Development tool, not shipped.
##
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://tools/preview_anim.tscn out.png 30 SpearThrow [from] [to]
##
## `from`/`to` narrow the sheet to a window of the clip in seconds. A 1.53 s
## throw spread over six evenly-spaced Gubs puts one sample anywhere near the
## release, which is not enough to pick a frame off; asking for 0.45-0.66 puts
## all six there. Without them the whole clip is sampled, as before.

@export var clip: String = "Idle"
@export var samples: int = 6
@export var spacing: float = 1.5

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		clip = args[3]

	var probe := (load("res://art/generated/gub.glb") as PackedScene).instantiate()
	var probe_ap := probe.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var length: float = probe_ap.get_animation(clip).length
	probe.free()

	var from: float = float(args[4]) if args.size() >= 5 else 0.0
	# The last sample lands *on* `to` when a window is asked for, and one step
	# short of the end when it is not: a looping clip's last frame is its first.
	var to: float = float(args[5]) if args.size() >= 6 else length
	var span := maxf(to - from, 0.0)
	var step := span / float(samples if args.size() < 6 else maxi(samples - 1, 1))

	var x := -spacing * (samples - 1) * 0.5
	for i in samples:
		var n := (load("res://art/generated/gub.glb") as PackedScene).instantiate() as Node3D
		add_child(n)
		n.position = Vector3(x, 0, 0)
		n.scale = Vector3.ONE * 0.35
		x += spacing
		var ap := n.find_child("AnimationPlayer", true, false) as AnimationPlayer
		ap.play(clip)
		ap.advance(from + step * float(i))
		ap.pause()

		var stamp := Label3D.new()
		stamp.text = "%.2f" % (from + step * float(i))
		stamp.font_size = 64
		stamp.pixel_size = 0.0025
		stamp.position = Vector3(0.0, -0.7, 0.0) / 0.35
		n.add_child(stamp)

	var label := Label3D.new()
	label.text = "%s   (%.2fs)" % [clip, length]
	label.font_size = 96
	label.pixel_size = 0.0025
	label.position = Vector3(0, 2.6, 0)
	add_child(label)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -30, 0)
	key.light_energy = 2.4
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, 150, 0)
	fill.light_energy = 0.6
	fill.light_color = Color(0.6, 0.75, 1.0)
	add_child(fill)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.1, 6.4)
	cam.fov = 48.0
	add_child(cam)
	cam.make_current()
