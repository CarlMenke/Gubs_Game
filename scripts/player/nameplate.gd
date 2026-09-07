class_name Nameplate
extends Node3D
## The floating name above a Gub's head.
##
## Every Gub looks identical — the name is the *only* way to tell who you are
## looking at, in the lobby and in the match. So it is treated as gameplay
## information, not decoration: always legible, never hidden by the crowd, and
## occluded by scenery so it cannot be used to see through a rock.
##
## The plate lives in the world, at the world's scale: it shrinks with distance
## like everything else. It used to be `fixed_size`, which pinned it to a
## constant number of screen pixels — that reads as correct in a screenshot and
## wrong in motion, because a name across the island stayed exactly as large as
## the one on the Gub beside you, so the crowd came out as a wall of identical
## floating text with the players somewhere behind it. Perspective is the cue
## that says which name belongs to which body, and it was the one thing being
## thrown away.

## The label's world size is `FONT_SIZE * PIXEL_SIZE` tall, which works out at
## about 0.21 m — a Gub is 1.55 m, so a six-letter name is roughly the width of
## its shoulders and sits like a label on the model rather than over it.
##
## The two numbers are not interchangeable even though only their product sets
## the size: `FONT_SIZE` is the resolution the glyphs are rasterised at, so it
## is deliberately large and `PIXEL_SIZE` small. Halving `FONT_SIZE` and
## doubling `PIXEL_SIZE` would give a plate of exactly the same size made of
## half as many pixels, and it would go to mush the moment anyone plays above
## 1080p.
const FONT_SIZE := 64
const PIXEL_SIZE := 0.0033
## Thick enough to survive being shrunk. The outline is what keeps a name off a
## sunlit patch of grass, and at range it is most of what is left of the plate.
const OUTLINE_SIZE := 14

## Beyond this the plate fades out.
##
## These came down with the plate. At a fixed screen size the old 34-46 m was
## honest — the text was as big out there as it was in your face, so it was
## still worth drawing. In perspective a name at 34 m is four or five pixels
## tall and is no longer a name, it is a smear that says "somebody is over
## there", which is information the Gub's own silhouette already gives you for
## free. Fading it out at the distance it stops being readable is the same
## decision the old numbers made, applied to a plate that now has a size.
const FADE_START := 20.0
const FADE_END := 28.0

const TEAM_COLOURS: Array[Color] = [
	Color(0.42, 0.72, 1.00),   # blue
	Color(1.00, 0.48, 0.42),   # red
	Color(0.56, 0.90, 0.52),   # green
	Color(0.96, 0.78, 0.36),   # amber
	Color(0.80, 0.58, 0.98),   # violet
	Color(0.44, 0.92, 0.88),   # teal
	Color(0.98, 0.62, 0.83),   # pink
	Color(0.78, 0.78, 0.82),   # grey
]

const NEUTRAL_COLOUR := Color(0.94, 0.95, 0.97)

var _label: Label3D
var _camera: Camera3D
var _text: String = "Gub"
var _colour: Color = NEUTRAL_COLOUR


func _ready() -> void:
	_label = Label3D.new()
	# Turned to face the camera, but not scaled to it: the plate keeps its world
	# size and shrinks and grows with the Gub it belongs to.
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = false
	_label.font_size = FONT_SIZE
	_label.outline_size = OUTLINE_SIZE
	_label.outline_modulate = Color(0.02, 0.03, 0.04, 0.85)
	_label.pixel_size = PIXEL_SIZE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Occluded by the world like anything else: a nameplate visible through a
	# boulder is a wallhack you handed out for free.
	_label.no_depth_test = false
	_label.shaded = false
	_label.double_sided = true
	_label.render_priority = 1
	add_child(_label)
	_refresh()


func _process(_delta: float) -> void:
	if _label == null:
		return
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return
	var distance := global_position.distance_to(_camera.global_position)
	var alpha := 1.0 - clampf(inverse_lerp(FADE_START, FADE_END, distance), 0.0, 1.0)
	_label.modulate = Color(_colour, alpha)
	_label.outline_modulate = Color(0.02, 0.03, 0.04, 0.85 * alpha)
	_label.visible = alpha > 0.01


func set_display_name(value: String) -> void:
	_text = value
	_refresh()


## `team` of `MatchConfig.TEAM_NONE` uses the neutral colour, which is what
## free-for-all wants: everyone is a threat, so nobody is colour-coded.
func set_team(team: int) -> void:
	_colour = NEUTRAL_COLOUR if team < 0 else TEAM_COLOURS[team % TEAM_COLOURS.size()]
	_refresh()


static func colour_for_team(team: int) -> Color:
	return NEUTRAL_COLOUR if team < 0 else TEAM_COLOURS[team % TEAM_COLOURS.size()]


func _refresh() -> void:
	if _label == null:
		return
	_label.text = _text
	_label.modulate = _colour
