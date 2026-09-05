extends CanvasLayer
## Scene changes with a fade, plus the mouse-capture policy. Autoloaded as `SceneFlow`.
##
## Every screen transition goes through here so that (a) there is always a fade
## rather than a hitch, and (b) exactly one place decides whether the cursor is
## captured. Mouse capture bugs are otherwise the classic "I opened the pause
## menu and can't click anything" class of problem.

const MENU := "res://scenes/ui/main_menu.tscn"
const LOBBY := "res://scenes/ui/lobby.tscn"
const ARENA := "res://scenes/world/arena.tscn"

const FADE_OUT := 0.22
const FADE_IN := 0.30

signal scene_ready(path: String)

var current_scene_path: String = ""

var _fade: ColorRect
var _busy: bool = false
## Reasons the cursor is currently free. Capture resumes when the set empties.
var _cursor_holds: Dictionary = {}


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS

	_fade = ColorRect.new()
	_fade.color = Color(0.016, 0.02, 0.031, 1.0)
	_fade.anchor_right = 1.0
	_fade.anchor_bottom = 1.0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.modulate.a = 0.0
	_fade.visible = false
	add_child(_fade)


func go_to(path: String) -> void:
	if _busy:
		return
	_busy = true
	await _fade_to(1.0, FADE_OUT)

	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("SceneFlow: could not load %s (error %d)" % [path, err])
		await _fade_to(0.0, FADE_IN)
		_busy = false
		return

	current_scene_path = path

	# A hold belongs to the scene that took it, and that scene is being freed
	# right now. Dropping the holds here is what makes the set mean "UI that is
	# on screen" rather than "UI that ever asked for the cursor". Without it the
	# menu's hold and the lobby's hold both survive into the match — neither
	# screen has anywhere to give them back — the set is never empty, and the
	# game runs with a free cursor and no mouse-look at all.
	#
	# Cleared silently: the new scene states what it needs in its own `_ready`,
	# which runs after this, and applying a capture mid-fade would warp the
	# pointer for one frame on the way into every menu.
	_cursor_holds.clear()

	# One frame for the new tree to be built before it becomes visible.
	await get_tree().process_frame
	# ...and now the new scene has spoken, so the mode can follow the holds.
	_apply_cursor()
	await _fade_to(0.0, FADE_IN)
	_busy = false
	scene_ready.emit(path)


func go_to_menu() -> void:
	await go_to(MENU)


func go_to_lobby() -> void:
	await go_to(LOBBY)


func go_to_arena() -> void:
	await go_to(ARENA)


func _fade_to(alpha: float, duration: float) -> void:
	_fade.visible = true
	var tween := create_tween()
	tween.tween_property(_fade, "modulate:a", alpha, duration)
	await tween.finished
	_fade.visible = alpha > 0.001


# ----------------------------------------------------------- mouse capture ---

## Ask for the cursor to be visible. `reason` identifies the requester so two
## overlapping requests (say, pause menu on top of the scoreboard) do not have
## the first one to close hand capture back to the game.
func release_cursor(reason: String) -> void:
	_cursor_holds[reason] = true
	_apply_cursor()


func recapture_cursor(reason: String) -> void:
	_cursor_holds.erase(reason)
	_apply_cursor()


func clear_cursor_holds() -> void:
	_cursor_holds.clear()
	_apply_cursor()


func cursor_is_free() -> bool:
	return not _cursor_holds.is_empty()


func _apply_cursor() -> void:
	if DisplayServer.get_name() == "headless":
		return
	Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE if _cursor_holds.is_empty() == false
		else Input.MOUSE_MODE_CAPTURED)
