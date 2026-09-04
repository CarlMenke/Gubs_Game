extends Node3D
## Contact sheet: one Gub per sampled moment of a clip, so a whole animation can
## be judged from a single snapshot. Development tool, not shipped.

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

	var x := -spacing * (samples - 1) * 0.5
	for i in samples:
		var n := (load("res://art/generated/gub.glb") as PackedScene).instantiate() as Node3D
		add_child(n)
		n.position = Vector3(x, 0, 0)
		n.scale = Vector3.ONE * 0.35
		x += spacing
		var ap := n.find_child("AnimationPlayer", true, false) as AnimationPlayer
		ap.play(clip)
		ap.advance(length * float(i) / float(samples))
		ap.pause()

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
