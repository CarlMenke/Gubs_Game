class_name PauseMenu
extends Control
## The Escape menu (PLAN 6.4).
##
## It does not pause anything. `get_tree().paused = true` would freeze this
## client's copy of a match that seven other people are still playing — the Gub
## would stand still, stop replicating, and be speared while its owner read a
## volume slider. So this is an overlay with a scrim, and the only thing it
## actually stops is mouse-look, by way of `SceneFlow.release_cursor`.
##
## Settings live in the same scene the main menu uses, so the two can never
## drift apart.

signal resumed()
signal left_match()

## Named holds, so closing this while the scoreboard is also up does not hand
## capture back to a game the player is still reading a table over.
const CURSOR_REASON := "pause"

@onready var _resume: Button = %ResumeButton
@onready var _settings_button: Button = %SettingsButton
@onready var _leave: Button = %LeaveButton
@onready var _settings: SettingsPanel = %Settings
@onready var _session: Label = %SessionLine


func _ready() -> void:
	visible = false
	_resume.pressed.connect(close)
	_settings_button.pressed.connect(_settings.open)
	_leave.pressed.connect(_on_leave)


func open() -> void:
	if visible:
		return
	visible = true
	_session.text = _describe_session()
	SceneFlow.release_cursor(CURSOR_REASON)
	_resume.grab_focus()


func close() -> void:
	if not visible:
		return
	# Closing the settings panel first means Escape always backs out exactly one
	# layer, wherever the player is.
	_settings.close()
	visible = false
	SceneFlow.recapture_cursor(CURSOR_REASON)
	resumed.emit()


## True while this is eating input, so the HUD knows not to act on the same
## Escape press.
func settings_open() -> bool:
	return visible and _settings.visible


func _on_leave() -> void:
	SceneFlow.recapture_cursor(CURSOR_REASON)
	visible = false
	left_match.emit()


## Enough for someone to know what they are about to walk out of, and — if they
## are hosting — that walking out ends it for everyone.
func _describe_session() -> String:
	if not Net.in_session:
		return "Not connected."
	if Net.is_offline:
		return "Offline session."
	if Net.is_host:
		return "You are hosting. Leaving closes the lobby for all %d Gubs." \
			% Net.player_count()
	return "Connected to a lobby of %d." % Net.player_count()
