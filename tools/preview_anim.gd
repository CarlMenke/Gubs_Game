extends Node3D
## Contact sheet: one Gub per sampled moment of a clip, so a whole animation can
## be judged from a single snapshot. Development tool, not shipped.
##
##   Godot --path . --resolution 1600x700 --script tools/snapshot.gd -- \
##       res://tools/preview_anim.tscn out.png 30 Throw [from] [to]
##
## `from`/`to` narrow the sheet to a window of the clip in seconds. A 3.8 s throw
## spread over six evenly-spaced Gubs puts one sample anywhere near the release,
## which is not enough to pick a frame off; asking for 1.45-1.80 puts all six
## there. Without them the whole clip is sampled, as before.
##
## The Gubs stand on a floor at y = 0 and are placed to fill the frame at
## whatever `--resolution` was asked for: a contact sheet exists to answer "are
## the feet planted, is the body facing the same way in every pose, is the hip
## drifting across the sheet", and all three of those need a ground line and a
## Gub big enough to see. `art/generated/gub.glb` imports at 1:1 (1.80 m tall,
## `root_scale = 1.0`), so nothing here scales it — the old asset came in at
## 0.35 and this file used to cancel that out in two places.

@export var clip: String = "Idle"
@export var samples: int = 6
@export var spacing: float = 1.4

## What the frame has to hold vertically: the floor a little below the feet, the
## 1.80 m Gub, its time stamp and the title. The camera is centred on the middle
## of that and never framed tighter than FRAME_MIN, but a wide render (the
## 1600x700 these sheets are taken at) is usually limited by the width instead.
const FRAME_LOW := -0.3
const FRAME_HIGH := 2.6
const FRAME_MIN := 3.2
## Elbow room either side of the two end Gubs, so an arm never leaves the frame.
const FRAME_MARGIN := 1.5
const GUB := "res://art/generated/gub.glb"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		clip = args[3]

	var scene := load(GUB) as PackedScene
	var probe := scene.instantiate()
	var probe_ap := probe.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if not probe_ap.has_animation(clip):
		push_error("preview_anim: %s has no clip '%s' (has %s)"
			% [GUB, clip, ", ".join(probe_ap.get_animation_list())])
		probe.free()
		return
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
		var n := scene.instantiate() as Node3D
		add_child(n)
		n.position = Vector3(x, 0, 0)
		x += spacing
		var ap := n.find_child("AnimationPlayer", true, false) as AnimationPlayer
		ap.play(clip)
		ap.advance(from + step * float(i))
		ap.pause()

		# Above the head, not below the feet: the floor is the reference the
		# feet are being judged against, and a number sitting on it reads as
		# part of the pose.
		var stamp := Label3D.new()
		stamp.text = "%.2f" % (from + step * float(i))
		stamp.font_size = 64
		stamp.pixel_size = 0.0018
		stamp.position = Vector3(0.0, 1.95, 0.0)
		n.add_child(stamp)

	var label := Label3D.new()
	label.text = "%s   (%.2fs)" % [clip, length]
	label.font_size = 96
	label.pixel_size = 0.0022
	label.position = Vector3(0, 2.35, 0)
	add_child(label)

	# The ground, as a line rather than a plane. The camera below is orthographic
	# and level, so a floor plane at y = 0 would be exactly edge-on and invisible;
	# a 2 cm bar is four pixels of unambiguous "this is where y = 0 is", which is
	# what "are the feet planted?" needs. It sits behind the Gubs so a foot draws
	# over it, and a foot that hovers leaves the line showing underneath.
	var ground := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(120.0, 0.02, 0.02)
	ground.mesh = bar
	ground.position = Vector3(0.0, 0.0, -0.8)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.38, 0.42)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground.material_override = mat
	add_child(ground)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -30, 0)
	key.light_energy = 2.4
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, 150, 0)
	fill.light_energy = 0.6
	fill.light_color = Color(0.6, 0.75, 1.0)
	add_child(fill)

	# Orthographic, which matters more here than it sounds. Under perspective the
	# end Gubs of a 7 m wide sheet are seen from 40° off to the side, so a clip
	# whose facing never changes looks like it swings through 80° across the
	# sheet — and "do all six poses face the same way" is one of the two
	# questions this tool exists to answer. In parallel projection every sample
	# is seen from exactly the same angle, and the floor is a straight line the
	# feet either touch or do not.
	#
	# The frame is as tall as the content needs, or taller if the row of Gubs
	# would not otherwise fit across: `size` is the vertical extent (the viewport
	# keeps height), so the width follows from the aspect the render asked for.
	var view := get_viewport().get_visible_rect().size
	var aspect: float = view.x / maxf(view.y, 1.0)
	var wide := (spacing * float(samples - 1) + FRAME_MARGIN) / aspect
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(FRAME_MIN, wide)
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0, (FRAME_LOW + FRAME_HIGH) * 0.5, 20.0)
	add_child(cam)
	cam.make_current()
