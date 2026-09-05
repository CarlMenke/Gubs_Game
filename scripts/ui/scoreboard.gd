class_name Scoreboard
extends Control
## The full standings, held open on the `scoreboard` action (PLAN 6.2).
##
## Rebuilt on open and on every score change rather than kept live: it is only
## on screen while a key is held, the roster is at most eight rows, and a table
## that rebuilds is a table that cannot drift out of step with `MatchState`.
##
## The scrim is deliberately light. This is held down *during* a fight, often
## while running, and a scoreboard that blacks out the game is one you cannot
## afford to read.

const SCRIM := Color(0.008, 0.012, 0.02, 0.62)
const COLUMN_WIDTH := 92

@onready var _rows: VBoxContainer = %Rows
@onready var _summary: Label = %Summary
@onready var _clock: Label = %Clock
@onready var _lives_heading: Label = %LivesHeading
@onready var _scrim: ColorRect = %Scrim


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrim.color = SCRIM
	visible = false
	MatchState.scores_changed.connect(_on_scores_changed)


func open() -> void:
	visible = true
	rebuild()


func close() -> void:
	visible = false


func _on_scores_changed() -> void:
	if visible:
		rebuild()


func rebuild() -> void:
	for child in _rows.get_children():
		child.queue_free()

	var config := Net.config
	_summary.text = config.summary()
	_clock.text = UIPalette.clock(MatchState.time_left) if config.time_limit > 0 else "--:--"
	_lives_heading.visible = config.win_condition == MatchConfig.WinCondition.LIVES

	if config.mode == MatchConfig.Mode.TEAMS:
		_build_teams(config)
	else:
		for peer_id: int in MatchState.ranking():
			_rows.add_child(_player_row(peer_id, config))


## Teams are listed best-first as teams, and players best-first inside them, so
## the table answers "are we winning" before it answers "am I winning".
func _build_teams(config: MatchConfig) -> void:
	var teams := range(config.team_count)
	teams.sort_custom(func(a, b): return MatchState.team_score(a) > MatchState.team_score(b))
	for team: int in teams:
		_rows.add_child(_team_header(team))
		var any := false
		for peer_id: int in MatchState.ranking():
			if Net.player_team(peer_id) == team:
				_rows.add_child(_player_row(peer_id, config))
				any = true
		if not any:
			var empty := Label.new()
			empty.theme_type_variation = "TinyLabel"
			empty.text = "    nobody"
			_rows.add_child(empty)


func _team_header(team: int) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 34

	var stripe := ColorRect.new()
	stripe.custom_minimum_size = Vector2(4, 20)
	stripe.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stripe.color = UIPalette.team_colour(team)
	row.add_child(stripe)

	var name_label := Label.new()
	name_label.text = "  Team %d" % (team + 1)
	name_label.theme_type_variation = "LeadLabel"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", UIPalette.team_colour(team))
	row.add_child(name_label)

	var score := Label.new()
	score.text = str(MatchState.team_score(team))
	score.theme_type_variation = "LeadLabel"
	score.custom_minimum_size.x = COLUMN_WIDTH
	score.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score.add_theme_color_override("font_color", UIPalette.team_colour(team))
	row.add_child(score)
	return row


func _player_row(peer_id: int, config: MatchConfig) -> Control:
	var mine := peer_id == Net.local_id()
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	# Eliminated and dead players stay on the board — you need to know they are
	# out — but they stop competing for attention with the living.
	var dead := not MatchState.is_alive(peer_id)
	row.modulate = Color(1, 1, 1, 0.5 if dead else 1.0)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)

	var stripe := ColorRect.new()
	stripe.custom_minimum_size = Vector2(3, 20)
	stripe.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stripe.color = UIPalette.GUB if mine else Color(0, 0, 0, 0)
	line.add_child(stripe)

	var name_label := Label.new()
	name_label.text = Net.player_name(peer_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if mine:
		name_label.add_theme_color_override("font_color", UIPalette.GUB)
	line.add_child(name_label)

	if peer_id == 1:
		var tag := Label.new()
		tag.theme_type_variation = "TinyLabel"
		tag.text = "HOST"
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_child(tag)

	line.add_child(_number(str(MatchState.kills(peer_id)), UIPalette.TEXT))
	line.add_child(_number(str(MatchState.deaths(peer_id)), UIPalette.TEXT_DIM))
	if config.win_condition == MatchConfig.WinCondition.LIVES:
		var left := MatchState.lives_left(peer_id)
		line.add_child(_number("OUT" if left <= 0 else str(left),
			UIPalette.DANGER if left <= 0 else UIPalette.GOOD))
	return row


func _number(text: String, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = COLUMN_WIDTH
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", colour)
	return label
