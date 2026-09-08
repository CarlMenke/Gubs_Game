extends Node3D
## Close-up of the Gub's hand across a clip, for tuning where the spear sits.
## Development tool, not shipped.
##
## Godot --path . --resolution 2400x700 --script tools/snapshot.gd -- \
##     res://tools/preview_grip.tscn out.png 25 <clip> [ox,oy,oz] [rx,ry,rz] [from] [to]
##
## The two optional vectors override the grip so values can be swept from the
## command line instead of edited and re-imported one at a time. `from`/`to`
## narrow the sheet to a window of the clip in seconds, which is how the throw
## release (1.63 s of a 3.83 s clip) gets more than one sample on it.

const GUB := preload("res://scenes/player/gub.tscn")

@export var clip: String = "Throw"
@export var samples: int = 5
@export var spacing: float = 1.15

## Where the frame sits vertically. The hand lives between 0.9 and 1.5 m in
## every clip, so the sheet is centred on the chest rather than on the body:
## a grip is judged on 12 cm of fist, and a full-height 1.80 m Gub in a 700 px
## render leaves that fist 30 pixels tall.
const FRAME_LOW := 0.35
const FRAME_HIGH := 2.05
const FRAME_MIN := 1.7
## Elbow room past the two end Gubs. A spear is 1.24 m long and swings a long
## way from the hand during a throw.
const FRAME_MARGIN := 1.0

## Where the camera stands, in degrees around the Gub. 0 would be dead in front
## of it (the model faces −Z once `gub.tscn`'s 180° turn is applied), and dead
## in front cannot tell a spear pointing forward from one pointing across the
## body — which is half of what this tool is for. 35° to the Gub's right puts
## the spear hand nearest the camera and reads both axes at once.
const VIEW_AZIMUTH := 35.0
const VIEW_ELEVATION := 12.0

var _offset: Vector3 = Vector3.INF
var _rotation: Vector3 = Vector3.ZERO


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		clip = args[3]
	if args.size() >= 6:
		_offset = _parse(args[4])
		_rotation = _parse(args[5])

	# The camera is orthographic (see _build_stage), so every Gub is seen from
	# exactly the same angle — but only if none of them hides another. Laying
	# the row along the camera's own right vector instead of world X is what
	# guarantees that at an oblique viewing angle.
	#
	# That right vector is `-(cos a, 0, sin a)`, not `+`: `look_at_from_position`
	# builds the basis as x = up × z with z pointing *back* at the eye, so the
	# camera's own +X ends up on the far side of the row from world +X. Get the
	# sign wrong and the sheet reads right-to-left — later samples on the left —
	# which is how the first pass came to disbelieve its own time stamps.
	var azimuth := deg_to_rad(VIEW_AZIMUTH)
	var elevation := deg_to_rad(VIEW_ELEVATION)
	var eye := Vector3(sin(azimuth) * cos(elevation), sin(elevation),
		-cos(azimuth) * cos(elevation))
	var row := -Vector3(cos(azimuth), 0.0, sin(azimuth))

	var length := 1.0
	var from := 0.0
	var to := 0.0
	var windowed := args.size() >= 8
	for i in samples:
		var gub := GUB.instantiate() as Gub
		add_child(gub)
		gub.position = row * (float(i) - float(samples - 1) * 0.5) * spacing
		# No ground in this scene, and the body would happily fall through it.
		gub.set_physics_process(false)
		# `get_node_or_null`, because this tool has to keep working while the
		# animation tree is being rebuilt around it: the grip lives on the
		# skeleton and does not care whether an AnimationTree exists. The tree
		# goes away regardless — the AnimationPlayer below is driven directly.
		for spare in ["CameraRig", "Nameplate", "AnimationTree"]:
			var node := gub.get_node_or_null(spare)
			if node != null:
				node.queue_free()

		var player := gub.find_child("AnimationPlayer", true, false) as AnimationPlayer
		length = player.get_animation(clip).length
		from = float(args[6]) if windowed else 0.0
		to = float(args[7]) if windowed else length
		# The last sample lands *on* `to` when a window is asked for, and one
		# step short of the end when it is not (a looping clip's last frame is
		# its first).
		var step := (to - from) / float(maxi(samples - 1, 1) if windowed else samples)
		var at := from + step * float(i)
		player.play(clip)
		player.advance(at)
		player.pause()
		if _offset != Vector3.INF:
			gub.held_spear.set_grip(_offset, _rotation)

		var stamp := Label3D.new()
		stamp.text = "%.2f" % at
		stamp.font_size = 64
		stamp.pixel_size = 0.0016
		stamp.position = Vector3(0.0, 1.98, 0.0)
		# Billboarded, because this camera stands in *front* of the Gub — it has
		# to, the whole point is to see whether the shaft crosses the face — and
		# a Label3D faces its own +Z, which here is away from the camera. Left
		# flat the text renders back-to-front, and a mirrored "0.83" over a
		# mirrored sheet is what made the first pass misread which side of the
		# head the spear was on.
		stamp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		gub.add_child(stamp)

	_build_stage(length, from, to, eye)


static func _parse(text: String) -> Vector3:
	var parts := text.split(",")
	if parts.size() != 3:
		return Vector3.ZERO
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())


func _build_stage(length: float, from: float, to: float, eye: Vector3) -> void:
	var label := Label3D.new()
	var grip := "default (%s / %s)" % [HeldSpear.GRIP_OFFSET, HeldSpear.GRIP_ROTATION]
	if _offset != Vector3.INF:
		grip = "%s / %s" % [_offset, _rotation]
	label.text = "%s   (%.2fs)   %.2f-%.2f   grip %s" % [clip, length, from, to, grip]
	label.font_size = 72
	label.pixel_size = 0.0013
	label.position = Vector3(0, 2.25, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
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

	# Orthographic for the same reason `preview_anim.gd` is: under perspective
	# the end Gubs of a 5 m row are seen from a different side than the middle
	# one, so the same grip looks like a different grip in every sample.
	var view := get_viewport().get_visible_rect().size
	var aspect: float = view.x / maxf(view.y, 1.0)
	var wide := (spacing * float(samples - 1) + FRAME_MARGIN) / aspect
	var target := Vector3(0.0, (FRAME_LOW + FRAME_HIGH) * 0.5, 0.0)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(FRAME_MIN, wide)
	cam.near = 0.05
	cam.far = 100.0
	add_child(cam)
	cam.look_at_from_position(target + eye * 20.0, target, Vector3.UP)
	cam.make_current()
