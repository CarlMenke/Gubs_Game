extends Node3D
## Close-up of the Gub's hand across a clip, for tuning where the spear sits.
## Development tool, not shipped.
##
## Godot --path . --script tools/snapshot.gd -- \
##     res://tools/preview_grip.tscn out.png 25 <clip> [ox,oy,oz] [rx,ry,rz]
##
## The two optional vectors override the grip so values can be swept from the
## command line instead of edited and re-imported one at a time.

const GUB := preload("res://scenes/player/gub.tscn")

@export var clip: String = "SpearThrow"
@export var samples: int = 5
@export var spacing: float = 1.15

var _offset: Vector3 = Vector3.INF
var _rotation: Vector3 = Vector3.ZERO


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		clip = args[3]
	if args.size() >= 6:
		_offset = _parse(args[4])
		_rotation = _parse(args[5])

	var length := 1.0
	var x := -spacing * (samples - 1) * 0.5
	for i in samples:
		var gub := GUB.instantiate() as Gub
		add_child(gub)
		gub.position = Vector3(x, 0, 0)
		x += spacing
		# No ground in this scene, and the body would happily fall through it.
		gub.set_physics_process(false)
		(gub.get_node("CameraRig") as Node3D).queue_free()
		(gub.get_node("Nameplate") as Node3D).queue_free()
		(gub.get_node("AnimationTree") as Node).queue_free()

		var player := gub.find_child("AnimationPlayer", true, false) as AnimationPlayer
		length = player.get_animation(clip).length
		player.play(clip)
		player.advance(length * float(i) / float(samples))
		player.pause()
		if _offset != Vector3.INF:
			gub.held_spear.set_grip(_offset, _rotation)

	_build_stage(length)


static func _parse(text: String) -> Vector3:
	var parts := text.split(",")
	if parts.size() != 3:
		return Vector3.ZERO
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())


func _build_stage(length: float) -> void:
	var label := Label3D.new()
	label.text = "%s   (%.2fs)" % [clip, length]
	label.font_size = 64
	label.pixel_size = 0.0018
	label.position = Vector3(0, 2.3, 0)
	add_child(label)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, -25, 0)
	key.light_energy = 2.4
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, 160, 0)
	fill.light_energy = 0.7
	fill.light_color = Color(0.6, 0.75, 1.0)
	add_child(fill)

	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(0, 1.35, 3.6), Vector3(0, 1.15, 0), Vector3.UP)
	cam.fov = 40.0
	add_child(cam)
	cam.make_current()
