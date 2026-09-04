class_name GubAnimator
extends AnimationTree
## Drives the Gub's skeleton from the state of the `Gub` body above it.
##
## The blend graph is built here in code rather than authored into the scene.
## The equivalent `.tscn` is about 150 lines of anonymous `SubResource` blocks
## that no one can read in a diff and no one can comment; this is the same graph
## in a form where each connection says what it is for.
##
## The graph:
##
##     idle_run     (1D blend: Idle -> SlowRun -> FastRun, by speed)
##     crouch_move  (1D blend: Crouch -> CrouchWalk, by speed)
##       -> stance          Blend2, by how crouched
##       -> locomotion_rate TimeScale, so clips play at the speed we move at
##       -> grounded        Blend2 against Jump, by how airborne
##       -> base            Blend2 against Slide, by how sliding
##       -> throw           OneShot of SpearThrow, filtered to the upper body
##       -> output
##
## The throw being a filtered one-shot rather than a state is what lets a Gub
## throw while running: the legs keep their cycle and only the arms and upper
## spine take the throw.

## Bones the spear throw is allowed to move. Everything below the middle spine
## keeps running, crouching or falling as it was.
const UPPER_BODY_BONES: Array[String] = [
	"spine.003", "spine.004", "spine.005", "spine.006",
	"breast.L", "breast.R",
	"shoulder.L", "upper_arm.L", "forearm.L", "hand.L",
	"shoulder.R", "upper_arm.R", "forearm.R", "hand.R",
]

## Clips that must cycle rather than play once and freeze.
const LOOPING_CLIPS: Array[String] = ["Idle", "SlowRun", "FastRun", "Crouch", "CrouchWalk"]

const P_SPEED := "parameters/idle_run/blend_position"
const P_CROUCH_SPEED := "parameters/crouch_move/blend_position"
const P_STANCE := "parameters/stance/blend_amount"
const P_RATE := "parameters/locomotion_rate/scale"
const P_AIRBORNE := "parameters/grounded/blend_amount"
const P_SLIDE := "parameters/base/blend_amount"
const P_THROW := "parameters/throw/request"
const P_THROW_ACTIVE := "parameters/throw/active"

## How quickly the visual state catches up to the physical one. Crouch and
## slide are near-instant reads; the airborne blend is deliberately slower on
## the way down so landing settles rather than snapping.
const STANCE_BLEND_SPEED := 10.0
const AIRBORNE_RISE_SPEED := 7.0
const AIRBORNE_FALL_SPEED := 12.0
const SLIDE_BLEND_SPEED := 14.0

var _body: Gub
var _skeleton_path: String = ""
var _airborne: float = 0.0
var _stance: float = 0.0
var _slide: float = 0.0


func _ready() -> void:
	_body = get_parent() as Gub
	if _body == null:
		push_error("GubAnimator expects to be a child of a Gub")
		return

	var player := get_node_or_null(anim_player) as AnimationPlayer
	if player == null:
		push_error("GubAnimator: anim_player does not resolve to an AnimationPlayer")
		return

	_skeleton_path = _find_skeleton_track_prefix(player)
	_make_clips_loop(player)
	tree_root = _build_graph()
	active = true

	set(P_RATE, Gub.SPEED_SCALE)


## Track paths inside the imported clips look like `Gub/Skeleton3D:spine`. The
## prefix is read off an actual track rather than hard-coded, so renaming a node
## inside the source `.glb` does not silently disable the throw filter.
func _find_skeleton_track_prefix(player: AnimationPlayer) -> String:
	for clip_name in player.get_animation_list():
		var clip := player.get_animation(clip_name)
		for i in clip.get_track_count():
			var path := String(clip.track_get_path(i))
			if path.contains(":"):
				return path.get_slice(":", 0)
	push_warning("GubAnimator: no skeleton tracks found; throw will play full-body")
	return ""


## The clips import with looping off, because glTF has no concept of a looping
## animation. Inside a blend space a non-looping clip plays once and freezes on
## its last frame, so a running Gub would take one stride and then skate.
func _make_clips_loop(player: AnimationPlayer) -> void:
	for clip_name in LOOPING_CLIPS:
		if player.has_animation(clip_name):
			player.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR


# ------------------------------------------------------------------ graph ---

func _build_graph() -> AnimationNodeBlendTree:
	var tree := AnimationNodeBlendTree.new()

	# Blend positions are in *authored* clip speed, not in-game speed: the clips
	# were made at 1.21 / 2.20 / 4.01 m/s and the game runs SPEED_SCALE times
	# faster, with the TimeScale node making up the difference.
	var idle_run := AnimationNodeBlendSpace1D.new()
	idle_run.min_space = 0.0
	idle_run.max_space = Gub.AUTHORED_RUN
	idle_run.add_blend_point(_clip("Idle"), 0.0, -1, "idle")
	idle_run.add_blend_point(_clip("SlowRun"), Gub.AUTHORED_JOG, -1, "jog")
	idle_run.add_blend_point(_clip("FastRun"), Gub.AUTHORED_RUN, -1, "run")
	tree.add_node("idle_run", idle_run, Vector2(0, 0))

	var crouch_move := AnimationNodeBlendSpace1D.new()
	crouch_move.min_space = 0.0
	crouch_move.max_space = Gub.AUTHORED_CROUCH_WALK
	crouch_move.add_blend_point(_clip("Crouch"), 0.0, -1, "still")
	crouch_move.add_blend_point(_clip("CrouchWalk"), Gub.AUTHORED_CROUCH_WALK, -1, "walk")
	tree.add_node("crouch_move", crouch_move, Vector2(0, 200))

	tree.add_node("stance", AnimationNodeBlend2.new(), Vector2(260, 80))
	tree.add_node("locomotion_rate", AnimationNodeTimeScale.new(), Vector2(460, 80))
	tree.add_node("air", _clip("Jump"), Vector2(260, 300))
	tree.add_node("grounded", AnimationNodeBlend2.new(), Vector2(660, 120))
	tree.add_node("slide", _clip("Slide"), Vector2(460, 380))
	tree.add_node("base", AnimationNodeBlend2.new(), Vector2(860, 180))
	tree.add_node("throw_clip", _clip("SpearThrow"), Vector2(860, 400))
	tree.add_node("throw", _build_throw(), Vector2(1060, 180))

	tree.connect_node("stance", 0, "idle_run")
	tree.connect_node("stance", 1, "crouch_move")
	tree.connect_node("locomotion_rate", 0, "stance")
	tree.connect_node("grounded", 0, "locomotion_rate")
	tree.connect_node("grounded", 1, "air")
	tree.connect_node("base", 0, "grounded")
	tree.connect_node("base", 1, "slide")
	tree.connect_node("throw", 0, "base")
	tree.connect_node("throw", 1, "throw_clip")
	tree.connect_node("output", 0, "throw")
	return tree


func _build_throw() -> AnimationNodeOneShot:
	var shot := AnimationNodeOneShot.new()
	shot.fadein_time = 0.10
	shot.fadeout_time = 0.22
	# Blend, not add: SpearThrow is a full pose for the arms, not an offset from
	# whatever they were doing.
	shot.mix_mode = AnimationNodeOneShot.MIX_MODE_BLEND

	# The filter is what makes this a *layer* rather than a state. Only the
	# listed bones take the throw; the legs stay in whatever locomotion the
	# blend space below is producing, so you can throw at a dead run.
	if not _skeleton_path.is_empty():
		shot.filter_enabled = true
		for bone in UPPER_BODY_BONES:
			shot.set_filter_path(NodePath("%s:%s" % [_skeleton_path, bone]), true)
	return shot


func _clip(clip_name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip_name
	return node


# ------------------------------------------------------------------ update ---

func _process(delta: float) -> void:
	if _body == null or tree_root == null:
		return

	var horizontal := Vector3(_body.velocity.x, 0.0, _body.velocity.z).length()
	# Convert in-game speed back into the clips' own units so the blend space is
	# asked for the pose it was actually authored for.
	var authored_speed := horizontal / Gub.SPEED_SCALE

	set(P_SPEED, clampf(authored_speed, 0.0, Gub.AUTHORED_RUN))
	set(P_CROUCH_SPEED, clampf(authored_speed, 0.0, Gub.AUTHORED_CROUCH_WALK))

	_stance = move_toward(_stance, 1.0 if _body.is_crouching() else 0.0,
		STANCE_BLEND_SPEED * delta)
	_slide = move_toward(_slide, 1.0 if _body.is_sliding() else 0.0,
		SLIDE_BLEND_SPEED * delta)

	var airborne_target := 0.0 if _body.is_on_floor() else 1.0
	var airborne_speed := AIRBORNE_RISE_SPEED if airborne_target > _airborne \
		else AIRBORNE_FALL_SPEED
	_airborne = move_toward(_airborne, airborne_target, airborne_speed * delta)

	set(P_STANCE, _stance)
	set(P_SLIDE, _slide)
	set(P_AIRBORNE, _airborne)


## Fire the throw animation. Called on every peer, so remote Gubs visibly throw.
func play_throw() -> void:
	if tree_root == null:
		return
	set(P_THROW, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func is_throwing() -> bool:
	return tree_root != null and bool(get(P_THROW_ACTIVE))
