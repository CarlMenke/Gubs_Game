extends Node
## Puts a UI screen into a named state so it can be photographed. Development
## tool, not shipped.
##
## Menus are the one part of the game that cannot be judged by playing for two
## seconds: a lobby with one person in it looks fine and a lobby with eight
## people, two teams and a scrolling chat is a different screen. So this opens a
## real offline session (D-011), writes a plausible roster straight into
## `Net.players` exactly the way `tools/combat_range.gd` does, and instances the
## real scene on top of it. Nothing here reaches past a public API.
##
##     Godot --path . --resolution 1600x900 --script tools/snapshot.gd -- \
##         res://tools/ui_range.tscn out.png 40 <mode>
##
## Modes: menu, menu_join, menu_notice, settings,
##        lobby, lobby_full, lobby_teams, lobby_client.

const MENU_SCENE := preload("res://scenes/ui/main_menu.tscn")
const LOBBY_SCENE := preload("res://scenes/ui/lobby.tscn")

## Peer ids for the stand-in roster, well clear of anything ENet hands out and
## of the combat range's 900s.
const FAKE_BASE := 700

## Enough flavour that the list reads as people rather than as Player 1..8, and
## long enough in a couple of cases to prove the rows do not overflow.
const FAKE_NAMES := ["Thistle", "Mossback", "Pipwick", "Bramblewick",
	"Toadflax", "Nettle", "Sorrel"]

## What each mode says in chat, so the log is never an empty box in a
## screenshot. Sender index -1 is the system.
const FAKE_CHAT: Array[Array] = [
	[0, "anyone else getting bodied by pipwick"],
	[2, "skill issue"],
	[1, "im just standing near the shrine and hoping"],
	[0, "reroll the seed, that island had one bridge"],
]

var _mode: String = "lobby"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4:
		_mode = args[3]

	match _mode:
		"menu", "menu_join", "menu_notice", "settings":
			_open_menu()
		"lobby_full":
			_open_lobby(7, false, true)
		"lobby_teams":
			_open_lobby(5, true, true)
		"lobby_client":
			_open_lobby(4, false, false)
		_:
			_open_lobby(3, false, true)


# ------------------------------------------------------------------- menus ---

func _open_menu() -> void:
	if _mode == "menu_notice":
		# The state a player lands in when a host closes the lobby out from
		# under them, which is the whole point of PLAN 1.8.
		UIState.post_notice("Lobby closed",
			"The host left, which ends the lobby for everyone.\nStart your own, or get a new code.")
	var menu := MENU_SCENE.instantiate()
	add_child(menu)
	await get_tree().process_frame
	if _mode == "menu_join":
		(menu.get_node("%JoinButton") as Button).pressed.emit()
		(menu.get_node("%CodeEdit") as LineEdit).text = "7K2QM-4XVB9"
	elif _mode == "settings":
		(menu.get_node("%Settings") as SettingsPanel).open()


# ------------------------------------------------------------------- lobby ---

## `extra` stand-ins besides the local player. `as_host` false leaves the local
## peer looking like a client, which is a visibly different screen: ready toggle
## instead of a start button, and every match setting greyed out.
func _open_lobby(extra: int, teams: bool, as_host: bool) -> void:
	Net.start_offline()
	Net.set_name_local("You")
	if teams:
		Net.config.mode = MatchConfig.Mode.TEAMS
		Net.config.team_count = 2
		Net.players[1]["team"] = 0
	for i in extra:
		Net.players[FAKE_BASE + i] = {
			"name": FAKE_NAMES[i % FAKE_NAMES.size()],
			"team": (i + 1) % 2 if teams else 0,
			# One straggler who has not readied up, so the start button has a
			# reason to be disabled and the gate hint has something to say.
			"ready": i != 1,
		}
	if not as_host:
		# Everything downstream branches on this, so flipping it is the whole
		# of "show me the client's view".
		Net.is_host = false
	Net.roster_changed.emit()

	var lobby := LOBBY_SCENE.instantiate()
	add_child(lobby)
	await get_tree().process_frame
	for line: Array in FAKE_CHAT:
		Net.chat_received.emit(FAKE_BASE + int(line[0]), String(line[1]))
