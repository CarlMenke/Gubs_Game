class_name HUD
extends CanvasLayer
## Everything drawn over a running match (PLAN 6.1-6.7).
##
## The arena is expected to instance this once, as a child of its root:
##
##     [node name="HUD" parent="." instance=ExtResource("res://scenes/ui/hud.tscn")]
##
## It reaches into no arena node and holds no reference to one. Everything it
## shows comes from `MatchState`, `Net` and the local Gub's own `GubCombat`, so
## it works over any scene that has registered an arena — including
## `tools/hud_range.tscn`, which is how every screen in it was looked at.
##
## Two things are read every frame rather than driven by signals: the cooldowns
## and the clock. Cooldowns are wall-clock deadlines inside `GubCombat` with no
## per-frame signal to hang off, and the clock is broadcast twice a second, so
## polling is both simpler and smoother than the alternative. Everything else —
## kills, scores, phases, deaths — arrives as a signal and is handled once.

## The banner is the only element that ever covers the middle of the screen, so
## it is on a short leash.
const FLASH_TIME := 1.4

@onready var _crosshair: Crosshair = %Crosshair
@onready var _clock: Label = %Clock
@onready var _score_line: RichTextLabel = %ScoreLine
@onready var _kill_feed: KillFeed = %KillFeed
@onready var _lives: HBoxContainer = %Lives
@onready var _abilities: HBoxContainer = %Abilities
@onready var _spear_slot: AbilitySlot = %SpearSlot
@onready var _mushroom_slot: AbilitySlot = %MushroomSlot
@onready var _lure_slot: AbilitySlot = %LureSlot
@onready var _banner: Control = %Banner
@onready var _banner_title: Label = %BannerTitle
@onready var _banner_sub: Label = %BannerSub
@onready var _chat: ChatPanel = %Chat
@onready var _scoreboard: Scoreboard = %Scoreboard
@onready var _pause: PauseMenu = %PauseMenu
@onready var _results: ResultsScreen = %Results

## Counts down the phase this client believes it is in. `phase_changed` does not
## carry the phase timer, so a warmup countdown has to be run locally off
## `MatchConfig.warmup_time`. Both sides start it from the same RPC, so they
## agree to within a round trip, which is well inside what a countdown needs.
var _phase_clock: float = 0.0
## Seconds until the local Gub respawns, from `local_death`.
var _respawn_clock: float = 0.0
var _flash: float = 0.0


func _ready() -> void:
	layer = 8
	# The match owns the mouse. Anything that wants it back asks by name.
	SceneFlow.recapture_cursor("hud")

	_chat.compact = true
	_chat.submitted.connect(Net.send_chat)
	_pause.resumed.connect(_on_resumed)
	_pause.left_match.connect(_on_leave_match)
	_results.return_to_lobby.connect(_on_back_to_lobby)

	MatchState.phase_changed.connect(_on_phase_changed)
	MatchState.scores_changed.connect(_refresh_score)
	MatchState.player_killed.connect(_on_player_killed)
	MatchState.match_finished.connect(_on_match_finished)
	MatchState.local_death.connect(_on_local_death)
	MatchState.local_respawn.connect(_on_local_respawn)
	Net.chat_received.connect(_chat.add_message)
	Net.left_lobby.connect(_on_left_lobby)

	_banner.visible = false
	_refresh_score()
	_on_phase_changed(MatchState.phase)


func _process(delta: float) -> void:
	_tick_clocks(delta)
	_refresh_crosshair()
	_refresh_abilities()
	_refresh_clock()


# ------------------------------------------------------------------- input ---

func _unhandled_input(event: InputEvent) -> void:
	# Typing beats every other binding: T is also a perfectly good movement key
	# on somebody's layout, and the scoreboard must not open under a message.
	if _chat.is_typing():
		return

	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		_toggle_pause()
		return
	if _pause.visible or _results.visible:
		return
	if event.is_action_pressed("scoreboard"):
		_scoreboard.open()
	elif event.is_action_released("scoreboard"):
		_scoreboard.close()
	elif event.is_action_pressed("chat"):
		get_viewport().set_input_as_handled()
		_begin_chat()


func _toggle_pause() -> void:
	if _results.visible:
		return
	if _pause.visible:
		_pause.close()
	else:
		_scoreboard.close()
		_pause.open()


func _on_resumed() -> void:
	pass  # the pause menu has already handed the cursor back


## Typing releases the cursor, which is what actually stops the Gub looking
## around and throwing spears: `GubCamera` and `GubCombat` both check
## `SceneFlow.cursor_is_free()` before acting on input.
func _begin_chat() -> void:
	_chat.set_input_visible(true)
	SceneFlow.release_cursor("chat")


func _on_chat_closed() -> void:
	SceneFlow.recapture_cursor("chat")


# ----------------------------------------------------------------- per frame ---

func _tick_clocks(delta: float) -> void:
	if _phase_clock > 0.0:
		_phase_clock = maxf(0.0, _phase_clock - delta)
		_banner_sub.text = "%d" % ceili(_phase_clock) if _phase_clock > 0.0 else "GO"
	if _respawn_clock > 0.0:
		_respawn_clock = maxf(0.0, _respawn_clock - delta)
		_banner_sub.text = "Back in %d" % ceili(_respawn_clock) if _respawn_clock > 0.0 \
			else "Any moment now"
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta)
		if _flash <= 0.0 and _respawn_clock <= 0.0 and _phase_clock <= 0.0:
			_banner.visible = false
	# Chat closes itself on send; the cursor hold has to be released with it.
	if not _chat.is_typing() and _chat.visible and SceneFlow.cursor_is_free() \
			and not _pause.visible and not _results.visible:
		SceneFlow.recapture_cursor("chat")


func _refresh_crosshair() -> void:
	var combat := _local_combat()
	var alive := combat != null and MatchState.is_alive(Net.local_id())
	if combat == null:
		_crosshair.set_state(0.0, false)
		return
	var total := maxf(0.01, Net.config.spear_recharge)
	_crosshair.set_state(clampf(combat.spear_cooldown() / total, 0.0, 1.0), alive)


func _refresh_abilities() -> void:
	var combat := _local_combat()
	var config := Net.config
	if combat == null:
		# Spectating: the bar stays on screen but plainly inert, rather than
		# vanishing and taking the layout with it.
		_abilities.modulate = Color(1, 1, 1, 0.25)
		return
	_abilities.modulate = Color(1, 1, 1, 1.0 if MatchState.is_alive(Net.local_id()) else 0.3)
	_spear_slot.set_cooldown(combat.spear_cooldown(), config.spear_recharge)
	_mushroom_slot.set_cooldown(combat.mushroom_cooldown(), config.mushroom_cooldown)
	_lure_slot.set_cooldown(combat.lure_cooldown(), config.lure_cooldown)


func _refresh_clock() -> void:
	if Net.config.time_limit <= 0:
		_clock.text = "--:--"
		return
	_clock.text = UIPalette.clock(MatchState.time_left)
	# The last thirty seconds go amber. Nothing else on the HUD changes colour
	# with time, so it cannot be confused with anything.
	_clock.add_theme_color_override("font_color",
		UIPalette.AMBER if MatchState.time_left <= 30.0 else UIPalette.TEXT)


func _local_combat() -> GubCombat:
	var gub := MatchState.local_gub()
	if gub == null:
		return null
	return gub.get_node_or_null("Combat") as GubCombat


# ------------------------------------------------------------------- score ---

func _refresh_score() -> void:
	var config := Net.config
	var me := Net.local_id()
	if config.mode == MatchConfig.Mode.TEAMS:
		var parts: Array[String] = []
		for team in config.team_count:
			parts.append("[color=#%s]%d[/color]" % [
				UIPalette.team_colour(team).to_html(false), MatchState.team_score(team)])
		_score_line.text = "[center]%s[/center]" % "  [color=#4a545f]—[/color]  ".join(parts)
	else:
		var mine := MatchState.kills(me)
		var ranking := MatchState.ranking()
		var leader: int = ranking[0] if not ranking.is_empty() else me
		var target := " / %d" % config.kill_limit \
			if config.win_condition == MatchConfig.WinCondition.KILL_LIMIT else ""
		var tail := "you lead" if leader == me and mine > 0 \
			else "%s %d" % [Net.player_name(leader), MatchState.kills(leader)]
		_score_line.text = "[center][color=#%s]%d%s[/color]  [color=#4a545f]·[/color]  %s[/center]" % [
			UIPalette.GUB.to_html(false), mine, target, tail]

	_refresh_lives()


## Lives are pips rather than a number: at three or five, a row of shapes is
## read without counting, and the moment there is one left it is unmistakable.
func _refresh_lives() -> void:
	var config := Net.config
	var show := config.win_condition == MatchConfig.WinCondition.LIVES
	_lives.visible = show
	if not show:
		return
	for child in _lives.get_children():
		child.queue_free()
	var left := MatchState.lives_left(Net.local_id())
	for i in config.lives:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(16, 5)
		pip.color = UIPalette.GUB if i < left else UIPalette.faded(UIPalette.TEXT, 0.16)
		_lives.add_child(pip)


# ----------------------------------------------------------------- signals ---

func _on_phase_changed(phase: int) -> void:
	match phase:
		MatchState.Phase.WARMUP:
			_phase_clock = maxf(0.1, Net.config.warmup_time)
			_show_banner("GET READY", "%d" % ceili(_phase_clock), UIPalette.AMBER)
		MatchState.Phase.PLAYING:
			_phase_clock = 0.0
			_flash = FLASH_TIME
			_show_banner("FIGHT", "", UIPalette.GUB)
		MatchState.Phase.POST_MATCH:
			_phase_clock = 0.0
			_flash = 0.0
			_banner.visible = false
			_scoreboard.close()
		_:
			_banner.visible = false
	_refresh_score()


func _on_player_killed(victim_id: int, killer_id: int, cause: int) -> void:
	_kill_feed.add_kill(victim_id, killer_id, cause)
	# Visual only. `MatchState` already plays the hitmarker sound and shakes the
	# camera on a kill; a second one from here would be two of each.
	if killer_id == Net.local_id() and victim_id != killer_id:
		_crosshair.strike()
	_refresh_score()


func _on_local_death(respawn_in: float) -> void:
	_scoreboard.close()
	if _is_eliminated():
		_respawn_clock = 0.0
		_show_banner("ELIMINATED", "Spectating. The match goes on without you.",
			UIPalette.DANGER)
		return
	_respawn_clock = maxf(0.1, respawn_in)
	_show_banner("YOU DIED", "Back in %d" % ceili(_respawn_clock), UIPalette.DANGER)


func _on_local_respawn() -> void:
	_respawn_clock = 0.0
	_banner.visible = false


## Out of lives, in a mode that has them. The distinction matters: a dead Gub is
## back in three seconds and an eliminated one is done, and telling someone
## "respawning in 3" when they are not is worse than saying nothing.
func _is_eliminated() -> bool:
	return Net.config.win_condition == MatchConfig.WinCondition.LIVES \
		and MatchState.lives_left(Net.local_id()) <= 0


func _on_match_finished(summary: Dictionary) -> void:
	_banner.visible = false
	_scoreboard.close()
	_pause.close()
	_results.show_summary(summary)


func _on_left_lobby(reason: Net.Leave, message: String) -> void:
	var described := UIState.describe_leave(reason, message)
	# A deliberate walk-out has nothing to explain; anything else does.
	if not String(described["body"]).is_empty():
		UIState.post_notice(String(described["title"]), String(described["body"]))
	SceneFlow.clear_cursor_holds()
	SceneFlow.go_to_menu()


func _on_leave_match() -> void:
	# Announced, so `MatchState` hears `left_lobby` and tears the match down.
	# `_on_left_lobby` above does the navigating.
	Net.leave_lobby(Net.Leave.LOCAL_REQUEST, "", true)


## Every client walks itself back to the lobby. `Net` has no "the match is over,
## everyone return" message, so the host pressing this cannot bring the others
## with it — see the note in the final report.
func _on_back_to_lobby() -> void:
	MatchState.reset()
	if Net.is_host:
		# Otherwise the lobby keeps refusing joiners with "that match has
		# already started" for the rest of the session.
		Net.match_running = false
	SceneFlow.clear_cursor_holds()
	SceneFlow.go_to_lobby()


func _show_banner(title: String, subtitle: String, colour: Color) -> void:
	_banner_title.text = title
	_banner_title.add_theme_color_override("font_color", colour)
	_banner_sub.text = subtitle
	_banner.visible = true
