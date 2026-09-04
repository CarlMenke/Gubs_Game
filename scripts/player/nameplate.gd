class_name Nameplate
extends Node3D
## The floating name above a Gub's head.
##
## Every Gub looks identical — the name is the *only* way to tell who you are
## looking at, in the lobby and in the match. So it is treated as gameplay
## information, not decoration: always legible, never hidden by the crowd, and
## occluded by scenery so it cannot be used to see through a rock.

## Screen-space height is fixed, so a name is as readable across the island as
## it is up close.
const FONT_SIZE := 44
const OUTLINE_SIZE := 18

## Beyond this the plate fades out; the island is about 70 m across, so a name
## stays readable anywhere you could realistically shoot someone.
const FADE_START := 34.0
const FADE_END := 46.0

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
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Keep the plate upright when the camera tilts; a name that rolls with the
	# view is much harder to read than one that stays level.
	_label.fixed_size = true
	_label.font_size = FONT_SIZE
	_label.outline_size = OUTLINE_SIZE
	_label.outline_modulate = Color(0.02, 0.03, 0.04, 0.85)
	# With fixed_size on, this is what sets the on-screen height. Tuned by
	# eye at 1280x720 so a name is comfortably readable but not shouting.
	_label.pixel_size = 0.0011
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
