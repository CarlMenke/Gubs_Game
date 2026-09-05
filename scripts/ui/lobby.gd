extends Node3D
## The room everyone waits in (PLAN 1.4): who is here, what the match will be,
## and the code that gets your friends in.
##
## Like the menu, the root is a `Node3D` — the roster is not only a list of
## names, it is a ring of real Gubs standing round the fire behind the panels,
## wearing the same nameplates you will be reading across the island in a
## minute (PLAN 1.5). The list and the ring are driven from the same
## `Net.players` dictionary, so they cannot disagree.
##
## Nothing here is authoritative. Every mutation is a request to `Net`, which is
## host-authoritative and rebroadcasts the whole roster; this screen only ever
## renders what came back. That is why `_refresh` is safe to call from every
## signal that could possibly have changed anything.

## Rows for players who have not arrived yet. Showing the empty seats is how a
## host knows at a glance whether they still have room, without doing arithmetic
## against a number in the settings panel.
const SHOW_EMPTY_SLOTS := true

@onready var _backdrop: GubBackdrop = %Backdrop
@onready var _player_list: VBoxContainer = %PlayerList
@onready var _player_count: Label = %PlayerCount
@onready var _code_label: Label = %CodeLabel
@onready var _code_caption: Label = %CodeCaption
@onready var _copy_button: Button = %CopyButton
@onready var _chat: ChatPanel = %Chat
@onready var _team_picker: HBoxContainer = %TeamPicker
@onready var _team_row: Control = %TeamRow
@onready var _ready_button: Button = %ReadyButton
@onready var _start_button: Button = %StartButton
@onready var _gate_hint: Label = %GateHint
@onready var _leave_button: Button = %LeaveButton

## The roster as it was on the previous refresh, so joins and leaves can be
## announced in chat. `Net` broadcasts the whole roster rather than a diff, so
## the diff has to be taken here or not at all.
var _known_peers: Array = []
var _copy_reset: SceneTreeTimer = null


func _ready() -> void:
	SceneFlow.release_cursor("lobby")

	# Reaching the lobby without a session means something tore the session down
	# between the menu handing off and this scene loading. There is nothing to
	# show, so go back rather than render an empty room.
	if not Net.in_session:
		UIState.post_notice("Lobby closed", "The session ended before the lobby opened.")
		SceneFlow.go_to_menu()
		return

	_leave_button.pressed.connect(_on_leave)
	_copy_button.pressed.connect(_on_copy)
	_ready_button.toggled.connect(_on_ready_toggled)
	_start_button.pressed.connect(_on_start)
	_chat.submitted.connect(Net.send_chat)

	Net.roster_changed.connect(_refresh)
	Net.config_changed.connect(_refresh)
	Net.chat_received.connect(_on_chat)
	Net.left_lobby.connect(_on_left_lobby)
	Net.join_failed.connect(_on_join_failed)
	Net.match_start_requested.connect(_on_match_start)

	_known_peers = Net.peer_ids()
	_chat.add_system("Welcome to the hollow. Say hello.")
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		_on_leave()


# ------------------------------------------------------------------ refresh ---

## One function for the whole screen. Every signal that could have changed
## anything calls this, because the alternative — a targeted updater per signal —
## is a dozen partial refreshes and one of them is always missing a case.
func _refresh() -> void:
	_announce_roster_changes()
	_rebuild_player_list()
	_rebuild_team_picker()
	_refresh_invite()
	_refresh_actions()
	_backdrop.set_roster(_backdrop_entries())


func _backdrop_entries() -> Array:
	var entries: Array = []
	var teams := Net.config.mode == MatchConfig.Mode.TEAMS
	for peer_id: int in Net.peer_ids():
		entries.append({
			"name": Net.player_name(peer_id),
			"team": Net.player_team(peer_id) if teams else MatchConfig.TEAM_NONE,
		})
	return entries


func _announce_roster_changes() -> void:
	var now := Net.peer_ids()
	for peer_id: int in now:
		if not _known_peers.has(peer_id):
			_chat.add_system("%s joined." % Net.player_name(peer_id))
	for peer_id: int in _known_peers:
		if not now.has(peer_id):
			# The name is gone from the roster by now, so this can only ever say
			# that somebody left. Better than a stale name that might be wrong.
			_chat.add_system("A Gub left the lobby.")
	_known_peers = now


func _rebuild_player_list() -> void:
	for child in _player_list.get_children():
		child.queue_free()

	var teams := Net.config.mode == MatchConfig.Mode.TEAMS
	for peer_id: int in Net.peer_ids():
		_player_list.add_child(_player_row(peer_id, teams))
	if SHOW_EMPTY_SLOTS:
		for i in maxi(0, Net.config.max_players - Net.player_count()):
			_player_list.add_child(_empty_row())

	_player_count.text = "%d / %d" % [Net.player_count(), Net.config.max_players]


func _player_row(peer_id: int, teams: bool) -> Control:
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	row.add_child(box)

	# A bar rather than a dot: it reads as a team stripe down the row at a
	# glance, and in free-for-all it quietly becomes the "this is you" marker.
	var stripe := ColorRect.new()
	stripe.custom_minimum_size = Vector2(4, 20)
	stripe.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if teams:
		stripe.color = UIPalette.team_colour(Net.player_team(peer_id))
	else:
		stripe.color = UIPalette.GUB if peer_id == Net.local_id() else UIPalette.LINE_STRONG
	box.add_child(stripe)

	var name_label := Label.new()
	name_label.text = Net.player_name(peer_id)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if peer_id == Net.local_id():
		name_label.add_theme_color_override("font_color", UIPalette.GUB)
	box.add_child(name_label)

	if peer_id == 1:
		var host_tag := Label.new()
		host_tag.theme_type_variation = "TinyLabel"
		host_tag.text = "HOST"
		host_tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		box.add_child(host_tag)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	var status := Label.new()
	status.theme_type_variation = "SmallLabel"
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# The host is never "not ready" — `Net.can_start_match` does not ask, since
	# the host is the one pressing Start.
	if peer_id == 1:
		status.text = ""
	elif Net.is_ready(peer_id):
		status.text = "READY"
		status.add_theme_color_override("font_color", UIPalette.GOOD)
	else:
		status.text = "WAITING"
	box.add_child(status)
	return row


func _empty_row() -> Control:
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	row.modulate = Color(1, 1, 1, 0.35)
	var label := Label.new()
	label.theme_type_variation = "SmallLabel"
	label.text = "Empty"
	row.add_child(label)
	return row


## One button per team, tinted with the colour that team's nameplates will use.
## Rebuilt rather than hidden when the team count changes, because the host can
## move it from two to eight while people are looking at it.
func _rebuild_team_picker() -> void:
	for child in _team_picker.get_children():
		child.queue_free()
	var teams := Net.config.mode == MatchConfig.Mode.TEAMS
	_team_row.visible = teams
	if not teams:
		return

	var mine := Net.player_team(Net.local_id())
	for team in Net.config.team_count:
		var button := Button.new()
		button.text = "Team %d" % (team + 1)
		button.custom_minimum_size.x = 104
		button.toggle_mode = true
		button.button_pressed = team == mine
		button.add_theme_color_override("font_color", UIPalette.team_colour(team))
		button.add_theme_color_override("font_hover_color", UIPalette.team_colour(team))
		button.add_theme_color_override("font_pressed_color", UIPalette.team_colour(team))
		button.pressed.connect(func() -> void: Net.set_team(team))
		_team_picker.add_child(button)


func _refresh_invite() -> void:
	if Net.is_offline:
		# There is no socket, so there is no endpoint to encode. Saying so beats
		# printing a code that dials this machine's own LAN address and fails.
		_code_caption.text = "OFFLINE SESSION"
		_code_label.text = "no code"
		_copy_button.disabled = true
		return
	if not Net.is_host:
		# The code encodes the *host's* address; a client generating one from
		# its own IP would hand out a code that points at itself.
		_code_caption.text = "CONNECTED TO"
		_code_label.text = String(Settings.get_value("last_invite_code")).to_upper()
		_copy_button.disabled = false
		return
	_code_caption.text = "INVITE CODE"
	_code_label.text = Net.lan_invite_code()
	_copy_button.disabled = false


func _refresh_actions() -> void:
	var host := Net.is_host
	_start_button.visible = host
	_ready_button.visible = not host

	if not host:
		var am_ready := Net.is_ready(Net.local_id())
		_ready_button.set_pressed_no_signal(am_ready)
		_ready_button.text = "READY" if am_ready else "READY UP"
		# The primary fill is the thing to press next, so it moves off the
		# button once it has been pressed.
		_ready_button.theme_type_variation = &"Button" if am_ready else &"PrimaryButton"
		_gate_hint.text = "Waiting for the host to start." if am_ready \
			else "Ready up when you are set."
		return

	var can_start := Net.can_start_match()
	_start_button.disabled = not can_start
	_gate_hint.text = "" if can_start else _why_not_startable()


## Say what is blocking the start, in the order the host can fix it. A disabled
## button with no explanation is the single most common lobby complaint there
## is.
func _why_not_startable() -> String:
	if Net.player_count() < MatchConfig.MIN_PLAYERS:
		return "Nobody is here yet."
	for peer_id: int in Net.peer_ids():
		if peer_id != 1 and not Net.is_ready(peer_id):
			return "Waiting on %s." % Net.player_name(peer_id)
	if Net.config.mode == MatchConfig.Mode.TEAMS:
		var occupied := {}
		for peer_id: int in Net.peer_ids():
			occupied[Net.player_team(peer_id)] = true
		if occupied.size() < 2:
			return "Everyone is on the same team."
	return ""


# ------------------------------------------------------------------ actions ---

func _on_copy() -> void:
	DisplayServer.clipboard_set(_code_label.text)
	_copy_button.text = "Copied"
	# A copy button that never acknowledges the copy gets pressed four times.
	if _copy_reset != null and _copy_reset.timeout.is_connected(_reset_copy_label):
		_copy_reset.timeout.disconnect(_reset_copy_label)
	_copy_reset = get_tree().create_timer(1.6)
	_copy_reset.timeout.connect(_reset_copy_label)


func _reset_copy_label() -> void:
	_copy_reset = null
	if is_instance_valid(_copy_button):
		_copy_button.text = "Copy"


func _on_ready_toggled(pressed: bool) -> void:
	Net.set_ready(pressed)


func _on_start() -> void:
	# The arena is built by another part of the project and may not exist yet.
	# Checking beats letting `SceneFlow` fail into a black screen with an error
	# only the console will ever see.
	if not ResourceLoader.exists(SceneFlow.ARENA):
		_gate_hint.text = "The island is not built yet (%s is missing)." % SceneFlow.ARENA
		return
	Net.request_match_start()


func _on_match_start() -> void:
	if not ResourceLoader.exists(SceneFlow.ARENA):
		UIState.post_notice("No island",
			"The host started a match, but this build has no arena scene yet.")
		SceneFlow.go_to_menu()
		return
	SceneFlow.go_to_arena()


func _on_leave() -> void:
	# Announce nothing: the player chose this, so the menu has no news for them.
	Net.leave_lobby(Net.Leave.LOCAL_REQUEST, "", false)
	SceneFlow.go_to_menu()


func _on_chat(peer_id: int, text: String) -> void:
	_chat.add_message(peer_id, text)


func _on_left_lobby(reason: Net.Leave, message: String) -> void:
	var described := UIState.describe_leave(reason, message)
	UIState.post_notice(String(described["title"]), String(described["body"]))
	SceneFlow.go_to_menu()


func _on_join_failed(message: String) -> void:
	UIState.post_notice("Disconnected", message)
	SceneFlow.go_to_menu()
