extends Node
## Does the mouse actually get captured when a match starts? (PLAN 1.7, 6.4)
##
##     Godot --path . --resolution 640x360 res://tools/cursor_flow.tscn
##
## This exists because of a bug that no other check could have found. The menu
## and the lobby each take a named cursor hold in `_ready` and neither has
## anywhere to give it back; `SceneFlow` only released capture when the set of
## holds emptied, so the holds accumulated across the scene changes and the
## match ran with a free cursor and no mouse-look at all. The game was
## unplayable in exactly the way that no still frame shows.
##
## Every other testbed missed it because every other testbed *is* the main
## scene: `combat_range` and `hud_range` stand the arena up directly, so no menu
## ever ran, no hold was ever taken, and capture worked. The bug only exists on
## the path a player takes.
##
## So this drives the real `SceneFlow`, through the real scenes, and asks
## `Input.mouse_mode` what actually happened. It needs a real window — the
## headless driver has no cursor and `_apply_cursor` returns early there.
##
## The runner is parented to the tree root rather than left in this scene,
## because `change_scene_to_file` frees the current scene: a test that lived in
## it would be deleted by the first transition it performed.

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	# The runner carries this same script, so without this guard it would spawn
	# a runner of its own — and two of them racing through `SceneFlow` would
	# both bounce off its `_busy` guard and assert against the wrong scene.
	if has_meta("is_runner"):
		return

	var runner := Node.new()
	runner.name = "CursorFlowRunner"
	runner.set_script(get_script())
	runner.set_meta("is_runner", true)
	get_tree().root.add_child.call_deferred(runner)


func _enter_tree() -> void:
	if has_meta("is_runner"):
		_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("cursor_flow: SKIP (headless has no cursor)")
		get_tree().quit()
		return

	# The menu is a mouse screen: it takes a hold, and the cursor must be free.
	await SceneFlow.go_to(SceneFlow.MENU)
	_expect("menu frees the cursor", SceneFlow.cursor_is_free())
	_expect("menu cursor is visible",
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)

	# Stand in for the lobby, which cannot be reached without a live session but
	# takes a second hold exactly this way. Two holds is what the original bug
	# needed: one alone might have been released by a matching call somewhere.
	SceneFlow.release_cursor("lobby")
	_expect("a second hold stacks", SceneFlow.cursor_is_free())

	# ...and now the match. This is the assertion the bug failed.
	await SceneFlow.go_to(SceneFlow.ARENA)
	_expect("the match takes the cursor back", not SceneFlow.cursor_is_free())
	_expect("the match captures the mouse",
		Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

	# The pause menu hands it back, and takes it away again on close. This is
	# the same machinery from the other side, and it is what the named holds are
	# for: closing the pause menu must not hand capture to a menu screen.
	var pause := get_tree().current_scene.find_child("PauseMenu", true, false)
	if pause == null:
		_expect("the arena has a pause menu", false)
	else:
		pause.call("open")
		_expect("pause frees the cursor", SceneFlow.cursor_is_free())
		pause.call("close")
		_expect("closing pause recaptures", not SceneFlow.cursor_is_free())

	# Leave the machine as it was found, whatever happened above.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	print("cursor_flow: %d checks, %d failures" % [_checks, _failures])
	if _failures > 0:
		print("cursor_flow: FAIL")
		get_tree().quit(1)
		return
	print("cursor_flow: PASS")
	get_tree().quit()


func _expect(what: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  ok    %s" % what)
		return
	_failures += 1
	print("  FAIL  %s" % what)
	print("        holds=%s mouse_mode=%d"
		% [str(SceneFlow._cursor_holds.keys()), Input.mouse_mode])
