extends Node3D
## Firing range for Phase 3. Development tool, not shipped.
##
## Unlike `tools/sandbox.tscn`, which instantiates one Gub directly to feel the
## movement, this runs the **real match path**: an offline session on `Net`, a
## roster, `MatchState.register_arena`, Gubs spawned by `MatchState._create_gub`,
## and kills reported through `MatchState.report_kill`. Nothing here reaches past
## a public API into the combat code, so if a throw works in this scene it works
## in a match.
##
## The opponents are ordinary Gubs owned by peer ids that will never connect, so
## they are *remote* Gubs to this client: no input, no gravity, no camera. That
## is exactly what a target dummy should be, and it also means this scene is the
## only place the remote-Gub code path gets looked at before eight people do.
##
## Play it:
##   Godot --path . tools/combat_range.tscn
##
## Snapshot it (the mode is the trailing argument, as in the sandbox):
##   Godot --path . --resolution 1280x720 --script tools/snapshot.gd -- \
##       res://tools/combat_range.tscn out.png 90 hit

## Peer ids for the dummies. Well outside anything ENet hands out, so a stray
## real peer can never collide with one.
const DUMMY_BASE := 900

## What each mode does.
##
##   flight   — a spear caught in mid-air on its way to a dummy
##   hit      — the same throw, held until the dummy is a corpse
##   arc      — a long throw at the far wall, to see how much a spear drops
##   miss     — a throw into the dirt, to check the spear sticks and stays put
##   mushroom — one planted, to check it lands on the ground the right size
##   lure     — a lure lobbed at the middle dummy, held through the pull.
##              Note what this mode can and cannot show: the catch *decision* is
##              the host's and is reported here, but the pull itself is applied
##              on each victim's own client, and these dummies are fake roster
##              entries with no client behind them. So the dummies will be
##              listed as caught and will not visibly move. Only the local Gub
##              can actually be dragged — see `lure_self`.
##   lure_self— a lure dropped at the player's own feet, which is the only way
##              to watch the pull actually move a Gub in a one-client testbed
##   walk     — holds W for a second and requires the Gub to have gone somewhere.
##              Trivial-looking, and it is here because movement was wired up in
##              this file and in the sandbox and nowhere else, so every testbed
##              could be walked around while the actual game could not.
##   free     — no script; play it yourself
const MODES := ["flight", "hit", "arc", "miss", "mushroom", "lure", "lure_self",
	"walk", "free"]

## How far the `walk` mode requires the Gub to travel. A Gub that is not walking
## still drifts a little as it settles onto the ground on the first few frames,
## and this is comfortably clear of that.
const WALK_MIN_DISTANCE := 1.0

## Every scripted mode is watched from the touchline. The thrower's own camera
## looks *along* the throw, where the spear is a dot behind the Gub's head and a
## parabola is a straight line — the one view that cannot show whether any of
## this works. Pass `pov` as the argument after the mode to use it anyway.
##  mode -> {eye, look, fov}
const VIEWS := {
	"flight": {"eye": Vector3(17.0, 5.5, 2.0), "look": Vector3(0.0, 1.4, 2.0), "fov": 60.0},
	"hit": {"eye": Vector3(11.0, 3.4, -2.0), "look": Vector3(0.0, 1.0, -4.6), "fov": 55.0},
	"arc": {"eye": Vector3(30.0, 10.0, -12.0), "look": Vector3(0.0, 2.5, -12.0), "fov": 62.0},
	"miss": {"eye": Vector3(9.0, 3.0, -9.0), "look": Vector3(0.0, 0.6, -13.0), "fov": 50.0},
	"mushroom": {"eye": Vector3(6.0, 2.6, 9.5), "look": Vector3(0.0, 1.1, 7.2), "fov": 50.0},
	"lure": {"eye": Vector3(12.0, 8.0, -3.0), "look": Vector3(-3.0, 1.0, -12.0), "fov": 60.0},
	"lure_self": {"eye": Vector3(9.0, 3.2, 12.0), "look": Vector3(0.0, 1.0, 7.0), "fov": 55.0},
}

const PLAYER_SPOT := Vector3(0.0, 0.1, 9.0)
const DUMMY_SPOTS: Array[Vector3] = [
	Vector3(0.0, 0.1, -5.0),
	Vector3(-6.0, 0.1, -13.0),
	Vector3(5.5, 0.1, -20.0),
]
## Where the long throw is aimed in `arc` mode: the far wall, well past any
## dummy, so the whole parabola is in frame.
const ARC_TARGET := Vector3(0.0, 1.2, -34.0)

var _mode: String = "free"
var _trace: bool = false
var _pov: bool = false
var _frames: int = 0
## Where the `walk` mode started measuring from.
var _walk_from: Vector3 = Vector3.ZERO
var _acted: bool = false
var _items: Node3D
var _players: Node3D
var _aim_at: Vector3 = Vector3.ZERO
var _fixed_camera: Camera3D


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4 and MODES.has(args[3]):
		_mode = args[3]
	# A still frame cannot tell "the spear missed" from "the spear hit and the
	# kill was dropped". Add `trace` after the mode to print the flight, or
	# `pov` to watch from the thrower's own camera instead of the touchline.
	var extra: String = args[4] if args.size() >= 5 else ""
	_trace = extra == "trace"
	_pov = extra == "pov"

	_build_stage()

	_items = Node3D.new()
	_items.name = "SpawnedItems"
	# `GubCombat._spawn_root` looks for this group; without it every spear and
	# mushroom is parented to the scene root and nothing can be swept up later.
	_items.add_to_group("spawned_items")
	add_child(_items)
	# The lure reports its own catch list unconditionally: unlike a spear, there
	# is no frame in which "who did this pull?" is visible on screen.
	_items.child_entered_tree.connect(_watch_spawned)

	_players = Node3D.new()
	_players.name = "Players"
	add_child(_players)

	_start_session()
	MatchState.player_killed.connect(_on_player_killed)
	MatchState.register_arena(_players, _spawn_points())
	_place_everyone()

	if VIEWS.has(_mode) and not _pov:
		_build_touchline_camera()
	if _mode == "free":
		SceneFlow.recapture_cursor("combat_range")
		_print_controls()


# ---------------------------------------------------------------- session ---

## A one-player host session with no socket, plus however many dummies the mode
## wants written straight into the roster. Faking roster entries is the whole
## trick: `MatchState` spawns a Gub per entry and never asks whether the peer
## behind it is real.
func _start_session() -> void:
	Net.start_offline()
	for i in _dummy_count():
		Net.players[DUMMY_BASE + i] = {
			"name": "Dummy %d" % (i + 1), "team": 0, "ready": true,
		}
	Net.roster_changed.emit()

	var config := Net.config
	# No warmup: a testbed that makes you wait five seconds before it will
	# register a kill is a testbed nobody runs twice.
	config.warmup_time = 0.0
	config.spawn_protection = 0.0
	config.respawn_delay = 3.0
	config.time_limit = 0
	config.kill_limit = 50
	config.spear_recharge = 1.5


func _dummy_count() -> int:
	match _mode:
		"lure":
			return 3
		"arc", "miss", "mushroom", "lure_self":
			return 1
		_:
			return 2


func _spawn_points() -> Array[Transform3D]:
	var out: Array[Transform3D] = [_facing(PLAYER_SPOT, Vector3(0.0, 0.1, 0.0))]
	for spot: Vector3 in DUMMY_SPOTS:
		out.append(_facing(spot, PLAYER_SPOT))
	return out


static func _facing(from: Vector3, towards: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, Gub.yaw_towards(towards - from)), from)


## `MatchState._next_spawn` deliberately shuffles pads so nobody opens on the
## same ledge twice; a testbed wants the opposite. Put everyone back afterwards.
func _place_everyone() -> void:
	var player := MatchState.gubs.get(1) as Gub
	if player != null:
		player.revive_at(_facing(PLAYER_SPOT, Vector3(0.0, 0.1, 0.0)))
	for i in _dummy_count():
		var dummy := MatchState.gubs.get(DUMMY_BASE + i) as Gub
		if dummy != null:
			dummy.revive_at(_facing(DUMMY_SPOTS[i], PLAYER_SPOT))
			_stand_still(dummy)


## Make a dummy read as a remote Gub whose client is publishing "standing on the
## ground, not moving".
##
## A remote Gub takes its whole animation state from replicated fields, and
## nothing replicates for a fake roster entry — so `sync_grounded` sat at its
## default `false` and every dummy played the Jump clip forever, splayed out
## mid-leap in every screenshot this tool has ever produced. That is the same
## class of bug as the real one this testbed found in `GubAnimator`, except here
## the missing publisher is the testbed itself.
func _stand_still(dummy: Gub) -> void:
	dummy.sync_position = dummy.global_position
	dummy.sync_yaw = dummy.body_yaw
	dummy.sync_velocity = Vector3.ZERO
	dummy.sync_grounded = true
	dummy.sync_crouching = false
	dummy.sync_sliding = false


func _on_player_killed(victim_id: int, killer_id: int, cause: int) -> void:
	print("combat_range: %s killed %s (cause %d) at frame %d" % [
		Net.player_name(killer_id), Net.player_name(victim_id), cause, _frames])


# ----------------------------------------------------------------- driving ---

func _physics_process(_delta: float) -> void:
	_frames += 1
	if _trace:
		_trace_frame()
	if _mode == "free":
		# No input reading here any more: `Gub._read_input` does it, for the
		# local Gub, in the game and in this testbed alike. That it only ever
		# happened here is what left the real arena unwalkable.
		return
	if _mode == "walk":
		_drive_walk()
		return

	var player := MatchState.gubs.get(1) as Gub
	if player == null:
		return
	var rig := player.get_node_or_null("CameraRig") as GubCamera
	var combat := player.get_node_or_null("Combat") as GubCombat
	if rig == null or combat == null:
		return

	# Re-aim every frame until the moment of the throw. One call lands close and
	# the next few converge, because moving the rig moves the camera it solved
	# from — see `GubCamera.look_at_point`.
	_aim_at = _target_point()
	if not _acted:
		rig.look_at_point(_aim_at)

	# Twenty frames is enough for the rig to settle onto the target and for the
	# spawn-frame transforms to have been published.
	if _frames < 20 or _acted:
		return
	_acted = true
	match _mode:
		"mushroom":
			combat.try_place_mushroom()
		"lure", "lure_self":
			combat.try_throw_lure()
		_:
			combat.try_throw_spear()


func _target_point() -> Vector3:
	match _mode:
		"arc":
			return ARC_TARGET
		"miss":
			return Vector3(0.0, 0.05, -14.0)
		"lure":
			return DUMMY_SPOTS[1] + Vector3.UP * 0.2
		"lure_self":
			# Just in front of the player's own feet, so the pull has something
			# to drag and the camera has something to show.
			return PLAYER_SPOT + Vector3(0.0, 0.05, -3.0)
		_:
			var dummy := MatchState.gubs.get(DUMMY_BASE) as Gub
			if dummy == null:
				return Vector3(0.0, 1.0, -5.0)
			return dummy.global_position + Vector3.UP * dummy.eye_height()


## Say what a spear actually hit, which is the one thing a still frame cannot.
func _watch_spawned(node: Node) -> void:
	if node.has_signal("caught"):
		node.connect("caught", func(victim_ids: Array) -> void:
			var names: Array[String] = []
			for id: int in victim_ids:
				names.append(Net.player_name(id))
			print("combat_range: lure caught %d — %s"
				% [victim_ids.size(), ", ".join(names) if names else "nobody"]))
		return
	var spear := node as SpearProjectile
	if spear == null or not _trace:
		return
	spear.struck_gub.connect(func(victim: Gub, point: Vector3, bone: String) -> void:
		print("  >> struck %s at %v (bone %s)" % [victim.display_name, point, bone]))
	spear.struck_world.connect(func(point: Vector3, normal: Vector3) -> void:
		print("  >> struck world at %v normal %v" % [point, normal]))


## Where everything is, once a frame. Deliberately noisy — it is only on when
## `trace` is passed, and it is the difference between "it missed" and "it hit
## and nothing happened".
func _trace_frame() -> void:
	if _frames == 1:
		print("combat_range: mode=%s phase=%d host=%s offline=%s gubs=%d" % [
			_mode, MatchState.phase, Net.is_host, Net.is_offline,
			MatchState.gubs.size()])
		for peer_id: int in MatchState.gubs:
			var gub: Gub = MatchState.gubs[peer_id]
			print("  gub %d %s at %v local=%s alive=%s" % [
				peer_id, gub.display_name, gub.global_position,
				gub.is_local(), gub.alive])
	if _frames == 2:
		print("combat_range: frame 2 phase=%d (want %d = PLAYING) timer=%f" % [
			MatchState.phase, MatchState.Phase.PLAYING, MatchState._phase_timer])
	if not _acted:
		return
	for child in _items.get_children():
		var spear := child as SpearProjectile
		if spear == null:
			print("  f%d %s at %v" % [_frames, child.name, (child as Node3D).global_position])
			continue
		print("  f%d spear at %v stuck=%s auth=%s" % [
			_frames, spear.global_position, spear.is_stuck(), spear.authoritative])


## Hold W for a second and see whether the Gub went anywhere.
##
## `Input.action_press` is a real press as far as everything downstream is
## concerned, so this exercises the same path a player does: `Gub._read_input`
## reads the action, fills `input_direction`, and `_handle_movement` does the
## rest. Nothing here touches `input_direction` itself — that would test the
## movement code while skipping the wiring that was actually missing.
func _drive_walk() -> void:
	var player := MatchState.gubs.get(1) as Gub
	if player == null:
		return

	# Let it settle onto the ground before the start position is taken.
	if _frames < 20:
		return
	if _frames == 20:
		_walk_from = player.global_position
		Input.action_press("move_forward")
		return
	if _frames < 80:
		return

	Input.action_release("move_forward")
	var travelled := player.global_position.distance_to(_walk_from)
	if travelled >= WALK_MIN_DISTANCE:
		print("combat_range: walked %.2f m — walk PASS" % travelled)
	else:
		print("combat_range: walked %.2f m, wanted %.2f — walk FAIL"
			% [travelled, WALK_MIN_DISTANCE])
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		get_tree().quit()


func _print_controls() -> void:
	print("combat_range: WASD move, Shift sprint, Ctrl crouch, Space jump,")
	print("              LMB spear, Q mushroom, E lure, RMB aim, Esc quit.")


# ------------------------------------------------------------------ stage ---

func _build_touchline_camera() -> void:
	var view: Dictionary = VIEWS[_mode]
	_fixed_camera = Camera3D.new()
	_fixed_camera.fov = view["fov"]
	_fixed_camera.far = 400.0
	_fixed_camera.look_at_from_position(view["eye"], view["look"], Vector3.UP)
	add_child(_fixed_camera)
	# Claimed after the Gubs exist, so it wins over the local rig's own camera.
	_fixed_camera.make_current()


func _build_stage() -> void:
	_build_ground()
	_build_cover()
	_build_lighting()


func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(90, 1, 90)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(90, 90)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.13, 0.15, 0.13)
	mat.roughness = 0.95
	# A metre grid, so a still frame says how far the spear actually went.
	mat.uv1_scale = Vector3(45, 45, 1)
	plane.material = mat
	mesh.mesh = plane
	body.add_child(mesh)


## A back wall and two blocks: something for a long throw to stick into, and
## something to duck behind.
func _build_cover() -> void:
	var layout := [
		{"pos": Vector3(0, 3.0, -36), "size": Vector3(46, 6, 1)},
		{"pos": Vector3(-9, 0.9, -8), "size": Vector3(2.4, 1.8, 2.4)},
		{"pos": Vector3(8, 1.4, -16), "size": Vector3(3, 2.8, 3)},
	]
	for entry: Dictionary in layout:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.position = entry["pos"]
		add_child(body)

		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = entry["size"]
		shape.shape = box
		body.add_child(shape)

		var mesh := MeshInstance3D.new()
		var cube := BoxMesh.new()
		cube.size = entry["size"]
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.22, 0.25)
		mat.roughness = 0.9
		cube.material = mat
		mesh.mesh = cube
		body.add_child(mesh)


func _build_lighting() -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, -34, 0)
	key.light_energy = 1.6
	key.shadow_enabled = true
	add_child(key)

	var env := WorldEnvironment.new()
	env.environment = load("res://resources/config/default_env.tres")
	add_child(env)
