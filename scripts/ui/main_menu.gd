extends Node3D
## The first screen anyone sees (PLAN 1.3): who you are, and the four ways out
## of here.
##
## The scene root is a `Node3D` rather than a `Control` because the menu is not
## a picture of the game, it is the game with a UI in front of it — a live
## `GubBackdrop` with a real Gub standing in a real glade, lit by the arena's
## own environment. Everything the player can touch lives on a `CanvasLayer`
## above it.
##
## Joining is deliberately a two-step reveal rather than a modal: pressing
## "Join with a code" opens a field directly beneath the button that opened it,
## so the eye never leaves the column it was already reading.

## Long enough to read, short enough that nobody wonders if it has hung. `Net`
## puts its own eight-second clock on the connection itself.
const CONNECT_HINT := "Connecting..."

@onready var _backdrop: GubBackdrop = %Backdrop
@onready var _name_edit: LineEdit = %NameEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton
@onready var _join_panel: Control = %JoinPanel
@onready var _code_edit: LineEdit = %CodeEdit
@onready var _connect_button: Button = %ConnectButton
@onready var _notice: PanelContainer = %Notice
@onready var _notice_title: Label = %NoticeTitle
@onready var _notice_body: Label = %NoticeBody
@onready var _settings: SettingsPanel = %Settings
@onready var _version: Label = %Version

## True between pressing Host/Join and the session opening or failing, so the
## buttons can be locked without a second flag for each of them.
var _pending: bool = false


func _ready() -> void:
	# The menu is a mouse screen. Named, because the pause menu and the
	# scoreboard hold the cursor too and whoever lets go last must not hand
	# capture back to a game that is not running.
	SceneFlow.release_cursor("menu")

	# Arriving here with a session still open means something went wrong on the
	# way in, or the player backed out of a lobby. Either way this screen owns
	# no session, so close it before it can surprise anyone.
	if Net.in_session:
		Net.leave_lobby(Net.Leave.LOCAL_REQUEST, "", false)

	_version.text = "v%s" % ProjectSettings.get_setting("application/config/version", "0.0.0")
	_name_edit.text = Settings.sanitized_player_name()
	_code_edit.text = String(Settings.get_value("last_invite_code"))
	_join_panel.visible = false
	_notice.visible = false
	_push_name_to_backdrop()

	_host_button.pressed.connect(_on_host)
	_join_button.pressed.connect(_on_join_toggled)
	_settings_button.pressed.connect(_settings.open)
	_quit_button.pressed.connect(_on_quit)
	_connect_button.pressed.connect(_on_connect)
	_code_edit.text_submitted.connect(func(_text: String) -> void: _on_connect())
	_name_edit.text_changed.connect(_on_name_typed)
	_name_edit.text_submitted.connect(func(_text: String) -> void: _commit_name())
	_name_edit.focus_exited.connect(_commit_name)

	Net.joined_lobby.connect(_on_joined)
	Net.join_failed.connect(_on_join_failed)
	Net.left_lobby.connect(_on_left_lobby)

	# Whatever threw us back here gets the first word.
	var pending := UIState.take_notice()
	if not String(pending["body"]).is_empty():
		_show_notice(String(pending["title"]), String(pending["body"]))

	_host_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	# Escape backs out one layer at a time rather than doing nothing on a screen
	# that has no "back".
	if event.is_action_pressed("pause") and _join_panel.visible:
		_set_join_open(false)
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ identity ---

func _on_name_typed(_text: String) -> void:
	_push_name_to_backdrop()


## Committed on submit and on losing focus rather than on every keystroke:
## `Settings.set_value` writes the file, and a disk write per character typed is
## a silly thing to do to someone's SSD.
func _commit_name() -> void:
	var clean := Net.sanitize_name(_name_edit.text)
	_name_edit.text = clean
	Net.set_name_local(clean)
	_push_name_to_backdrop()


## The Gub on screen wears the name in the box, live. It is the clearest
## possible answer to "is this field the name other people will see?"
func _push_name_to_backdrop() -> void:
	var shown := Net.sanitize_name(_name_edit.text)
	_backdrop.set_roster([{"name": shown, "team": MatchConfig.TEAM_NONE}])


# -------------------------------------------------------------------- actions ---

func _on_host() -> void:
	if _pending:
		return
	_commit_name()
	_set_busy(true)
	_show_notice("Opening lobby", "Binding port %d..." % Net.DEFAULT_PORT)
	# `host_lobby` reports its own failure through `join_failed`, which this
	# screen is already listening to, so a bound port or a second copy of the
	# game running lands in the same notice as a bad invite code.
	if not Net.host_lobby():
		_set_busy(false)


func _on_join_toggled() -> void:
	_set_join_open(not _join_panel.visible)


func _set_join_open(open: bool) -> void:
	# No open/closed marker on the button: the field appearing directly beneath
	# it is the affordance, and a bare glyph on the end of a label reads as a
	# typo.
	_join_panel.visible = open
	if open:
		_code_edit.grab_focus()
		_code_edit.select_all()


func _on_connect() -> void:
	if _pending:
		return
	var code := _code_edit.text.strip_edges()
	if code.is_empty():
		_show_notice("No code", "Paste the code the host sent you.")
		return
	if not InviteCode.is_valid(code):
		# Checked here as well as inside `Net` so the player is told before a
		# socket is opened, and told what the shape of a code actually is.
		_show_notice("That code will not work",
			"An invite code looks like XXXXX-XXXXX.\nCheck for a missing character.")
		return
	_commit_name()
	Settings.set_value("last_invite_code", code)
	_set_busy(true)
	_show_notice(CONNECT_HINT, "Reaching the host at %s." % code.to_upper())
	if not Net.join_lobby(code):
		_set_busy(false)


func _on_quit() -> void:
	get_tree().quit()


# -------------------------------------------------------------------- session ---

func _on_joined() -> void:
	SceneFlow.go_to_lobby()


func _on_join_failed(message: String) -> void:
	_set_busy(false)
	_show_notice("Could not join", message)
	_set_join_open(true)


func _on_left_lobby(reason: Net.Leave, message: String) -> void:
	_set_busy(false)
	var described := UIState.describe_leave(reason, message)
	if not String(described["body"]).is_empty():
		_show_notice(String(described["title"]), String(described["body"]))


func _set_busy(busy: bool) -> void:
	_pending = busy
	_host_button.disabled = busy
	_connect_button.disabled = busy


func _show_notice(title: String, body: String) -> void:
	_notice_title.text = title
	_notice_body.text = body
	_notice.visible = true
