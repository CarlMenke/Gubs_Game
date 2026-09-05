class_name KillFeed
extends VBoxContainer
## Who just killed whom (PLAN 3.8, 6.3).
##
## In a game where one hit kills, the feed is not trivia — it is the only way to
## know that the Gub you were about to fight is already dead, or that the person
## who keeps killing you is on a streak. So rows you are in are marked: your own
## name is always the Gub's yellow, and a row you are involved in keeps a bright
## edge while the others sink back.
##
## Rows are plain nodes with a tween on their modulate rather than a timer that
## rebuilds a list. A feed that repaints itself every frame in the middle of a
## fight is the kind of thing that shows up in a profile later.

## Long enough to catch out of the corner of your eye while running, short
## enough that it is never a wall of text.
const HOLD := 5.0
const FADE := 0.9
const MAX_ROWS := 5


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_BEGIN
	add_theme_constant_override("separation", 4)


## `cause` is a `Gub.Cause`. A victim who is their own killer fell off the
## island under their own steam, which the feed says in words rather than
## drawing an arrow from someone to themselves.
func add_kill(victim_id: int, killer_id: int, cause: int) -> void:
	var involved := victim_id == Net.local_id() or killer_id == Net.local_id()
	var row := PanelContainer.new()
	row.theme_type_variation = "HudPanel"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Shrink to the text and hang off the right edge. Full-width rows turn the
	# feed into a banner across the top of the screen.
	row.size_flags_horizontal = Control.SIZE_SHRINK_END

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 9)
	row.add_child(line)

	if killer_id == victim_id or killer_id == 0:
		# Name first, so every row in the feed starts with a Gub and the eye can
		# scan the left edge of the column for its own name.
		line.add_child(_name_label(victim_id))
		line.add_child(_verb(_self_death_text(cause)))
	else:
		line.add_child(_name_label(killer_id))
		line.add_child(_verb(_cause_glyph(cause)))
		line.add_child(_name_label(victim_id))

	add_child(row)
	move_child(row, 0)  # newest at the top, nearest the eye
	# `remove_child` first, and it is not optional. `queue_free` defers to the end
	# of the frame, so a loop that frees a child and then re-reads
	# `get_child_count()` sees the same number it saw last time and spins for
	# ever. The sixth death in any match — six kills inside the 5.9 s a row is on
	# screen, which in an eight-player game with a one-hit weapon is an ordinary
	# fight — hung the process at 100% CPU with no error and no output.
	# `remove_child` detaches immediately, so the count actually falls.
	while get_child_count() > MAX_ROWS:
		var oldest := get_child(get_child_count() - 1)
		remove_child(oldest)
		oldest.queue_free()

	# A row you are in stays at full strength for its whole life; everyone
	# else's settles back so the feed reads as background.
	row.modulate = Color(1, 1, 1, 1.0 if involved else 0.78)
	var tween := create_tween()
	tween.tween_interval(HOLD)
	tween.tween_property(row, "modulate:a", 0.0, FADE)
	tween.tween_callback(row.queue_free)


func clear() -> void:
	for child in get_children():
		child.queue_free()


func _name_label(peer_id: int) -> Label:
	var label := Label.new()
	label.text = Net.player_name(peer_id)
	label.theme_type_variation = "SmallLabel"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var colour := UIPalette.TEXT
	if peer_id == Net.local_id():
		colour = UIPalette.GUB
	elif Net.config.mode == MatchConfig.Mode.TEAMS:
		colour = UIPalette.team_colour(Net.player_team(peer_id))
	label.add_theme_color_override("font_color", colour)
	return label


func _verb(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = "SmallLabel"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", UIPalette.AMBER)
	return label


## The kit has no icon font, so the weapon is a typographic mark. An arrow reads
## as "did this to" in every language a player is likely to bring.
static func _cause_glyph(cause: int) -> String:
	match cause:
		Gub.Cause.SPEAR:
			return "⟶"
		Gub.Cause.VOID:
			return "pushed off"
		Gub.Cause.FALL:
			return "dropped"
		_:
			return "⟶"


static func _self_death_text(cause: int) -> String:
	match cause:
		Gub.Cause.VOID:
			return "fell off the island"
		Gub.Cause.FALL:
			return "misjudged a drop"
		_:
			return "died"
