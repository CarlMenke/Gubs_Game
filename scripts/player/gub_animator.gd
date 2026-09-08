class_name GubAnimator
extends AnimationTree
## Drives the Gub's skeleton from the state of the `Gub` body above it.
##
## **Ground poses come from speed, air poses come from the arc, events are
## one-shots.** Nothing in this tree runs a clock that is not either (a) a
## looping locomotion cycle, (b) a OneShot that restarts every time it is fired,
## or (c) a node that is scrubbed to an absolute time every frame. That is not a
## style preference: an `AnimationNodeAnimation` sitting in a blend runs its own
## clock from the moment the tree starts whether or not anything is listening,
## reaches its last frame, and stops there for the rest of the round (D-026).
## Every clip in here is one of those three kinds, so that bug cannot be written
## into this graph without deleting one of them first.
##
## The graph, left to right:
##
##     stand      BlendSpace1D   Idle @ 0 | Walk @ WALK_SPEED | Run @ RUN_SPEED
##     crouch     BlendSpace1D   CrouchIdle @ 0 | CrouchWalk @ CROUCH_SPEED
##     stance     Blend2         stand / crouch, by how crouched
##     air_one    Animation(JumpOne) behind air_one_seek, scrubbed by the arc
##     air_two    Animation(JumpTwo) behind air_two_seek, scrubbed by the arc
##     air        Blend2         air_one / air_two, 1 if this airtime is a dive
##     grounded   Blend2         stance / air, by how airborne
##     slide      OneShot        the low part of Slide, full body
##     land       OneShot        JumpOne's touchdown and absorb, full body
##     roll       OneShot        JumpTwo's ground roll, full body
##     throw      OneShot        Throw at THROW_RATE, filtered to the upper body
##     output   <- throw
##
## Both blend positions are in **game** metres per second, not in clip units:
## each locomotion node carries its own playback rate (`game speed / authored
## speed`) in a custom timeline, so a Gub travelling at exactly one of the three
## speeds is playing exactly one clip at exactly the rate that keeps its feet on
## the floor. There is no global TimeScale to keep in step with anything.
##
## One code path for the Gub you are driving and the seven you are watching:
## everything read here comes either from a `Gub` accessor that already answers
## with replicated values on a remote Gub (`is_grounded`, `is_sliding`,
## `is_crouching`, `vertical_speed`, `velocity`) or from a replicated serial
## counter (`sync_jump_serial`, `sync_dive_serial`).

# ------------------------------------------------------------------- clips ---

## Every clip this graph names. Checked once in `_ready`, because a rebuild that
## renames or drops one would otherwise show up as a Gub that simply never
## moves, with nothing in the log.
const REQUIRED_CLIPS: Array[String] = [
	"Idle", "Walk", "Run", "CrouchIdle", "CrouchWalk",
	"JumpOne", "JumpTwo", "Slide", "Throw",
]

# -------------------------------------------------------- the airborne arc ---

## The two jump clips are far longer in the air than any jump the physics
## actually makes — JumpOne spends 0.34 s of clip off the ground against a
## 0.70 s round trip at JUMP_VELOCITY — so neither is played on a clock. They
## are *indexed by where the body is in its arc*: `phase` 0 is leaving the
## ground, 0.5 is the apex, 1 is about to land, and these three clip times are
## the poses that belong at those three moments.
##
## The two clips are treated differently because the pipeline treats their
## vertical motion differently (`VERTICAL_RISE_KEPT` in `tools/build_gub.py`),
## and each set of times below is measured on the clip as it is actually built.
##
## JumpOne is a vertical hop, and its pelvis rise *is* the ballistic motion the
## physics capsule already performs, so the pipeline pins the hips at their
## first key. With the pelvis not moving, the tell for "high in the air" is how
## far the feet are tucked up under it: the toes are 0.14 m *below* rest at
## 0.58 s (legs still extended in the push-off), peak 0.17 m above it at 0.83 s,
## and are back on the ground by 0.97 s. So the apex pose is the 0.83 s tuck and
## not the 0.75 s the hips top out at in the raw clip.
##
## START is 0.68 and not 0.60 for the same reason the apex moved: 0.58-0.65 is
## the push-off, and with the pelvis pinned those extended legs reach 0.141 m
## under the floor (deepest at 0.583 s, measured by the build's own floor
## check). The physics take-off is instantaneous — the capsule is already
## leaving at JUMP_VELOCITY on the frame the jump is pressed — so there is
## nothing for a wind-up pose to be in step with, and phase 0 may as well be
## the first frame that is clear of the ground.
const JUMP_ONE_START := 0.68
const JUMP_ONE_APEX := 0.83
const JUMP_ONE_END := 0.95

## JumpTwo is a front somersault, and its hips rise is *not* something the
## capsule duplicates — the clip's pelvis has to be up there or the inverted
## body's head and hands go through the floor. So the pipeline keeps the rise in
## full, and the clip is once again self-consistent: hips top out 0.618 m above
## standing at 0.900 s, the hands take the ground at 1.183 s and stay down to
## 1.833, and the feet come through at 1.530.
##
## Which puts the apex pose back where the hips say it is. (It was moved to
## 1.10 s while the pelvis was pinned, to hurry past the frames that sank
## furthest below the floor; nothing sinks now while the body is airborne, so
## the honest reading is the right one.) The window ends at 1.48, a frame or two
## before the feet arrive, and the roll one-shot takes it from there.
const JUMP_TWO_START := 0.58
const JUMP_TWO_APEX := 0.90
const JUMP_TWO_END := 1.48

# ------------------------------------------------------------- the windows ---

## The slide. `Slide` drops the hips from 0.69 m to 0.17 m by 0.50 s, holds them
## there to 1.13 s and is standing again by 1.70; the window is the whole of
## that. `Gub.SLIDE_DURATION` (1.0 s) ends the physical slide at 1.10 s of clip,
## just as the hips start to rise, and SLIDE_FADE_OUT covers the stand-up.
const SLIDE_CLIP_START := 0.10
const SLIDE_CLIP_END := 1.70

## The landing absorb, taken out of JumpOne: touchdown at 0.95 and the dip
## bottoms out with the hips at 0.43 m around 1.28. JUMP_ONE_END and this share
## the 0.95 boundary on purpose — the scrub hands over to the one-shot at the
## frame the feet touch.
##
## The window runs to 1.45 rather than 1.35 because Godot fades a one-shot out
## *inside* its window and not after it: with the end at 1.35 the LAND_FADE_OUT
## 0.20 s of blend started at 1.15, so the absorb was already being pulled back
## toward the locomotion pose before it had reached its deepest frame, and the
## dip that is the whole point of the clip never fully arrived. 1.45 gives the
## bottom of the absorb the frames it needs and still leaves the stand-up to the
## fade rather than playing it out.
const LAND_CLIP_START := 0.95
const LAND_CLIP_END := 1.45

## The dive's ground roll, out of JumpTwo: the feet come down through 1.48, the
## hips are on the floor (0.12 m) from 1.53 to 1.77, and the body is standing
## again by 2.25. Ends at 2.10 for the same reason the landing does.
##
## Starts at 1.62 and not at the 1.48 the air scrub hands over at, on purpose.
## The roll is authored below the floor: those hips keys sit *under* the clip's
## first key, which the pipeline's vertical rule never lifts (see
## `tools/build_gub.py`), and from 1.48 to ~1.60 the skin is 0.15-0.25 m under
## the plane — the most sunk stretch of the whole clip. From 1.62 it is within
## 0.10 m and closing. The cost is the first two frames of the tumble, which a
## touchdown — an impact, with a 0.05 s fade-in — hides anyway.
const ROLL_CLIP_START := 1.62
const ROLL_CLIP_END := 2.10

## The throw. `Throw` is 3.83 s of wind-up, throw, follow-through and a long
## return to idle; only the middle 1.60 s is the throw. The arm does not move
## until 0.55, so the fade-in has finished before anything the eye follows
## starts, and the follow-through is done by 1.95.
const THROW_CLIP_START := 0.50
const THROW_CLIP_END := 2.10
## Played faster than authored: 1.60 s of wind-up is a long time to hold a
## button for, and 1.0 s is not. This is the one clip in the graph with a rate
## that is not derived from a ground speed, so it gets its own TimeScale node.
const THROW_RATE := 1.6

## Where in `Throw` the spear leaves the hand, in the clip's own seconds.
## Measured, not chosen: tracking the right hand through the clip gives a peak
## speed of 9.9 m/s at 1.625 s, the hand crossing in front of the body at
## 1.60 and reaching furthest forward at 1.68. A thrown object separates at peak
## forward hand speed, so 1.633 (frame 99) is the release; by 1.68 the hand is
## decelerating and letting go there would read as a push.
const THROW_RELEASE_IN_CLIP := 1.633

## How long after `play_throw()` the spear actually leaves the hand, in real
## seconds. `GubCombat` reads this, and it is derived rather than typed so that
## moving the window or the rate cannot leave the spear and the hand disagreeing
## (D-025 is what that costs). = (1.633 - 0.50) / 1.6.
const THROW_RELEASE_TIME := (THROW_RELEASE_IN_CLIP - THROW_CLIP_START) / THROW_RATE

## Fade times, in and out, for the four one-shots. The slide comes in fast and
## leaves slowly because its exit *is* the stand-up; the landings come in almost
## instantly because a touchdown is an impact.
const SLIDE_FADE_IN := 0.08
const SLIDE_FADE_OUT := 0.30
const LAND_FADE_IN := 0.05
const LAND_FADE_OUT := 0.20
const ROLL_FADE_IN := 0.05
const ROLL_FADE_OUT := 0.25
const THROW_FADE_IN := 0.08
const THROW_FADE_OUT := 0.22

# ------------------------------------------------------------------ blends ---

## How fast the visual state catches up with the physical one, in units of blend
## per second. Crouch is a near-instant read. Take-off is faster than landing on
## purpose: leaving the ground is a decision and should look like one, while
## arriving wants to settle rather than snap — and the landing one-shot is
## covering the same frames anyway.
const STANCE_BLEND_SPEED := 10.0
const AIRBORNE_RISE_SPEED := 14.0
const AIRBORNE_FALL_SPEED := 10.0
const DIVE_BLEND_SPEED := 12.0

## An airtime shorter than this fires no landing one-shot. Stepping off a kerb,
## or the single frame `is_on_floor()` sometimes drops on a slope, is not a
## landing worth absorbing, and a 0.05 s absorb fired every few strides down a
## rocky slope is a visible stutter.
##
## It is `Gub.ROLL_MIN_AIRTIME` rather than its own number because the body uses
## the same threshold to decide whether to hold the player still through the
## roll (ROLL_LOCK). Two copies of that number could drift apart into the two
## states nobody wants: a roll animation with the controls live under it, or
## 0.45 s of dead controls with no roll to show for them.
const LAND_MIN_AIRTIME := Gub.ROLL_MIN_AIRTIME

# ----------------------------------------------------------- the throw mask --

## Bones the spear throw is allowed to move. Everything from the middle spine
## down keeps whatever the locomotion, the air scrub or the slide is producing,
## which is what makes the throw a *layer* rather than a state: you can throw at
## a dead run. Hips and Spine are deliberately not here — the throw's own
## rotation of them would fight the run cycle's weight shift.
##
## The finger and `*_End` tips carry no tracks in the exported clips (the
## exporter drops constant channels, D-023), so filtering them is a no-op
## today; they are listed because they are part of the arm, and a future rebuild
## that animates a grip should not need this list edited to work.
const UPPER_BODY_BONES: Array[String] = [
	"Spine1", "Spine2", "Neck", "Head", "HeadTop_End",
	"LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
	"LeftHandThumb1", "LeftHandThumb2", "LeftHandThumb3", "LeftHandThumb4",
	"LeftHandIndex1", "LeftHandIndex2", "LeftHandIndex3", "LeftHandIndex4",
	"LeftHandMiddle1", "LeftHandMiddle2", "LeftHandMiddle3", "LeftHandMiddle4",
	"RightShoulder", "RightArm", "RightForeArm", "RightHand",
	"RightHandThumb1", "RightHandThumb2", "RightHandThumb3", "RightHandThumb4",
	"RightHandIndex1", "RightHandIndex2", "RightHandIndex3", "RightHandIndex4",
	"RightHandMiddle1", "RightHandMiddle2", "RightHandMiddle3", "RightHandMiddle4",
]

# -------------------------------------------------------------- parameters ---

const P_STAND_SPEED := "parameters/stand/blend_position"
const P_CROUCH_SPEED := "parameters/crouch/blend_position"
const P_STANCE := "parameters/stance/blend_amount"
const P_AIR_ONE_SEEK := "parameters/air_one_seek/seek_request"
const P_AIR_TWO_SEEK := "parameters/air_two_seek/seek_request"
const P_DIVE := "parameters/air/blend_amount"
const P_AIRBORNE := "parameters/grounded/blend_amount"
const P_SLIDE := "parameters/slide/request"
const P_SLIDE_ACTIVE := "parameters/slide/active"
const P_LAND := "parameters/land/request"
const P_ROLL := "parameters/roll/request"
const P_THROW := "parameters/throw/request"
const P_THROW_ACTIVE := "parameters/throw/active"
const P_THROW_RATE := "parameters/throw_rate/scale"

var _body: Gub
var _skeleton_path: String = ""

## Smoothed blend positions, so nothing in the tree steps.
var _stance: float = 0.0
var _airborne: float = 0.0
var _dive_blend: float = 0.0

## What this animator believes about the body. `_grounded` and `_sliding` are
## kept rather than read fresh because the interesting thing about both is the
## frame they *change*.
var _grounded: bool = true
var _sliding: bool = false

## The current airtime. `_airtime_open` is false while the Gub is standing on
## something and nothing is expected to land.
var _airtime_open: bool = false
var _airtime: float = 0.0
var _dived: bool = false
## The upward speed the dive was launched at, which is the scale the dive's arc
## phase is measured against. Seeded with the floor the dive itself enforces.
var _dive_launch: float = Gub.DIVE_UP_VELOCITY

## Last values of the replicated counters this animator has acted on. Seeded
## from the body in `_ready`, so a Gub that spawns into a match already several
## dives old does not open with one.
var _dive_serial: int = 0
var _jump_serial: int = 0


func _ready() -> void:
	_body = get_parent() as Gub
	if _body == null:
		push_error("GubAnimator expects to be a child of a Gub")
		return

	var player := get_node_or_null(anim_player) as AnimationPlayer
	if player == null:
		push_error("GubAnimator: anim_player does not resolve to an AnimationPlayer")
		return
	var missing := _missing_clips(player)
	if not missing.is_empty():
		push_error("GubAnimator: art/generated/gub.glb is missing clips: %s"
			% ", ".join(missing))
		return

	_skeleton_path = _find_skeleton_track_prefix(player)
	tree_root = _build_graph(player)
	active = true

	# A parameter and not a property, so it can only be set once the graph is
	# installed.
	set(P_THROW_RATE, THROW_RATE)

	_grounded = _body.is_grounded()
	_dive_serial = _body.sync_dive_serial
	_jump_serial = _body.sync_jump_serial
	# A Gub that dies in mid-air is put back on the ground somewhere else, and it
	# did not land to get there: without this, the teleport reads as a touchdown
	# and every respawn out of a fall opens with a landing absorb.
	_body.respawned.connect(_forget_airtime)
	# Standing, whatever the body says. A Gub is spawned onto the ground, and a
	# remote one is spawned before anything has replicated to it — `sync_grounded`
	# defaults to false, and opening on the air pose is what had every dummy in
	# `tools/combat_range.tscn` and every Gub in the lobby splayed out mid-leap.
	# If it really is falling, AIRBORNE_RISE_SPEED covers the gap in 0.07 s.
	_airborne = 0.0


## Track paths inside the imported clips look like `Armature/Skeleton3D:Hips`.
## The prefix is read off an actual track rather than hard-coded, so renaming a
## node inside the source `.glb` does not silently disable the throw filter —
## which would fail by throwing with the whole body, at a run, and look like a
## blend problem.
func _find_skeleton_track_prefix(player: AnimationPlayer) -> String:
	for clip_name in player.get_animation_list():
		var clip := player.get_animation(clip_name)
		for i in clip.get_track_count():
			var path := String(clip.track_get_path(i))
			if path.contains(":"):
				return path.get_slice(":", 0)
	push_warning("GubAnimator: no skeleton tracks found; throw will play full-body")
	return ""


func _missing_clips(player: AnimationPlayer) -> PackedStringArray:
	var missing := PackedStringArray()
	for clip_name in REQUIRED_CLIPS:
		if not player.has_animation(clip_name):
			missing.append(clip_name)
	return missing


# ------------------------------------------------------------------ graph ---

func _build_graph(player: AnimationPlayer) -> AnimationNodeBlendTree:
	var tree := AnimationNodeBlendTree.new()

	# Blend positions are in game m/s, and each point plays its own clip at the
	# rate that plants its feet at that speed. Idle sits at 0 at rate 1.
	var stand := AnimationNodeBlendSpace1D.new()
	stand.min_space = 0.0
	stand.max_space = Gub.RUN_SPEED
	# Every point keeps running whether or not it carries any weight. See
	# `_blend2` for why, and note that it matters most here: without it the Run
	# point sits on frame 0 for the whole match until the first sprint, and that
	# sprint cross-fades a *static* run frame into a mid-stride walk.
	stand.sync = true
	stand.add_blend_point(_cycle(player, "Idle", 0.0, 0.0), 0.0, -1, "idle")
	stand.add_blend_point(_cycle(player, "Walk", Gub.WALK_SPEED, Gub.AUTHORED_WALK),
		Gub.WALK_SPEED, -1, "walk")
	stand.add_blend_point(_cycle(player, "Run", Gub.RUN_SPEED, Gub.AUTHORED_RUN),
		Gub.RUN_SPEED, -1, "run")
	tree.add_node("stand", stand, Vector2(0, 0))

	var crouch := AnimationNodeBlendSpace1D.new()
	crouch.min_space = 0.0
	crouch.max_space = Gub.CROUCH_SPEED
	crouch.sync = true
	crouch.add_blend_point(_cycle(player, "CrouchIdle", 0.0, 0.0), 0.0, -1, "still")
	crouch.add_blend_point(
		_cycle(player, "CrouchWalk", Gub.CROUCH_SPEED, Gub.AUTHORED_CROUCH_WALK),
		Gub.CROUCH_SPEED, -1, "walk")
	tree.add_node("crouch", crouch, Vector2(0, 220))

	tree.add_node("stance", _blend2(), Vector2(280, 100))

	tree.add_node("air_one", _scrubbed("JumpOne"), Vector2(0, 420))
	tree.add_node("air_one_seek", AnimationNodeTimeSeek.new(), Vector2(200, 420))
	tree.add_node("air_two", _scrubbed("JumpTwo"), Vector2(0, 560))
	tree.add_node("air_two_seek", AnimationNodeTimeSeek.new(), Vector2(200, 560))
	tree.add_node("air", _blend2(), Vector2(400, 490))

	tree.add_node("grounded", _blend2(), Vector2(560, 280))

	tree.add_node("slide_clip", _window("Slide", SLIDE_CLIP_START, SLIDE_CLIP_END),
		Vector2(560, 700))
	tree.add_node("slide", _shot(SLIDE_FADE_IN, SLIDE_FADE_OUT), Vector2(760, 320))
	tree.add_node("land_clip", _window("JumpOne", LAND_CLIP_START, LAND_CLIP_END),
		Vector2(760, 700))
	tree.add_node("land", _shot(LAND_FADE_IN, LAND_FADE_OUT), Vector2(960, 360))
	tree.add_node("roll_clip", _window("JumpTwo", ROLL_CLIP_START, ROLL_CLIP_END),
		Vector2(960, 700))
	tree.add_node("roll", _shot(ROLL_FADE_IN, ROLL_FADE_OUT), Vector2(1160, 400))
	tree.add_node("throw_clip", _window("Throw", THROW_CLIP_START, THROW_CLIP_END),
		Vector2(1160, 700))
	tree.add_node("throw_rate", AnimationNodeTimeScale.new(), Vector2(1340, 700))
	tree.add_node("throw", _upper_body_shot(), Vector2(1360, 440))

	tree.connect_node("stance", 0, "stand")
	tree.connect_node("stance", 1, "crouch")
	tree.connect_node("air_one_seek", 0, "air_one")
	tree.connect_node("air_two_seek", 0, "air_two")
	tree.connect_node("air", 0, "air_one_seek")
	tree.connect_node("air", 1, "air_two_seek")
	tree.connect_node("grounded", 0, "stance")
	tree.connect_node("grounded", 1, "air")
	tree.connect_node("slide", 0, "grounded")
	tree.connect_node("slide", 1, "slide_clip")
	tree.connect_node("land", 0, "slide")
	tree.connect_node("land", 1, "land_clip")
	tree.connect_node("roll", 0, "land")
	tree.connect_node("roll", 1, "roll_clip")
	tree.connect_node("throw_rate", 0, "throw_clip")
	tree.connect_node("throw", 0, "roll")
	tree.connect_node("throw", 1, "throw_rate")
	tree.connect_node("output", 0, "throw")
	return tree


## A two-way blend whose *unweighted* side keeps running.
##
## That is what `sync` buys, and it is not a nicety. With `sync` at its default
## false, Godot freezes any input a blend node is not currently listening to:
## measured on this graph, after 1.5 s of walking the `stand` space reported
## `run/current_position` 0.0000 while the walk point was mid-stride, and the
## whole `crouch` space sat on frame 0 the entire time. So every entry into a
## cycle that had not been weighted yet — the first sprint of a round, the first
## crouch — cross-faded a *static* frame into a moving one over 4 frames, which
## is a foot scissor and then a pop as the frozen clip finally starts. Blending
## two cycles that are both mid-stride is at worst a phase mismatch; blending
## against a still frame is a visible fault, and it was the transition
## complaint this rework exists to answer.
##
## The three OneShots need `sync` for a related but different reason — keeping
## the branch *underneath* them alive while they play; see `_shot`.
func _blend2() -> AnimationNodeBlend2:
	var blend := AnimationNodeBlend2.new()
	blend.sync = true
	return blend


## One looping locomotion cycle, played at exactly the rate that keeps its feet
## planted at the game speed its blend point sits at.
##
## The rate lives in a custom timeline: `stretch_time_scale` makes the node play
## its clip in `timeline_length` seconds instead of its own length, so
## `length / rate` seconds of timeline is a playback rate of `rate`. Pass a
## speed of 0 for the two standing poses, which have no rate to match.
##
## `loop_mode` is set here rather than trusted from the asset. With
## `use_custom_timeline` on, the node's own loop mode wins, which means the
## thing that guarantees a run cycle cycles is this graph and not a flag in a
## `.import` file that a rebuild could drop.
func _cycle(player: AnimationPlayer, clip: String, game_speed: float,
		authored_speed: float) -> AnimationNodeAnimation:
	var rate := 1.0
	if authored_speed > 0.0 and game_speed > 0.0:
		rate = game_speed / authored_speed
	var node := AnimationNodeAnimation.new()
	node.animation = clip
	node.use_custom_timeline = true
	node.start_offset = 0.0
	node.timeline_length = player.get_animation(clip).length / rate
	node.stretch_time_scale = true
	node.loop_mode = Animation.LOOP_LINEAR
	return node


## A window of a clip, played once at authored speed and held on its last frame.
##
## `stretch_time_scale` has to be **false** here. True gives you a playback rate
## but throws the window's far end away: the node plays from `start_offset` to
## the clip's own end at `clip length / timeline_length`, so a 1.6 s window into
## a 3.8 s clip would run on for another 1.7 s of clip nobody asked for. That is
## why the throw's rate is a separate TimeScale node and not a stretched window.
func _window(clip: String, from: float, to: float) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip
	node.use_custom_timeline = true
	node.start_offset = from
	node.timeline_length = to - from
	node.stretch_time_scale = false
	node.loop_mode = Animation.LOOP_NONE
	return node


## A clip with no timeline of its own, because something else says what time it
## is every frame. Both air poses are these, and the seeks they are given are
## therefore in the clip's own seconds.
##
## `loop_mode` is stated for the reader and does nothing: a node's loop mode is
## only consulted when it has a custom timeline, so these two take the clip's,
## which the pipeline exports as LOOP_NONE. It would not matter either way —
## a seek past the end clamps.
func _scrubbed(clip: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip
	node.use_custom_timeline = false
	node.loop_mode = Animation.LOOP_NONE
	return node


func _shot(fade_in: float, fade_out: float) -> AnimationNodeOneShot:
	var shot := AnimationNodeOneShot.new()
	shot.fadein_time = fade_in
	shot.fadeout_time = fade_out
	# Blend, not add: these are whole poses, not offsets from whatever the body
	# was already doing.
	shot.mix_mode = AnimationNodeOneShot.MIX_MODE_BLEND
	# Keeps the branch *underneath* running while this shot is at full weight.
	# Measured, because it is not obvious: with `sync` at its default false and
	# no filter, Godot stops a zero-weight input dead — a 2 s one-shot advanced
	# its own input 0 by 0.00 s. With `sync` true it advanced by the full 2.00 s.
	# So without this a run cycle would freeze for the length of every landing
	# absorb and come back a third of a stride behind the feet it is supposed to
	# be planting. (A *filtered* shot keeps its input 0 alive either way, because
	# the tracks outside the filter still carry weight — so the throw would work
	# without this and the three full-body shots would not.)
	shot.sync = true
	return shot


## The throw is a layer, not a state, and the filter is what makes it one: only
## `UPPER_BODY_BONES` take the clip, and the legs stay in whatever the blend
## below is producing.
func _upper_body_shot() -> AnimationNodeOneShot:
	var shot := _shot(THROW_FADE_IN, THROW_FADE_OUT)
	if _skeleton_path.is_empty():
		return shot
	shot.filter_enabled = true
	for bone in UPPER_BODY_BONES:
		shot.set_filter_path(NodePath("%s:%s" % [_skeleton_path, bone]), true)
	return shot


# ------------------------------------------------------------------ update ---

func _process(delta: float) -> void:
	if _body == null or tree_root == null:
		return

	var speed := Vector3(_body.velocity.x, 0.0, _body.velocity.z).length()
	set(P_STAND_SPEED, clampf(speed, 0.0, Gub.RUN_SPEED))
	set(P_CROUCH_SPEED, clampf(speed, 0.0, Gub.CROUCH_SPEED))

	_track_airtime(delta)
	_track_slide()
	_scrub_air()

	_stance = move_toward(_stance, 1.0 if _body.is_crouching() else 0.0,
		STANCE_BLEND_SPEED * delta)
	var airborne_target := 0.0 if _grounded else 1.0
	var airborne_speed := AIRBORNE_RISE_SPEED if airborne_target > _airborne \
		else AIRBORNE_FALL_SPEED
	_airborne = move_toward(_airborne, airborne_target, airborne_speed * delta)
	# Moved toward 0 while grounded rather than snapped on touchdown: the dive
	# pose has to be allowed to fade out of the air branch instead of turning
	# into the jump pose on the frame the feet land.
	var dive_target := 1.0 if (_dived and not _grounded) else 0.0
	_dive_blend = move_toward(_dive_blend, dive_target, DIVE_BLEND_SPEED * delta)

	set(P_STANCE, _stance)
	set(P_AIRBORNE, _airborne)
	set(P_DIVE, _dive_blend)


## Where the body is in its arc, turned into an absolute clip time.
##
## `phase` is 0 leaving the ground, 0.5 at the apex and 1 about to land, and it
## is read off the vertical velocity rather than off a stopwatch — which is what
## makes a fall work with no extra clip. A Gub that walks off a ledge has vy of
## about 0, so it starts at phase 0.5 (the apex pose) and falls through to the
## pre-landing pose; one that is falling faster than it could ever have launched
## holds phase 1.
static func arc_time(vy: float, launch: float, from: float, apex: float,
		to: float) -> float:
	var phase := clampf(0.5 * (1.0 - vy / maxf(launch, 0.01)), 0.0, 1.0)
	if phase < 0.5:
		return lerpf(from, apex, phase / 0.5)
	return lerpf(apex, to, (phase - 0.5) / 0.5)


## Both air clips are told what time it is every frame, whether or not anything
## is looking at them. A `TimeSeek` at zero weight still takes its request — the
## branch is processed regardless, which is the same fact that made D-026
## possible — so the pose is already correct on the frame the airborne blend
## starts to come up, and there is no take-off event to miss.
##
## On the ground, vertical velocity stops being a phase: `move_and_slide` zeroes
## it on touchdown, and `vy == 0` means *apex*. Read literally that snaps both
## air poses back to the top of the leap on the one frame the airborne blend is
## still most of the picture — a 0.48 m hip pop and a 0.10 m foot pop, measured.
## So a grounded Gub holds the about-to-land pose instead, which is also the pose
## the landing one-shots pick the body up from, so the hand-over is continuous.
func _scrub_air() -> void:
	if _grounded:
		set(P_AIR_ONE_SEEK, JUMP_ONE_END)
		set(P_AIR_TWO_SEEK, JUMP_TWO_END)
		return
	# `vertical_speed()` and not `velocity.y`: on a remote Gub the replicated
	# value is a physics tick fresher than the copy in `velocity`. See `Gub`.
	var vy := _body.vertical_speed()
	set(P_AIR_ONE_SEEK, arc_time(vy, Gub.JUMP_VELOCITY,
		JUMP_ONE_START, JUMP_ONE_APEX, JUMP_ONE_END))
	set(P_AIR_TWO_SEEK, arc_time(vy, _dive_launch,
		JUMP_TWO_START, JUMP_TWO_APEX, JUMP_TWO_END))


## Airtimes, from the two replicated serials and the grounded flag.
func _track_airtime(delta: float) -> void:
	# The serials are the only news that cannot arrive late, so they open the
	# airtime and the grounded flag only confirms it.
	if _body.sync_jump_serial != _jump_serial:
		_jump_serial = _body.sync_jump_serial
		_open_airtime(false)
	if _body.sync_dive_serial != _dive_serial:
		_dive_serial = _body.sync_dive_serial
		_open_airtime(true)

	var grounded := _body.is_grounded()
	if grounded != _grounded:
		_grounded = grounded
		if grounded:
			_close_airtime()
		elif not _airtime_open:
			# No serial: walked off a ledge, or was knocked off one.
			_open_airtime(false)
	if not _grounded and _airtime_open:
		_airtime += delta


## Start tracking a fresh airtime. A jump clears the dive flag because a new
## jump is a new airtime; a dive sets it, and records the speed its arc is
## measured against — `Gub._dive` has already added DIVE_UP_VELOCITY to the
## vertical velocity by the time this sees it.
##
## The launch speed is read exactly once, on the frame the serial changes, and
## the whole leap is then measured against it — so this is the one reader in the
## file that cannot afford a stale value, and it asks `vertical_speed()` for the
## replicated one. Read off `velocity` instead, a remote dive out of a rising
## jump scaled its arc against the *pre-dive* climb: phase stuck at 0 (the
## take-off pose) for the first third of the leap and hit 1 (feet down, about to
## land) while the body was still over a metre up.
func _open_airtime(dived: bool) -> void:
	_airtime_open = true
	_airtime = 0.0
	if dived:
		_dived = true
		_dive_launch = maxf(_body.vertical_speed(), Gub.DIVE_UP_VELOCITY)
	else:
		_dived = false


## Touchdown. Fire the roll if the airtime was a dive, the absorb if it was not,
## and nothing at all if the feet were barely off the ground.
##
## `_dived` is deliberately not cleared here — `_process` fades the dive pose out
## of the air branch while grounded, and the next take-off clears the flag.
func _close_airtime() -> void:
	if _airtime_open and _airtime >= LAND_MIN_AIRTIME:
		set(P_ROLL if _dived else P_LAND,
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_airtime_open = false
	_airtime = 0.0


## Drop the airtime without landing it. `_grounded` is deliberately left alone:
## `revive_at` moves the body without running `move_and_slide`, so `is_on_floor()`
## is not yet true at the spawn point, and believing it would put the Gub into
## the air pose for the first few frames of its new life.
func _forget_airtime() -> void:
	_airtime_open = false
	_airtime = 0.0
	_dived = false
	_jump_serial = _body.sync_jump_serial
	_dive_serial = _body.sync_dive_serial


## The slide is the one event with an end as well as a beginning: the clip is
## 1.6 s long and the physical slide can be cut short by a wall, a ledge or the
## speed dropping, so it is faded out rather than left to finish.
func _track_slide() -> void:
	var sliding := _body.is_sliding()
	if sliding == _sliding:
		return
	_sliding = sliding
	if sliding:
		set(P_SLIDE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	elif bool(get(P_SLIDE_ACTIVE)):
		set(P_SLIDE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)


# -------------------------------------------------------------- public API ---

## Fire the throw animation. Called on every peer, so remote Gubs visibly throw,
## and re-firing mid-throw restarts it from the top of the window.
func play_throw() -> void:
	if tree_root == null:
		return
	set(P_THROW, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## True from the moment the throw is fired until its fade-out has finished. The
## camera uses it to keep the body facing the crosshair through the throw.
func is_throwing() -> bool:
	return tree_root != null and bool(get(P_THROW_ACTIVE))


## Airborne, in an airtime a dive was spent in.
func is_diving() -> bool:
	return _dived and not _grounded
