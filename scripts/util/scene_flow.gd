extends CanvasLayer
## Scene changes with a fade, plus the mouse-capture policy. Autoloaded as `SceneFlow`.
##
## Every screen transition goes through here so that (a) there is always a fade
## rather than a hitch, (b) exactly one place decides whether the cursor is
## captured, and (c) a slow scene says so instead of looking hung. Mouse capture
## bugs are otherwise the classic "I opened the pause menu and can't click
## anything" class of problem.
##
## The loading card exists because the arena is *generated* (D-007) and that
## costs two to six seconds inside `arena.gd`'s `_ready`. `change_scene_to_file`
## does not return until that finishes, so the frame showing the card has to be
## drawn *before* the call rather than after it — there is no main thread left to
## animate anything once the island starts building. That is why this waits two
## frames on the card before changing scene: one to lay the labels out, one to
## put them on the glass. Without it the player watches a black screen for six
## seconds and reasonably concludes the game has crashed.

const MENU := "res://scenes/ui/main_menu.tscn"
const LOBBY := "res://scenes/ui/lobby.tscn"
const ARENA := "res://scenes/world/arena.tscn"

const FADE_OUT := 0.22
const FADE_IN := 0.30

signal scene_ready(path: String)

var current_scene_path: String = ""

var _fade: ColorRect
var _loading: Control
var _loading_title: Label
var _loading_hint: Label
var _busy: bool = false
## A `go_to` that arrived mid-transition, to be run when this one finishes.
## Latest wins; see the note in `go_to`.
var _pending: Array = []
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

	_build_loading_card()


## `loading_title` is shown over the black while the next scene builds itself.
## Leave it empty for anything that loads instantly — a card that flashes up for
## one frame is worse than no card.
func go_to(path: String, loading_title: String = "", loading_hint: String = "") -> void:
	# A transition is not over when the next scene enters the tree — the fade back
	# in still has to run, and `_busy` stays true for those 0.3 s. Dropping a
	# request that lands in that window is what it used to do, and it lost real
	# ones: the host pressing Start the instant the lobby appeared set
	# `Net.match_running` and broadcast `_begin_match` to everybody, and then the
	# `go_to_arena` that should have followed returned having done nothing. The
	# lobby simply sat there, in a session that believed a match had started.
	# Pressing Start again worked, which is the worst possible symptom: it looks
	# like a missed click rather than a bug.
	if _busy:
		_pending = [path, loading_title, loading_hint]
		return
	_busy = true
	await _fade_to(1.0, FADE_OUT)

	if not loading_title.is_empty():
		_show_loading(loading_title, loading_hint)
		# Two frames, deliberately: the first lays the labels out, the second
		# actually draws them. `change_scene_to_file` blocks for as long as the
		# new scene's `_ready` takes, so whatever is on the glass when it is
		# called is what the player looks at for the whole build.
		await get_tree().process_frame
		await get_tree().process_frame

	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("SceneFlow: could not load %s (error %d)" % [path, err])
		_hide_loading()
		await _fade_to(0.0, FADE_IN)
		_busy = false
		_drain_pending()
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
	_hide_loading()
	# ...and now the new scene has spoken, so the mode can follow the holds.
	_apply_cursor()
	await _fade_to(0.0, FADE_IN)
	_busy = false
	scene_ready.emit(path)
	_drain_pending()


func go_to_menu() -> void:
	await go_to(MENU)


func go_to_lobby() -> void:
	await go_to(LOBBY)


func go_to_arena() -> void:
	await go_to(ARENA, "WHISPERBLOOM HOLLOW", "Growing the island from seed %d" % Net.config.map_seed)


## Run whichever request arrived while we were busy. Only the most recent is
## kept: if two screens both asked to be next, the second one is the one the
## player actually chose, and replaying a queue of stale destinations would walk
## them through screens they have already left.
func _drain_pending() -> void:
	if _pending.is_empty():
		return
	var next: Array = _pending
	_pending = []
	await go_to(next[0], next[1], next[2])


## A title and one line of explanation, centred on the black. Built once and
## reused, because building it at the moment of a transition would allocate on
## exactly the frame that can least afford it.
func _build_loading_card() -> void:
	_loading = CenterContainer.new()
	_loading.anchor_right = 1.0
	_loading.anchor_bottom = 1.0
	_loading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading.visible = false
	add_child(_loading)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	_loading.add_child(stack)

	_loading_title = Label.new()
	_loading_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_title.add_theme_font_size_override("font_size", 40)
	_loading_title.add_theme_color_override("font_color", Color(0.98, 0.80, 0.36))
	stack.add_child(_loading_title)

	_loading_hint = Label.new()
	_loading_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_hint.add_theme_font_size_override("font_size", 15)
	_loading_hint.add_theme_color_override("font_color", Color(0.62, 0.67, 0.76))
	stack.add_child(_loading_hint)


func _show_loading(title: String, hint: String) -> void:
	if _loading == null:
		return
	_loading_title.text = title
	_loading_hint.text = hint
	_loading.visible = true


func _hide_loading() -> void:
	if _loading != null:
		_loading.visible = false


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
