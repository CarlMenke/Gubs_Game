class_name UIState
extends RefCounted
## The small amount of UI state that has to outlive a scene change.
##
## When a session ends badly — the host closed the lobby, the connection
## dropped, the match you were joining had already started — the message
## explaining it is produced by whatever screen was running at the time, and it
## has to be read by the main menu *after* that screen has been freed. There is
## nowhere else for it to live: `Net` is deliberately transport-and-roster only,
## and `SceneFlow` owns fades and the cursor.
##
## Static rather than an autoload because it is two strings and adding an
## autoload would mean editing `project.godot`, which is shared ground.

## Set by whoever is leaving; consumed exactly once by the main menu.
static var _notice_title: String = ""
static var _notice_body: String = ""


## Leave a message for the next screen. Overwrites any unread one: if two things
## go wrong on the way out, the last one is the one that explains the state the
## player is actually in.
static func post_notice(title: String, body: String) -> void:
	_notice_title = title
	_notice_body = body


## Read and clear. Returns an empty body when there is nothing to show, so a
## caller can branch on `body.is_empty()`.
static func take_notice() -> Dictionary:
	var out := {"title": _notice_title, "body": _notice_body}
	_notice_title = ""
	_notice_body = ""
	return out


## `Net` is loaded as a script rather than reached through the autoload node so
## that these stay usable from static context.
const NET := preload("res://scripts/net/net.gd")

## Turn a `Net.Leave` reason into something a player can act on. `Net` supplies
## its own text for some reasons; that always wins, because it knows the detail
## (which port, which host) that this mapping cannot.
static func describe_leave(reason: int, message: String) -> Dictionary:
	if not message.strip_edges().is_empty():
		return {"title": "Disconnected", "body": message}
	match reason:
		NET.Leave.HOST_CLOSED:
			return {"title": "Lobby closed",
				"body": "The host left, which ends the lobby for everyone.\nStart your own, or get a new code."}
		NET.Leave.CONNECTION_LOST:
			return {"title": "Connection lost",
				"body": "The link to the host dropped.\nIf they are still hosting, the same invite code will get you back in."}
		NET.Leave.CONNECTION_FAILED:
			return {"title": "Could not connect",
				"body": "Nothing answered at that address.\nCheck the code, and that the host has the game open."}
		NET.Leave.LOBBY_FULL:
			return {"title": "Lobby full",
				"body": "That lobby already has %d Gubs in it." % MatchConfig.MAX_PLAYERS}
		NET.Leave.MATCH_IN_PROGRESS:
			return {"title": "Match already running",
				"body": "That lobby is mid-match. You can join once it ends."}
		_:
			return {"title": "", "body": ""}
