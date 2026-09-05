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

## Everything drawn *during* play lives under this one node — clock, score, kill
## feed, crosshair, banner, ability bar, chat. The scoreboard, pause menu and
## results screen are its siblings, so any of them can take the screen by
## hiding it rather than by each element knowing about each overlay.
@onready var _root: Control = $Root
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
@onready var _spectate_label: Label = %SpectateLabel
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
## Index into `MatchState.living_gubs()` while spectating (PLAN 6.5). Held as an
## index rather than as a reference to the Gub because the list changes under us
## constantly — the player being watched dies, respawns, or leaves — and an index
## degrades into "somebody else" where a stale reference degrades into a crash.
var _spectate_index: int = 0
var _spectating: bool = false
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
	_results.rematch.connect(_on_rematch_pressed)

	MatchState.phase_changed.connect(_on_phase_changed)
	MatchState.scores_changed.connect(_refresh_score)
	MatchState.player_killed.connect(_on_player_killed)
	MatchState.match_finished.connect(_on_match_finished)
	MatchState.local_death.connect(_on_local_death)
	MatchState.local_respawn.connect(_on_local_respawn)
	Net.chat_received.connect(_chat.add_message)
	Net.left_lobby.connect(_on_left_lobby)
	Net.return_to_lobby_requested.connect(_go_to_lobby)
	Net.rematch_requested.connect(_on_rematch)

	_banner.visible = false
	_refresh_score()
	_on_phase_changed(MatchState.phase)


func _process(delta: float) -> void:
	_tick_clocks(delta)
	_refresh_crosshair()
	_refresh_abilities()
	_refresh_clock()
	if _spectating:
		_apply_spectator()


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
	# Dead players have no spear to throw, so the throw and aim buttons are free
	# and are the two most obvious things to press. They step the spectator
	# camera forward and back through whoever is still alive.
	if _spectating:
		if event.is_action_pressed("throw_spear"):
			get_viewport().set_input_as_handled()
			_step_spectator(1)
			return
		if event.is_action_pressed("aim"):
			get_viewport().set_input_as_handled()
			_step_spectator(-1)
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

## Put the gameplay HUD back after a results screen. Leaving the arena rebuilds
## the whole scene so this would not be needed for that alone — but a rematch
## that reuses the arena would otherwise start with everything still hidden.
func restore_gameplay_hud() -> void:
	_root.visible = true
	_results.close()
	_end_spectating()


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
	# Watch somebody who is still playing rather than the patch of dirt you died
	# on. This matters most in a lives match, where "dead" is permanent and the
	# alternative is staring at your own corpse until the match ends.
	_begin_spectating()
	if _is_eliminated():
		_respawn_clock = 0.0
		_show_banner("ELIMINATED", "The match goes on without you.", UIPalette.DANGER)
		return
	_respawn_clock = maxf(0.1, respawn_in)
	_show_banner("YOU DIED", "Back in %d" % ceili(_respawn_clock), UIPalette.DANGER)


func _on_local_respawn() -> void:
	_respawn_clock = 0.0
	_banner.visible = false
	_end_spectating()


# -------------------------------------------------------------- spectating ---

## The local Gub's own rig, which keeps the viewport even while its Gub is
## hidden. Null once the match has torn its Gubs down.
func _local_rig() -> GubCamera:
	var gub := MatchState.local_gub()
	if gub == null:
		return null
	return gub.get_node_or_null("CameraRig") as GubCamera


func _begin_spectating() -> void:
	var living := MatchState.living_gubs(Net.local_id())
	if living.is_empty():
		return
	_spectating = true
	_spectate_index = 0
	_apply_spectator()


func _end_spectating() -> void:
	_spectating = false
	var rig := _local_rig()
	if rig != null:
		rig.spectate(null)
	_spectate_label.visible = false


func _step_spectator(direction: int) -> void:
	var living := MatchState.living_gubs(Net.local_id())
	if living.is_empty():
		return
	_spectate_index = posmod(_spectate_index + direction, living.size())
	_apply_spectator()


## Point the rig at the current pick and say whose eyes we are borrowing. Called
## every frame while dead as well as on a keypress, because the target can die
## or respawn without the player touching anything.
func _apply_spectator() -> void:
	if not _spectating:
		return
	var living := MatchState.living_gubs(Net.local_id())
	var rig := _local_rig()
	if living.is_empty() or rig == null:
		_spectate_label.visible = false
		if rig != null:
			rig.spectate(null)
		return
	_spectate_index = posmod(_spectate_index, living.size())
	var target := living[_spectate_index]
	rig.spectate(target)
	_spectate_label.text = "Spectating %s      LMB / RMB to switch" % target.display_name
	_spectate_label.visible = true


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
	_end_spectating()
	# The gameplay HUD goes away entirely rather than being dimmed behind the
	# scrim. A crosshair, a live ability bar and a counting clock over a table of
	# final scores read as a match still in progress, and the ability bar sat
	# directly behind the button people are meant to press next.
	_root.visible = false
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


## The host ends the match for the whole lobby; a client only moves itself.
##
## `Net.request_return_to_lobby` broadcasts, and everyone — the host included —
## arrives back here through `_go_to_lobby`. A client pressing the same button
## just walks itself home and stays connected, so leaving a results screen never
## needs the host's cooperation.
func _on_back_to_lobby() -> void:
	if Net.is_host:
		Net.request_return_to_lobby()
	else:
		_go_to_lobby()


func _go_to_lobby() -> void:
	MatchState.reset()
	if Net.is_host:
		# Otherwise the lobby keeps refusing joiners with "that match has
		# already started" for the rest of the session.
		Net.match_running = false
	SceneFlow.clear_cursor_holds()
	SceneFlow.go_to_lobby()


## Host only; the button is not shown to anyone else.
func _on_rematch_pressed() -> void:
	Net.request_rematch()


## Same roster, same settings, same island. Reloading the arena scene is what
## re-runs `register_arena`, and on the host that is what starts a fresh warmup
## and spawns everybody again — so a rematch is a scene change, not a special
## case inside `MatchState`.
func _on_rematch() -> void:
	MatchState.reset()
	SceneFlow.clear_cursor_holds()
	SceneFlow.go_to_arena()


func _show_banner(title: String, subtitle: String, colour: Color) -> void:
	_banner_title.text = title
	_banner_title.add_theme_color_override("font_color", colour)
	_banner_sub.text = subtitle
	_banner.visible = true
