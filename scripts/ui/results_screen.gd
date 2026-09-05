class_name ResultsScreen
extends Control
## What happened, at the end of a match (PLAN 1.7, 5.5, 6.1).
##
## Driven entirely from the `summary` dictionary `MatchState.match_finished`
## carries, not from `MatchState` itself. That matters: the summary is the
## host's snapshot at the moment the match ended, and reading live state instead
## would show a table that keeps changing while people are still reading it —
## or an empty one, once `MatchState.reset` runs on the way back to the lobby.
##
## It sits over the arena rather than replacing it, so the last thing that
## happened is still visible behind the numbers.

signal return_to_lobby()

const CURSOR_REASON := "results"

@onready var _headline: Label = %Headline
@onready var _subtitle: Label = %Subtitle
@onready var _rows: VBoxContainer = %Rows
@onready var _lobby_button: Button = %LobbyButton


func _ready() -> void:
	visible = false
	_lobby_button.pressed.connect(_on_lobby)


func show_summary(summary: Dictionary) -> void:
	visible = true
	SceneFlow.release_cursor(CURSOR_REASON)
	_fill_headline(summary)
	_fill_table(summary)
	_lobby_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	SceneFlow.recapture_cursor(CURSOR_REASON)


func _on_lobby() -> void:
	close()
	return_to_lobby.emit()


# ---------------------------------------------------------------- headline ---

func _fill_headline(summary: Dictionary) -> void:
	var teams: bool = int(summary.get("mode", MatchConfig.Mode.FREE_FOR_ALL)) \
		== MatchConfig.Mode.TEAMS
	var ranking: Array = summary.get("ranking", [])

	if teams:
		var scores: Dictionary = summary.get("team_scores", {})
		var best := -1
		var best_score := -99999
		var drawn := false
		for team: int in scores:
			var score := int(scores[team])
			if score > best_score:
				best_score = score
				best = team
				drawn = false
			elif score == best_score:
				drawn = true
		if drawn or best < 0:
			_headline.text = "DRAW"
			_headline.add_theme_color_override("font_color", UIPalette.TEXT)
		else:
			_headline.text = "TEAM %d WINS" % (best + 1)
			_headline.add_theme_color_override("font_color", UIPalette.team_colour(best))
	elif ranking.is_empty():
		_headline.text = "MATCH OVER"
		_headline.add_theme_color_override("font_color", UIPalette.TEXT)
	else:
		var winner: int = ranking[0]
		var mine := winner == Net.local_id()
		_headline.text = "YOU WIN" if mine else "%s WINS" % Net.player_name(winner)
		_headline.add_theme_color_override("font_color",
			UIPalette.GUB if mine else UIPalette.AMBER)

	_subtitle.text = _reason_text(String(summary.get("reason", "")))


static func _reason_text(reason: String) -> String:
	match reason:
		"limit":
			return "The kill limit was reached."
		"time":
			return "Time ran out."
		"elimination":
			return "Last Gub standing."
		_:
			return "The match ended."


# ------------------------------------------------------------------- table ---

func _fill_table(summary: Dictionary) -> void:
	for child in _rows.get_children():
		child.queue_free()

	var stats: Dictionary = summary.get("stats", {})
	var ranking: Array = summary.get("ranking", [])
	var teams: bool = int(summary.get("mode", MatchConfig.Mode.FREE_FOR_ALL)) \
		== MatchConfig.Mode.TEAMS
	for place in ranking.size():
		_rows.add_child(_row(place + 1, int(ranking[place]),
			stats.get(ranking[place], {}), teams))


func _row(place: int, peer_id: int, entry: Dictionary, teams: bool) -> Control:
	var mine := peer_id == Net.local_id()
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 14)
	row.add_child(line)

	# The podium places are called out; below that a number is enough.
	var rank := Label.new()
	rank.text = str(place)
	rank.custom_minimum_size.x = 42
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rank.theme_type_variation = "LeadLabel" if place == 1 else "DimLabel"
	if place == 1:
		rank.add_theme_color_override("font_color", UIPalette.GUB)
	line.add_child(rank)

	var name_label := Label.new()
	name_label.text = Net.player_name(peer_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if mine:
		name_label.add_theme_color_override("font_color", UIPalette.GUB)
	elif teams:
		name_label.add_theme_color_override("font_color",
			UIPalette.team_colour(Net.player_team(peer_id)))
	line.add_child(name_label)

	line.add_child(_stat("%d" % int(entry.get("kills", 0)), "KILLS", UIPalette.TEXT))
	line.add_child(_stat("%d" % int(entry.get("deaths", 0)), "DEATHS", UIPalette.TEXT_DIM))
	return row


## A number over its own caption, so the table needs no separate header row and
## stays readable however few columns a mode happens to use.
func _stat(value: String, caption: String, colour: Color) -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 86
	box.add_theme_constant_override("separation", 0)

	var number := Label.new()
	number.text = value
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	number.add_theme_color_override("font_color", colour)
	box.add_child(number)

	var label := Label.new()
	label.text = caption
	label.theme_type_variation = "SectionLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(label)
	return box
