class_name ChatPanel
extends PanelContainer
## Lobby and in-match chat (PLAN 6.7). One scene, used in both places, because
## the only thing that differs between them is whether the input box is always
## there or only while you are typing.
##
## The log is a single `RichTextLabel` rather than a list of `Label` nodes. It
## gets wrapping, scrollback, per-name colour and "stay pinned to the bottom
## unless the reader has scrolled up" for free, and a chat log is exactly the
## widget that was built for.
##
## Names are tinted with the same team colours the nameplates use, so the person
## who just said something and the Gub across the clearing are visibly the same
## player.

signal submitted(text: String)

## Long chats are trimmed rather than allowed to grow without bound: this runs
## for a whole session, and nobody scrolls back four hundred lines.
const MAX_LINES := 120

## In-match, chat is a quiet overlay that only takes the keyboard while you are
## actually typing. In the lobby it is a panel with a permanent input box.
@export var compact: bool = false

@onready var _log: RichTextLabel = %Log
@onready var _input: LineEdit = %Input
@onready var _heading: Control = %Heading
@onready var _hint: Label = %Hint

var _lines: int = 0


func _ready() -> void:
	_input.text_submitted.connect(_on_submitted)
	_log.bbcode_enabled = true
	_log.scroll_following = true
	if compact:
		_heading.visible = false
		theme_type_variation = &"HudPanel"
		set_input_visible(false)
	_hint.text = "%s to chat" % SettingsPanel.primary_key("chat")
	_update_compact_skin()


# ------------------------------------------------------------------ writing ---

## A line from a player. `peer_id` is looked up rather than passed as a name so
## a rename between sending and receiving cannot produce two names for one Gub.
func add_message(peer_id: int, text: String) -> void:
	var team := Net.player_team(peer_id)
	var colour := UIPalette.team_colour(team) if Net.config.mode == MatchConfig.Mode.TEAMS \
		else (UIPalette.GUB if peer_id == Net.local_id() else UIPalette.TEXT)
	_append("[color=#%s]%s[/color]  %s" % [
		colour.to_html(false), _escape(Net.player_name(peer_id)), _escape(text)])


## Something the game itself is saying: a join, a leave, a match starting.
func add_system(text: String) -> void:
	_append("[color=#%s]%s[/color]" % [UIPalette.TEXT_FAINT.to_html(false), _escape(text)])


func _append(bbcode: String) -> void:
	if _lines > 0:
		_log.append_text("\n")
	_log.append_text(bbcode)
	_lines += 1
	_update_compact_skin()
	if _lines > MAX_LINES:
		# `RichTextLabel` can only drop whole lines from the front, which is
		# exactly the granularity wanted here.
		_log.remove_paragraph(0)
		_lines -= 1


## Player text is escaped before it reaches a BBCode-enabled label. Without
## this, anyone in the lobby can type `[img]` or a colour tag and rewrite the
## chat log for everybody.
static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


# ------------------------------------------------------------------- typing ---

func _on_submitted(text: String) -> void:
	var clean := text.strip_edges()
	_input.clear()
	if clean.is_empty():
		if compact:
			set_input_visible(false)
		return
	submitted.emit(clean)
	if compact:
		set_input_visible(false)


## In-match, the input box appears when the player presses the chat key and
## goes away again on send or on escape. It has to actually take focus, or the
## first few characters go to the game and the Gub jumps.
func set_input_visible(shown: bool) -> void:
	_input.visible = shown
	_hint.visible = compact and not shown
	_update_compact_skin()
	if shown:
		_input.grab_focus()
	else:
		_input.release_focus()


func is_typing() -> bool:
	return _input.visible and _input.has_focus()


## In-match, an empty chat box is a black rectangle in the corner of a game
## nobody has spoken in yet. The panel earns its background only once it has
## something in it, or once someone starts typing.
func _update_compact_skin() -> void:
	if not compact:
		return
	var earned := _lines > 0 or _input.visible
	if earned:
		remove_theme_stylebox_override("panel")
	else:
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())


func _gui_input(event: InputEvent) -> void:
	if compact and _input.visible and event.is_action_pressed("pause"):
		accept_event()
		_input.clear()
		set_input_visible(false)
