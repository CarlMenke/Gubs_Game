"""Build the Gub — one skinned mesh, one skeleton, nine clips — from eight Mixamo FBX files.

`assets/source/GUB_2/` holds the same character exported eight times, one animation
per file: Idle, Walking, Run, CrouchWalking, Slide, JumpOne, JumpTwo, Throw. Each
file carries a full copy of the mesh (8814 verts), the 49-bone `mixamorig:`
skeleton and a 2048² base-colour JPEG. Godot wants the opposite shape: one
`art/generated/gub.glb` with every clip in it, so one AnimationPlayer can blend
between them. This script is that conversion, and it is the only place the Gub's
art is prepared — re-running it is always safe and never touches `assets/`.

Run it as:

    "$BLENDER" --background --python tools/build_gub.py [-- --emission FLOAT]

or `bash tools/build_gub.sh` to have Blender located for you. `--emission`
defaults to 0.15 (see *Material* below), so a plain rebuild reproduces the
asset that is in the tree.

What it does, and why each step is needed:

*Consolidate.* All eight files are imported into one scene, their bind poses and
meshes compared (they must be identical, or the clips would not be talking about
the same body), then seven of the eight armatures and meshes are deleted and
their actions re-targeted onto the survivor. Actions address bones by name, so
this is a rename problem, not a re-rig problem.

*Strip `mixamorig:`.* Godot mangles the colon in a bone name to an underscore,
so every script naming a bone would have to spell `mixamorig_RightHand`. The
prefix goes here, once, and the vertex groups and every fcurve data path are
checked afterwards to prove the rename reached them.

*Scale to 1.80 m and bake it.* Blender's FBX importer leaves the armature at
rotation (90°,0,0) and scale 0.01, which makes the Gub 9.5 mm tall. The whole
transform is baked into the rest data so both objects export at identity — but
**Blender does not scale pose-bone `location` fcurves when the armature's scale
is applied**, so every location curve is multiplied by the same factor by hand
(≈1.90 from the 0.01 import scale). Rotation keys are bone-local and need
nothing. §2 of the design spec measured the whole rig at this scale; the numbers
are re-printed here so a regression is visible in the log rather than in game.

*Lock the root motion.* Every clip but Idle and JumpOne travels, because Mixamo
bakes the travel into the Hips: Run covers 1.94 m per cycle, JumpTwo leaps 4.6 m.
Left in, the mesh slides out of the CharacterBody3D carrying it. The Hips
`location` curve is locked to its first key on the two horizontal axes (bone
index 0 sideways, 2 forward — the Hips bone is vertical in rest, so index 1 is
up) for every clip. The travel is printed on the way out: that is the speed each
clip was *authored* at, and `gub.gd` matches its playback rate to it so the feet
grip instead of skating.

*The vertical rule, one answer per clip.* Walk/Run/CrouchWalk/Idle bob 11 cm or
less and Slide drops half a metre — that is pose, and it stays. Only the two
jumps rise above standing (JumpOne 0.46 m, JumpTwo 0.62 m), and whether that rise
belongs to the animation or to the physics body is **not the same question for
both clips**, which is why `VERTICAL_RISE_KEPT` is a table and not a flag:

*JumpOne keeps the clamp* (0.0). It is a vertical hop whose pelvis rise is
exactly the ballistic motion the physics capsule already performs, so leaving it
in would do the arc twice and launch the Gub through ceilings. Held down, the
legs tuck under a pelvis that stays put while the downward half of the curve —
the landing absorb — still plays, because the body is standing on the floor by
then and cannot produce it.

*JumpTwo keeps its full rise* (1.0). It is a front somersault, and its rise is
not a second copy of the physics arc but the clearance the rotation needs: with
the pelvis pinned, the inverted body's head and hands go 0.41 m below the floor
from clip 1.00 to 1.60 s and the dive touches down upside-down. The raw clip is
self-consistent — the hands plant on the ground at ~1.17–1.45 s precisely
because the hips are high — so the rise stays, and during the dive the animation
rides that much above the physics capsule, which reads as a bigger leap rather
than as a body punched through the floor.

Because that is a judgement about one clip at a time, it is checked rather than
trusted: once the vertical is processed, every bone head is sampled over each
jump and the deepest one is measured against `FLOOR_LIMIT`, reported either side
of the frame the hands take the ground so the log says plainly which side of the
landing a dip happened on. With the rise kept, JumpTwo's flight clears the floor
and only the authored ground roll dips under it (−0.167 m, a knuckle at 1.40 s);
with the rise clamped, the same measurement reads −0.410 m in mid-air. The
limits sit in that gap.

*Align the facing.* The clips were authored at different resting yaws (Idle sits
50° off the rest pose, CrouchWalk 38°, JumpTwo +19° at the moment the game starts
using it). One clip at a time this is invisible; the moment an AnimationTree
blends two of them the body swings sideways on every state change. This is D-008
again, on new source. Facing is measured by forward kinematics — the yaw of the
line from the left hip joint to the right one, the one pair of joints that stays
put while the arms and torso animate — and corrected with a yaw on the Hips
rotation keys. Motion *within* a clip is untouched, so the throw still winds the
body up and the slide still goes sideways. The reference moment is the mean over
the cycle for a loop, and the first frame of the window the game actually plays
for a one-shot: a jump aligned on its take-off frame is a jump that leaves the
ground pointing where the player is going.

*Close the loops.* Idle/Walk/Run/CrouchWalk are cycles whose last frame repeats
their first (verified: within 6 mm of bone-relative agreement). The final key is
dropped so the loop does not hold that pose twice — see DROP_LOOP_TAIL for the
trade-off. The clip length therefore comes out one frame shorter than the source.

*Synthesise CrouchIdle.* There is no crouching-in-place clip, and a BlendSpace1D
needs something at speed 0 or the Gub keeps walking on the spot when the player
crouches and stops. CrouchWalking frame 37 (t = 0.600 s) is the one frame of the
cycle with both feet flat on the ground 0.27 m apart, so it becomes a two-key
one-second hold.

*Material.* One Principled BSDF, base colour from the packed JPEG downscaled to
1024² (the Gub is never seen closer than a couple of metres and eight of them
share this texture), roughness 0.9, metallic 0. The texture is also wired into
Emission Color at `--emission` strength, **default 0.15**: the old asset was a
pre-shaded emission texture and was always readable at night (D-027), while this
one, lit only by the moon and the torches, measured 1.5–2× the luminance of the
undergrowth it stands in — a near-silhouette wherever no torch reaches, with the
still pre-shaded spear in its hand brighter than its owner. 0.15 lifts the body
off that background at a spear's range without turning it into a lamp when a
torch does reach it. It stays an argument rather than a constant so that night
readability is re-judged by rebuilding the asset instead of by editing a material
inside a scene file, and 0.0 gives back a plain base-colour PBR material.

The image is named `basecolor` and the file `gub.glb` on purpose: Godot extracts
an embedded texture as `<glb name>_<image name>`, and the extension follows the
format of the embedded image rather than being chosen by Godot. This one stays
the source JPEG (re-encoding a photographic atlas as PNG triples the file for no
visible gain), so what the import step drops in the tree is
`art/generated/gub_basecolor.jpg` and its `.import` — not a `.png`. Anything
naming that file has to spell the `.jpg`.

*How a looping clip says so.* Godot can be told per animation in the `.import`
file (`_subresources` with `settings/loop_mode`), and it does work — but the
importer then rewrites that file with every default it can think of for each
animation named there, all 256 possible slices apiece: 348 KB of generated noise
in the tree instead of 1.1 KB, rewritten on every import, and the answer to "does
this clip loop?" split across two files that nobody re-syncs. So the five loops
are declared in the GLB instead, by exporting them under Godot's own name suffix
(`Idle-loop`): the scene importer strips the suffix and sets LOOP_LINEAR, which
leaves `_subresources` empty and the CLIPS table below as the only place the loop
flags are written down. `nodes/use_name_suffixes` has to stay true in
`gub.glb.import`, or the clips arrive in Godot still called `Idle-loop`.
"""

import math
import os
import sys
import time

import bpy
from mathutils import Matrix, Quaternion, Vector

# ---------------------------------------------------------------------------
# What is being built
# ---------------------------------------------------------------------------

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(REPO, "assets", "source", "GUB_2")
OUT_PATH = os.path.join(REPO, "art", "generated", "gub.glb")

# Mixamo exports at 60 fps and Blender numbers frames from 1, so a key on frame
# N is at (N-1)/60 seconds. Every time in this file is in seconds unless it is
# called a frame.
FPS = 60

PREFIX = "mixamorig:"
HIPS = "Hips"
HIP_JOINTS = ("LeftUpLeg", "RightUpLeg")

# 1.80 m. The old Gub was 1.81 m, and the collision capsule (STAND_HEIGHT 1.55)
# and eye height in `gub.gd` are tuned to that, so matching it keeps the whole
# body-and-camera rig valid. Everything else in this script is derived from it.
TARGET_HEIGHT = 1.80

# (file, clip name, loops, alignment reference)
#
# The reference is the moment whose facing is made to match the rest pose. For a
# cycle that is the mean over the whole clip, because a walk sways ±10° either
# side of where it is going and picking one frame would bake half a sway in. For
# a one-shot it is the first frame of the window `gub_animator.gd` plays, so the
# pose that appears when the OneShot fires is the aligned one.
LOOP_MEAN = None
CLIPS = (
    ("Idle.fbx",           "Idle",       True,  LOOP_MEAN),
    ("Walking.fbx",        "Walk",       True,  LOOP_MEAN),
    ("Run.fbx",            "Run",        True,  LOOP_MEAN),
    ("CrouchWalking.fbx",  "CrouchWalk", True,  LOOP_MEAN),
    ("Slide.fbx",          "Slide",      False, 0.10),
    ("JumpOne.fbx",        "JumpOne",    False, 0.60),
    ("JumpTwo.fbx",        "JumpTwo",    False, 0.58),
    ("Throw.fbx",          "Throw",      False, 0.50),
)

# How much of a clip's hips rise above its own first key survives, per clip.
# 0.0 pins the pelvis flat (the rise is the physics body's job, and doing it in
# both places at once launches the Gub through ceilings); 1.0 leaves the clip
# alone. A clip not named here keeps its vertical untouched — only the two jumps
# rise at all, and they need opposite answers, for the reasons in the module
# docstring. FLOOR_LIMIT below is the check that each answer is the right one.
VERTICAL_RISE_KEPT = {"JumpOne": 0.0, "JumpTwo": 1.0}

# How far below the floor the lowest bone head may reach in a clip once the rule
# above has been applied. A centimetre or two under is normal and authored into
# the Mixamo source (a planted toe joint rests at 0.035 m and Run dips 2 cm), and
# these two clips go deeper for reasons that are not the pipeline's to fix:
# JumpOne's push-off extends the legs below the pelvis they are pinned to
# (−0.141 m at the toe tips at 0.58 s — real, and skipped by the window the
# animator plays), and JumpTwo ends in a ground roll authored with the hands and
# back through the plane (−0.167 m at a knuckle at 1.40 s: a human-proportioned
# roll retargeted onto a body whose head is a 0.8 m blob). Each limit sits just
# under what its source authors, which is what makes it a check rather than a
# wish — build JumpTwo with its rise clamped away instead and the same
# measurement reads −0.410 m, in mid-air, well past the limit. (§P of the fix
# spec asked for −0.08 on JumpTwo; that was written before the roll was measured
# and no build of this clip can meet it.) Every clip in VERTICAL_RISE_KEPT needs
# a limit, or its rule would ship unchecked — see check_tables.
FLOOR_LIMIT = {"JumpOne": -0.15, "JumpTwo": -0.20}

# A palm flat on the floor leaves the wrist joint about this far above it (the
# hand is a quarter of a metre long on this cartoon body and the joint sits
# inside the wrist). Only used for reporting: on JumpTwo the hands take the
# landing, and when they touch is the moment the animator's roll window is cut
# from, so the number belongs in the build log rather than in somebody's notes.
HAND_PLANT_CLEARANCE = 0.12
HAND_JOINTS = ("LeftHand", "RightHand")

# How a looping clip tells Godot it loops.
#
# Godot's scene importer reads suffixes off imported names (`nodes/use_name_
# suffixes`, on by default and on in `gub.glb.import`): an animation exported as
# `Idle-loop` arrives as `Idle` with loop_mode LOOP_LINEAR. The alternative is to
# declare `settings/loop_mode` per clip in `_subresources` in the .import file —
# which works, but Godot then rewrites that file with every default it can think
# of for each animation it mentions, all 256 possible slices apiece: 348 KB of
# generated noise in the tree instead of 1.1 KB. It also splits the answer to
# "does this clip loop?" across two files that nobody re-syncs. Here the CLIPS
# table above is the only place it is written down. The cost is that the names
# inside the GLB carry the suffix; the names in Godot do not.
LOOP_SUFFIX = "-loop"

# CrouchIdle: (source clip, source frame, frames to hold).
CROUCH_IDLE = ("CrouchWalk", 37, FPS)

# Dropping the duplicate final key of a cycle costs one frame of the cycle: the
# loop then steps from frame N-1 straight back to frame 1, which is a normal
# one-frame step taken in zero time. Keeping it would give a mathematically
# perfect loop *if* Godot wraps t == length to 0 rather than drawing it, which
# is not worth betting the whole asset on — if it draws it, the first pose is
# held for two frames every cycle, which is the stutter this avoids. The
# authored speed is identical either way (one frame less time, one frame less
# travel), so nothing downstream changes. Set False to keep the tail key.
DROP_LOOP_TAIL = True

# A foot is "off the ground" once its toe joint is this far above where it rests.
# 5 cm is above the noise in a planted foot (the toe joint sits at 0.035 m and
# wobbles by 5 mm) and below any real step.
FOOT_CLEARANCE = 0.05
# §2's take-off and landing times were measured with a much larger clearance;
# both are printed so the two can be compared without re-deriving them.
FOOT_CLEARANCE_WIDE = 0.30

# "Low" is below this fraction of the clip's own standing hip height (the slide
# and the dive's landing roll get down to a quarter of it), and "standing again"
# is back above this one.
LOW_FRACTION = 0.40
STANDING_FRACTION = 0.90

# Texture edge in the exported GLB. Eight Gubs share this one image, the Gub is
# never seen closer than a couple of metres, and the source 2048² JPEG is well
# over a megabyte on its own — most of what each FBX weighs. At 1024² it is
# about 115 KB of a 1.5 MB file.
TEXTURE_EDGE = 1024

ROUGHNESS = 0.9
METALLIC = 0.0


def log(msg=""):
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# Layered-action plumbing
#
# Blender 5.x actions are layered and slotted: `action.fcurves` does not exist
# any more, the curves live in
# `action.layers[].strips[].channelbags[].fcurves`, and which channelbag applies
# to which datablock is decided by a *slot*. Every action here comes from the FBX
# importer with exactly one layer, one strip and one slot, so these helpers
# flatten that away rather than pretending to support the general case.
# ---------------------------------------------------------------------------

def iter_fcurves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for fcurve in bag.fcurves:
                    yield fcurve


def bone_curves(action, bone, prop):
    """The fcurves of one pose-bone property, ordered by array index."""
    path = 'pose.bones["%s"].%s' % (bone, prop)
    found = {}
    for fcurve in iter_fcurves(action):
        if fcurve.data_path == path:
            found[fcurve.array_index] = fcurve
    return [found[i] for i in sorted(found)]


def key_frames(fcurve):
    return [kp.co.x for kp in fcurve.keyframe_points]


def linearise(fcurve):
    """Make a rewritten curve mean exactly what its keys say.

    Every curve here is baked at 60 fps and re-sampled at 60 fps on export, so
    the shape between keys is never read — but a Bezier handle left over from
    before a rewrite can still bend the value *at* a key, and on a clamped curve
    it overshoots the clamp. Flattening to linear removes the question.
    """
    for kp in fcurve.keyframe_points:
        kp.interpolation = 'LINEAR'
        kp.handle_left = kp.co
        kp.handle_right = kp.co
    fcurve.update()


def action_frame_span(action):
    """(first, last) integer frame covered by an action's keys."""
    lo, hi = None, None
    for fcurve in iter_fcurves(action):
        for kp in fcurve.keyframe_points:
            lo = kp.co.x if lo is None else min(lo, kp.co.x)
            hi = kp.co.x if hi is None else max(hi, kp.co.x)
    return int(round(lo)), int(round(hi))


# ---------------------------------------------------------------------------
# 1-2. Import the eight files and prove they are the same character
# ---------------------------------------------------------------------------

def import_sources():
    """Import every FBX, returning [(clip, armature, mesh, action)] in clip order."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1.0

    imported = []
    for filename, clip, _loop, _ref in CLIPS:
        path = os.path.join(SOURCE_DIR, filename)
        if not os.path.isfile(path):
            raise SystemExit("missing source: %s" % path)
        before_objects = set(bpy.data.objects.keys())
        before_actions = set(bpy.data.actions.keys())
        bpy.ops.import_scene.fbx(filepath=path, use_anim=True)
        objects = [bpy.data.objects[n] for n in bpy.data.objects.keys()
                   if n not in before_objects]
        actions = [bpy.data.actions[n] for n in bpy.data.actions.keys()
                   if n not in before_actions]

        armatures = [o for o in objects if o.type == 'ARMATURE']
        meshes = [o for o in objects if o.type == 'MESH']
        if len(armatures) != 1 or len(meshes) != 1 or len(actions) != 1:
            raise SystemExit("%s: expected 1 armature, 1 mesh and 1 action, got "
                             "%d/%d/%d" % (filename, len(armatures), len(meshes),
                                           len(actions)))
        first, last = action_frame_span(actions[0])
        log("  imported %-18s -> %-11s %d verts, %d bones, frames %d..%d (%.3f s)"
            % (filename, clip, len(meshes[0].data.vertices),
               len(armatures[0].data.bones), first, last, (last - first) / FPS))
        imported.append((clip, armatures[0], meshes[0], actions[0]))
    return imported


def assert_same_character(imported):
    """Refuse to build if the eight files do not share a body.

    The clips only make sense on one skeleton, and a silently different bind
    pose would show up as a subtly broken skin in one clip and nowhere else.
    """
    ref_clip, ref_arm, ref_mesh, _ = imported[0]
    ref_bones = [b.name for b in ref_arm.data.bones]
    ref_groups = sorted(g.name for g in ref_mesh.vertex_groups)
    worst = 0.0
    for clip, arm, mesh, _action in imported[1:]:
        if len(mesh.data.vertices) != len(ref_mesh.data.vertices):
            raise SystemExit("%s: %d verts, %s has %d"
                             % (clip, len(mesh.data.vertices), ref_clip,
                                len(ref_mesh.data.vertices)))
        if [b.name for b in arm.data.bones] != ref_bones:
            raise SystemExit("%s: skeleton differs from %s" % (clip, ref_clip))
        if sorted(g.name for g in mesh.vertex_groups) != ref_groups:
            raise SystemExit("%s: vertex groups differ from %s" % (clip, ref_clip))
        for name in ref_bones:
            a = ref_arm.data.bones[name].matrix_local
            b = arm.data.bones[name].matrix_local
            for row in range(4):
                for col in range(4):
                    worst = max(worst, abs(a[row][col] - b[row][col]))
    log("  %d files agree: %d verts, %d bones, %d vertex groups, bind pose within %.2g"
        % (len(imported), len(ref_mesh.data.vertices), len(ref_bones),
           len(ref_groups), worst))
    if worst > 1e-5:
        raise SystemExit("bind poses differ by %.4g — these are not the same rig" % worst)


def consolidate(imported):
    """Keep one armature and one mesh; every action moves onto the survivor.

    An action addresses bones by name through `pose.bones["..."]`, so an action
    imported alongside armature #7 drives armature #1 unchanged. Nothing is
    re-rigged here; seven duplicate bodies are deleted.
    """
    clip, arm, mesh, _ = imported[0]
    actions = {}
    for clip_name, other_arm, other_mesh, action in imported:
        action.name = clip_name
        actions[clip_name] = action
        if other_arm is arm:
            continue
        if other_arm.animation_data:
            other_arm.animation_data.action = None
        bpy.data.objects.remove(other_mesh, do_unlink=True)
        bpy.data.objects.remove(other_arm, do_unlink=True)

    arm.name = "Armature"
    arm.data.name = "Armature"
    mesh.name = "Gub"
    mesh.data.name = "Gub"
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = None

    for obj in list(bpy.data.objects):
        if obj not in (arm, mesh):
            bpy.data.objects.remove(obj, do_unlink=True)

    # Each file also brought its own copy of the mesh data, the armature data,
    # the material and the 2048² JPEG, and deleting an *object* deletes none of
    # them. They have to go in dependency order — an orphaned mesh datablock
    # still counts as a user of its material, and that material as a user of its
    # image — or nothing is collected at all.
    dropped = []
    for collection in (bpy.data.meshes, bpy.data.armatures,
                       bpy.data.materials, bpy.data.images):
        gone = 0
        for datablock in list(collection):
            if datablock.users == 0:
                collection.remove(datablock)
                gone += 1
        dropped.append("%d %s" % (gone, collection.rna_type.identifier
                                  .replace("BlendData", "").lower()))
    log("  kept 1 armature + 1 mesh; dropped orphaned %s" % ", ".join(dropped))
    log("  %d actions: %s" % (len(actions), ", ".join(actions)))
    return arm, mesh, actions


# ---------------------------------------------------------------------------
# 3. Names
# ---------------------------------------------------------------------------

def strip_bone_prefix(arm, mesh, actions):
    """Drop `mixamorig:` from bones, vertex groups and every fcurve data path.

    Renaming a bone normally propagates to the vertex groups and to the animation
    data of every object using the armature — but only seven of these eight
    actions were ever assigned to this armature, and none of them is assigned
    now, so the sweep afterwards is the part that actually does the work. It is
    kept in that order rather than hand-rewriting first, so that if a future
    Blender does propagate, this still ends up in one consistent state.
    """
    renamed = 0
    for bone in arm.data.bones:
        if bone.name.startswith(PREFIX):
            bone.name = bone.name[len(PREFIX):]
            renamed += 1
    fixed_groups = 0
    for group in mesh.vertex_groups:
        if group.name.startswith(PREFIX):
            group.name = group.name[len(PREFIX):]
            fixed_groups += 1
    fixed_curves = 0
    for action in actions.values():
        for fcurve in iter_fcurves(action):
            if PREFIX in fcurve.data_path:
                fcurve.data_path = fcurve.data_path.replace(PREFIX, "")
                fixed_curves += 1

    left = [b.name for b in arm.data.bones if PREFIX in b.name]
    left += [g.name for g in mesh.vertex_groups if PREFIX in g.name]
    for action in actions.values():
        left += [f.data_path for f in iter_fcurves(action) if PREFIX in f.data_path]
    if left:
        raise SystemExit("%d names still carry the prefix, e.g. %s" % (len(left), left[0]))
    log("  stripped '%s' from %d bones; fixed %d vertex groups and %d fcurve paths by hand"
        % (PREFIX, renamed, fixed_groups, fixed_curves))
    log("  vertex groups: %d of %d bones deform the mesh"
        % (len(mesh.vertex_groups), len(arm.data.bones)))


# ---------------------------------------------------------------------------
# 4. Scale, and the fcurves Blender will not scale for you
# ---------------------------------------------------------------------------

def mesh_height(mesh, matrix):
    zs = [(matrix @ v.co).z for v in mesh.data.vertices]
    return min(zs), max(zs)


def scale_to_height(arm, mesh, actions):
    """Bake the import transform and TARGET_HEIGHT into the rest data.

    The FBX importer hands over a 9.5 mm character rotated 90° about X. Both
    objects share that one world matrix, so the whole thing can be pushed into
    the armature's bones and the mesh's vertices, leaving both objects at
    identity — which is what makes `root_scale = 1.0` in the .import file
    honest, and what makes a BoneAttachment3D's local space metres.

    Pose-bone `location` is stored in armature units in the bone's own rest
    basis, and nothing in Blender rescales it when the rest data is scaled, so
    every location curve is multiplied here. Rotations are bone-local and are
    already right.
    """
    world = arm.matrix_world.copy()
    drift = max(abs(world[r][c] - mesh.matrix_world[r][c])
                for r in range(4) for c in range(4))
    if drift > 1e-6:
        raise SystemExit("mesh and armature do not share a transform (%.3g)" % drift)

    low, high = mesh_height(mesh, world)
    factor = TARGET_HEIGHT / (high - low)
    matrix = Matrix.Scale(factor, 4) @ world
    scale = matrix.to_scale()
    if max(abs(s - scale.x) for s in scale) > 1e-6:
        raise SystemExit("import transform is not a uniform scale: %s" % (scale,))

    arm.data.transform(matrix)
    mesh.data.transform(matrix)
    arm.matrix_basis = Matrix.Identity(4)
    mesh.matrix_basis = Matrix.Identity(4)
    mesh.matrix_parent_inverse = Matrix.Identity(4)
    # `matrix_world` is a cached product of the parent chain; without this the
    # measurements below would still be reading the 0.01 import scale.
    bpy.context.view_layer.update()
    for obj in (arm, mesh):
        stale = max(abs(obj.matrix_world[r][c] - (1.0 if r == c else 0.0))
                    for r in range(4) for c in range(4))
        if stale > 1e-6:
            raise SystemExit("%s did not end up at identity (%.3g)" % (obj.name, stale))

    curves = 0
    for action in actions.values():
        for fcurve in iter_fcurves(action):
            if not fcurve.data_path.endswith(".location"):
                continue
            for kp in fcurve.keyframe_points:
                kp.co.y *= scale.x
                kp.handle_left.y *= scale.x
                kp.handle_right.y *= scale.x
            fcurve.update()
            curves += 1

    log("  imported %.5f m tall; scaled by %.4f in world (%.6f in armature units)"
        % (high - low, factor, scale.x))
    log("  baked the transform into rest data and scaled %d location fcurves" % curves)
    return scale.x


def report_rest_pose(arm, mesh):
    """Re-print §2's measurements so a regression shows up in the log."""
    low, high = mesh_height(mesh, mesh.matrix_world)
    size = [max((mesh.matrix_world @ v.co)[i] for v in mesh.data.vertices)
            - min((mesh.matrix_world @ v.co)[i] for v in mesh.data.vertices)
            for i in range(3)]
    log("  mesh bbox %.3f wide, %.3f deep, %.3f tall; feet at z=%+.4f"
        % (size[0], size[1], size[2], low))
    heights = ("Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "HeadTop_End",
               "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase")
    log("  rest heights " + "  ".join(
        "%s %.3f" % (n, arm.data.bones[n].head_local.z) for n in heights))
    log("  rest arm span LeftArm %.3f  LeftForeArm %.3f  LeftHand %.3f (x from centre)"
        % tuple(arm.data.bones[n].head_local.x
                for n in ("LeftArm", "LeftForeArm", "LeftHand")))
    toe = arm.data.bones["LeftToeBase"].head_local - arm.data.bones["LeftFoot"].head_local
    log("  LeftFoot -> LeftToeBase points (%+.3f, %+.3f, %+.3f) in Blender "
        "(-Y is front, so this is +Z in Godot)" % (toe.x, toe.y, toe.z))
    if abs(size[2] - TARGET_HEIGHT) > 1e-3 or abs(low) > 1e-3:
        raise SystemExit("mesh is %.4f tall with feet at %.4f — wanted %.2f at 0"
                         % (size[2], low, TARGET_HEIGHT))


# ---------------------------------------------------------------------------
# Posing the rig so it can be measured
# ---------------------------------------------------------------------------

def use_action(arm, action):
    """Make `action` the pose the armature evaluates, so frame_set can sample it."""
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = action
    if action is not None and len(action.slots):
        arm.animation_data.action_slot = action.slots[0]


def sample_bones(arm, action, bones):
    """{bone: [world position per frame]} plus the frame numbers sampled."""
    use_action(arm, action)
    first, last = action_frame_span(action)
    frames = list(range(first, last + 1))
    tracks = dict((b, []) for b in bones)
    scene = bpy.context.scene
    for frame in frames:
        scene.frame_set(frame)
        for bone in bones:
            tracks[bone].append((arm.matrix_world @ arm.pose.bones[bone].matrix).translation.copy())
    return frames, tracks


def rest_facing(arm):
    left = arm.data.bones[HIP_JOINTS[0]].head_local
    right = arm.data.bones[HIP_JOINTS[1]].head_local
    return math.atan2(right.y - left.y, right.x - left.x)


def wrap_pi(angle):
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


# ---------------------------------------------------------------------------
# The authored numbers: travel, speed, and the moments the game keys off
# ---------------------------------------------------------------------------

def measure_clip(arm, action, clip):
    """Everything §2 measured, measured again on the built rig.

    Run before the root motion is locked and the jumps are clamped, because
    that is what these numbers describe: how far the clip travels (the speed the
    feet were drawn for) and when the body leaves the ground (the window the
    animator scrubs). Locking removes the travel; clamping removes the rise; the
    times stay where they are.
    """
    bones = (HIPS, "LeftToeBase", "RightToeBase", "RightHand", "Head") + HIP_JOINTS
    frames, tracks = sample_bones(arm, action, bones)
    hips = tracks[HIPS]
    n = len(frames)
    seconds = [(f - frames[0]) / FPS for f in frames]
    duration = seconds[-1]

    travel = math.hypot(hips[-1].x - hips[0].x, hips[-1].y - hips[0].y)
    speed = travel / duration if duration > 0 else 0.0

    ground = min(arm.data.bones["LeftToeBase"].head_local.z,
                 arm.data.bones["RightToeBase"].head_local.z)
    clearance = [min(tracks["LeftToeBase"][i].z, tracks["RightToeBase"][i].z) - ground
                 for i in range(n)]

    def crossing(threshold, rising):
        """First (or last) time the feet are above `threshold`, interpolated."""
        span = range(1, n) if rising else range(n - 1, 0, -1)
        for i in span:
            a, b = clearance[i - 1], clearance[i]
            if (a < threshold) != (b < threshold):
                t = (threshold - a) / (b - a)
                return seconds[i - 1] + t / FPS
        return None

    # The window a clip spends near the ground — the slide's low phase, the dive
    # landing's roll — measured against the clip's own standing height so one
    # rule fits a crouch and a jump.
    standing = hips[0].z
    low = [i for i in range(n) if hips[i].z < LOW_FRACTION * standing]
    recovered = None
    if low:
        for i in range(low[-1], n):
            if hips[i].z > STANDING_FRACTION * standing:
                recovered = seconds[i]
                break

    info = {
        "clip": clip,
        "frames": n,
        "duration": duration,
        "travel": travel,
        "speed": speed,
        "hips_first": standing,
        "hips_min": min(p.z for p in hips),
        "hips_max": max(p.z for p in hips),
        "hips_apex": seconds[max(range(n), key=lambda i: hips[i].z)],
        "airborne": max(clearance),
        "leave": crossing(FOOT_CLEARANCE, True),
        "land": crossing(FOOT_CLEARANCE, False),
        "leave_wide": crossing(FOOT_CLEARANCE_WIDE, True),
        "land_wide": crossing(FOOT_CLEARANCE_WIDE, False),
        "low_from": seconds[low[0]] if low else None,
        "low_to": seconds[low[-1]] if low else None,
        "stood_up": recovered,
    }

    hand = tracks["RightHand"]
    fastest = max(range(1, n), key=lambda i: (hand[i] - hand[i - 1]).length)
    info["hand_peak"] = (hand[fastest] - hand[fastest - 1]).length * FPS
    info["hand_peak_at"] = seconds[fastest]
    reach = min(range(n), key=lambda i: hand[i].y)
    info["hand_reach_at"] = seconds[reach]
    return info


def report_measurements(rows):
    log("  clip         frames  length   travel   speed    hips z: first  min    max")
    for r in rows:
        log("  %-11s %5d  %6.3f  %6.3f  %6.3f            %.3f  %.3f  %.3f"
            % (r["clip"], r["frames"], r["duration"], r["travel"], r["speed"],
               r["hips_first"], r["hips_min"], r["hips_max"]))
    log()
    log("  airborne windows (foot clearance over %.2f m / over %.2f m, which is what "
        "§2's figures used):" % (FOOT_CLEARANCE, FOOT_CLEARANCE_WIDE))
    for r in rows:
        if r["airborne"] < FOOT_CLEARANCE_WIDE:
            continue
        log("  %-11s feet leave %.3f / %.3f   apex %.3f (hips %.3f m)   feet touch %.3f / %.3f"
            % (r["clip"], r["leave"], r["leave_wide"], r["hips_apex"], r["hips_max"],
               r["land"], r["land_wide"]))
    log()
    log("  time spent low (hips under %.0f%% of the clip's standing height, back over %.0f%%):"
        % (LOW_FRACTION * 100.0, STANDING_FRACTION * 100.0))
    for r in rows:
        if r["low_from"] is None:
            continue
        log("  %-11s down from %.3f to %.3f (min %.3f m), standing again %s"
            % (r["clip"], r["low_from"], r["low_to"], r["hips_min"],
               "%.3f" % r["stood_up"] if r["stood_up"] else "not within the clip"))
    log()
    for r in rows:
        if r["clip"] != "Throw":
            continue
        log("  %-11s right hand peaks at %.2f m/s at %.3f s, furthest forward %.3f s"
            % (r["clip"], r["hand_peak"], r["hand_peak_at"], r["hand_reach_at"]))


# ---------------------------------------------------------------------------
# 5. Root motion
# ---------------------------------------------------------------------------

def check_ground(arm, action, clip):
    """Prove the vertical rule left the clip standing on the floor, and say where.

    VERTICAL_RISE_KEPT is a judgement per clip, so this is the part that keeps it
    honest rather than merely documented. Every bone head is sampled in world
    space over the whole clip; the lowest one anywhere in it is compared with the
    clip's FLOOR_LIMIT and the build stops if it is deeper. That is the check
    that catches a pelvis pinned under a body that then rotates over it — the
    dive's head 0.41 m through the floor — at build time instead of in a render.

    The hands are measured in the same pass because on JumpTwo they are what
    takes the landing: the window in which they are within HAND_PLANT_CLEARANCE
    of the floor is the plant, and that is both the moment `gub_animator.gd` cuts
    its roll window from and the line this report is split on. Everything deep in
    a correctly built JumpTwo is on the far side of it — the authored roll — and
    everything on the near side is flight, which is what the rule governs and
    what must clear the floor. JumpOne never plants a hand, so it reports once.
    """
    bones = [b.name for b in arm.data.bones]
    frames, tracks = sample_bones(arm, action, bones)
    count = len(frames)
    seconds = [(f - frames[0]) / FPS for f in frames]

    def deepest(indices):
        """(z, bone, seconds) of the lowest bone head over those frames."""
        best = None
        for i in indices:
            for bone in bones:
                if best is None or tracks[bone][i].z < best[0]:
                    best = (tracks[bone][i].z, bone, seconds[i])
        return best

    hands = [min(tracks[b][i].z for b in HAND_JOINTS) for i in range(count)]
    lowest_hand = min(range(count), key=lambda i: hands[i])
    down = [i for i in range(count) if hands[i] <= HAND_PLANT_CLEARANCE]
    plant = (seconds[down[0]], seconds[down[-1]]) if down else None

    log("              hands lowest %+.3f m at %.3f s, %s"
        % (hands[lowest_hand], seconds[lowest_hand],
           "planted (wrist within %.2f m of the floor) from %.3f to %.3f s"
           % (HAND_PLANT_CLEARANCE, plant[0], plant[1]) if plant
           else "never within %.2f m of the floor" % HAND_PLANT_CLEARANCE))
    phases = ([("airborne, before the plant", range(down[0])),
               ("from the plant on", range(down[0], count))]
              if down and down[0] > 0 else [("whole clip", range(count))])
    for what, indices in phases:
        low = deepest(indices)
        log("              lowest joint %s: %+.3f m (%s) at %.3f s"
            % (what.ljust(26), low[0], low[1], low[2]))

    worst = deepest(range(count))
    limit = FLOOR_LIMIT[clip]
    log("              deepest anywhere %+.3f m against a %+.3f m limit — %s"
        % (worst[0], limit, "ok" if worst[0] >= limit else "TOO DEEP"))
    if worst[0] < limit:
        raise SystemExit(
            "%s: %s reaches %+.3f m at %.3f s, past this clip's %+.3f m floor "
            "limit — VERTICAL_RISE_KEPT[%r] = %.2f is wrong for it"
            % (clip, worst[1], worst[0], worst[2], limit, clip,
               VERTICAL_RISE_KEPT.get(clip, 1.0)))
    return {"lowest": worst[0], "lowest_bone": worst[1], "lowest_at": worst[2],
            "hand_min": hands[lowest_hand], "hand_min_at": seconds[lowest_hand],
            "plant": plant}


def lock_root_motion(action, clip):
    """Lock the Hips' horizontal travel in place, and apply the vertical rule.

    Index 1 of the Hips `location` curve is up: the Hips bone is vertical in the
    rest pose, so its local Y is world Z, and pose translation is applied in the
    bone's *rest* basis — which is why this holds no matter how the rotation
    keys turn the pelvis.

    The two horizontal axes are locked to their first key on every clip. The up
    axis is scaled toward that same first key by whatever fraction of the rise
    VERTICAL_RISE_KEPT says to keep, so `0.0` is the flat clamp, `1.0` is
    untouched, and anything between is a rise the animation and the physics body
    share. Only keys *above* the first one move: the downward half of a jump —
    the landing absorb, the ground roll — is motion the physics body is standing
    on the floor for and cannot produce, so it is never scaled away.
    """
    curves = bone_curves(action, HIPS, "location")
    if len(curves) != 3:
        raise SystemExit("%s: Hips has %d location curves, wanted 3" % (clip, len(curves)))
    first = [c.keyframe_points[0].co.y for c in curves]

    for axis in (0, 2):
        for kp in curves[axis].keyframe_points:
            kp.co.y = first[axis]
        linearise(curves[axis])

    kept = VERTICAL_RISE_KEPT.get(clip, 1.0)
    pulled = 0
    if kept < 1.0:
        for kp in curves[1].keyframe_points:
            if kp.co.y > first[1]:
                kp.co.y = first[1] + (kp.co.y - first[1]) * kept
                pulled += 1
        linearise(curves[1])
    return pulled


# ---------------------------------------------------------------------------
# 6. Facing
# ---------------------------------------------------------------------------

def clip_facing(arm, action, reference):
    """The clip's facing at its reference moment, relative to nothing yet.

    Forward kinematics, not a Euler angle off the root quaternion: the Hips bone
    carries the rig's own rest orientation and its "yaw" is not the body's. The
    line between the two hip joints is the one measurement that stays put while
    the arms and torso animate.
    """
    frames, tracks = sample_bones(arm, action, HIP_JOINTS)
    left, right = tracks[HIP_JOINTS[0]], tracks[HIP_JOINTS[1]]
    yaws = [math.atan2(right[i].y - left[i].y, right[i].x - left[i].x)
            for i in range(len(frames))]
    # The rest pose sits at -176°, so raw yaws straddle the ±180° seam and a
    # plain min/max of them would read as a 360° swing. Everything is reported
    # relative to the rest facing instead.
    relative = [wrap_pi(y - rest_facing(arm)) for y in yaws]
    if reference is LOOP_MEAN:
        # A circular mean, for the same reason.
        x = sum(math.cos(y) for y in yaws)
        z = sum(math.sin(y) for y in yaws)
        return math.atan2(z, x), min(relative), max(relative)
    index = min(len(yaws) - 1, int(round(reference * FPS)))
    return yaws[index], min(relative), max(relative)


def rotate_hips_yaw(action, clip, angle):
    """Turn the whole clip by `angle` about world up, at the Hips.

    The correction is applied inside the Hips bone's own space: the bone is
    vertical in rest, so a rotation about its local +Y is a rotation about world
    +Z, and pre-multiplying it onto each key rotates the body without disturbing
    what the key was already saying. Quaternion multiplication is linear in the
    components, so the four curves can be rewritten key for key.
    """
    curves = bone_curves(action, HIPS, "rotation_quaternion")
    if len(curves) != 4:
        raise SystemExit("%s: Hips has %d rotation curves, wanted 4" % (clip, len(curves)))
    times = [key_frames(c) for c in curves]
    if any(t != times[0] for t in times[1:]):
        raise SystemExit("%s: Hips rotation curves are keyed at different times" % clip)

    correction = Quaternion(Vector((0.0, 1.0, 0.0)), angle)
    for i in range(len(times[0])):
        turned = correction @ Quaternion([c.keyframe_points[i].co.y for c in curves])
        for axis in range(4):
            curves[axis].keyframe_points[i].co.y = turned[axis]
    for curve in curves:
        linearise(curve)


def align_facing(arm, actions, references):
    """Make every clip point where the rest pose points, at its reference moment."""
    reference_yaw = rest_facing(arm)
    log("  rest pose faces %+.2f° (yaw of the left-hip -> right-hip line)"
        % math.degrees(reference_yaw))
    results = []
    for clip, action in actions.items():
        reference = references[clip]
        before, low, high = clip_facing(arm, action, reference)
        offset = wrap_pi(before - reference_yaw)
        rotate_hips_yaw(action, clip, -offset)
        after, low2, high2 = clip_facing(arm, action, reference)
        residual = math.degrees(wrap_pi(after - reference_yaw))
        if abs(residual) > 1.0:
            raise SystemExit("%s: still %+.2f° off the rest facing after alignment"
                             % (clip, residual))
        results.append((clip, math.degrees(offset), residual,
                        math.degrees(high2 - low2)))
        log("  %-11s %-9s was %+7.2f°, turned by %+7.2f°, now %+5.2f° "
            "(clip turns through %.0f° of real motion)"
            % (clip, "mean" if reference is LOOP_MEAN else "@%.2fs" % reference,
               math.degrees(offset), -math.degrees(offset), residual,
               math.degrees(high2 - low2)))
    return results


# ---------------------------------------------------------------------------
# 7. Loops and CrouchIdle
# ---------------------------------------------------------------------------

def trim_loop_tail(action, clip):
    """Drop the cycle's duplicate final frame.

    Some curves carry sub-frame keys (Mixamo hands a few joints three keys per
    frame), so this removes every key on the final frame rather than "the last
    key", and the export range is set from the frame numbers, not from what is
    left of the curves.
    """
    first, last = action_frame_span(action)
    removed = 0
    for fcurve in iter_fcurves(action):
        for kp in reversed(list(fcurve.keyframe_points)):
            if kp.co.x > last - 0.5 and len(fcurve.keyframe_points) > 1:
                fcurve.keyframe_points.remove(kp)
                removed += 1
        fcurve.update()
    return first, last - 1, removed


def synth_crouch_idle(arm, actions, source_clip, frame, hold):
    """A held crouch, built from the one frame of CrouchWalk with both feet down.

    Sampled after the root motion is locked, so the hips are already where the
    locked clip puts them and blending CrouchIdle against CrouchWalk does not
    shift the body.
    """
    source = actions[source_clip]
    action = bpy.data.actions.new("CrouchIdle")
    layer = action.layers.new("Layer")
    strip = layer.strips.new(type='KEYFRAME')
    slot = action.slots.new(id_type='OBJECT', name=arm.name)
    bag = strip.channelbags.new(slot)

    curves = 0
    for fcurve in iter_fcurves(source):
        value = fcurve.evaluate(frame)
        new = bag.fcurves.new(fcurve.data_path, index=fcurve.array_index)
        new.keyframe_points.insert(1.0, value)
        new.keyframe_points.insert(1.0 + hold, value)
        linearise(new)
        curves += 1

    use_action(arm, action)
    bpy.context.scene.frame_set(1)
    hips = (arm.matrix_world @ arm.pose.bones[HIPS].matrix).translation
    ground = arm.data.bones["LeftToeBase"].head_local.z
    toes = [(arm.matrix_world @ arm.pose.bones[b].matrix).translation
            for b in ("LeftToeBase", "RightToeBase")]
    log("  CrouchIdle from %s frame %d (t=%.3f): %d curves, 2 keys %.2f s apart"
        % (source_clip, frame, (frame - 1) / FPS, curves, hold / FPS))
    log("             hips %.3f m, toes %+.3f/%+.3f above rest, %.3f m apart"
        % (hips.z, toes[0].z - ground, toes[1].z - ground,
           math.hypot(toes[0].x - toes[1].x, toes[0].y - toes[1].y)))
    return action


# ---------------------------------------------------------------------------
# 8. Material
# ---------------------------------------------------------------------------

def build_material(mesh, emission):
    """One Principled BSDF over a 1024² base colour, rebuilt from scratch.

    The FBX importer leaves a Normal Map node wired into the BSDF with no image
    behind it, which is the kind of thing that exports as a silently broken
    normal texture, so the tree is cleared rather than edited.
    """
    if len(mesh.data.materials) != 1:
        raise SystemExit("mesh has %d materials, wanted 1" % len(mesh.data.materials))
    material = mesh.data.materials[0]

    # The image is taken from the material that survived consolidation rather
    # than from bpy.data, so this cannot pick up one of the other seven copies.
    found = [n.image for n in material.node_tree.nodes
             if n.type == 'TEX_IMAGE' and n.image is not None]
    if len(found) != 1:
        raise SystemExit("%s has %d image textures, wanted 1" % (material.name, len(found)))
    material.name = "gub"
    image = found[0]
    before = tuple(image.size)
    image.name = "basecolor"
    # The glTF exporter names an embedded image after the *basename of its
    # filepath* when that ends in .png/.jpg, and only falls back to the
    # datablock name — and Godot extracts an embedded texture as
    # `<glb name>_<glTF image name>`. Without this line the file that lands in
    # art/generated/ is called `gub_cartoon+monster+3d+model_basecolor.jpg`.
    # The extension also decides the exported mime type, so it stays .jpg.
    image.filepath_raw = "//basecolor.jpg"
    if max(image.size) > TEXTURE_EDGE:
        image.scale(TEXTURE_EDGE, TEXTURE_EDGE)

    tree = material.node_tree
    tree.nodes.clear()
    texture = tree.nodes.new("ShaderNodeTexImage")
    texture.image = image
    texture.location = (-400, 0)
    bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (0, 0)
    output = tree.nodes.new("ShaderNodeOutputMaterial")
    output.location = (300, 0)
    tree.links.new(texture.outputs["Color"], bsdf.inputs["Base Color"])
    tree.links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    bsdf.inputs["Roughness"].default_value = ROUGHNESS
    bsdf.inputs["Metallic"].default_value = METALLIC
    bsdf.inputs["Emission Strength"].default_value = emission
    if emission > 0.0:
        tree.links.new(texture.outputs["Color"], bsdf.inputs["Emission Color"])
    # Wiring it at strength 0 would still export an emissiveTexture with a black
    # emissiveFactor, which Godot turns into an enabled-but-black emission on the
    # material: a second texture sample per fragment that can never do anything.
    # At 0 the socket is left alone instead, so `--emission 0` really is a plain
    # base-colour PBR material rather than a lit one multiplied by nothing.

    log("  material '%s': base colour '%s' %dx%d -> %dx%d %s, roughness %.2f, "
        "metallic %.2f, emission %.2f%s"
        % (material.name, image.name, before[0], before[1], image.size[0],
           image.size[1], image.file_format, ROUGHNESS, METALLIC, emission,
           "" if emission > 0.0 else " (not wired)"))


# ---------------------------------------------------------------------------
# 9. Export
# ---------------------------------------------------------------------------

def stage_nla(arm, actions, ranges, loops):
    """One NLA track per clip, named after the clip (plus LOOP_SUFFIX if it loops).

    NLA_TRACKS export mode writes one glTF animation per track and takes the
    animation's name from the track, which is the only way to be sure the clip
    names in Godot are the ones in the table above. The strip range is set from
    the frame numbers this script decided on, so a trimmed cycle exports one
    frame short even though a sub-frame key may survive past its end.
    """
    arm.animation_data.action = None
    for track in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(track)
    for clip, action in actions.items():
        first, last = ranges[clip]
        name = clip + LOOP_SUFFIX if clip in loops else clip
        track = arm.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, int(first), action)
        if len(action.slots):
            strip.action_slot = action.slots[0]
        strip.action_frame_start = first
        strip.action_frame_end = last
        strip.frame_start_ui = first
        strip.frame_end_ui = last
        log("  track %-16s frames %d..%d (%.4f s)"
            % (name, first, last, (last - first) / FPS))


def export_glb(path):
    """GLB, Y-up, skinned, one animation per NLA track.

    `export_def_bones=False` keeps every bone including the `*_End` leaves: the
    ragdoll builder uses HeadTop_End and the toe ends as capsule tips, and
    `held_spear.gd` hangs off RightHand. `export_optimize_animation_size` drops
    channels that never change, which is most of the fingers on most clips
    (D-023). Sampling is forced so what Godot gets is what Blender evaluates,
    sub-frame keys and all.
    """
    if not os.path.isdir(os.path.dirname(path)):
        os.makedirs(os.path.dirname(path))
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        use_selection=False,
        use_visible=False,
        export_yup=True,
        export_apply=True,
        export_texcoords=True,
        export_normals=True,
        export_tangents=False,
        export_materials='EXPORT',
        export_image_format='AUTO',
        export_jpeg_quality=85,
        export_skins=True,
        export_def_bones=False,
        export_leaf_bone=False,
        export_influence_nb=4,
        export_all_influences=False,
        export_rest_position_armature=True,
        export_animations=True,
        export_animation_mode='NLA_TRACKS',
        export_force_sampling=True,
        export_frame_range=False,
        export_frame_step=1,
        export_anim_slide_to_zero=True,
        export_optimize_animation_size=True,
        export_optimize_animation_keep_anim_armature=True,
        export_bake_animation=False,
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_morph=False,
    )
    return os.path.getsize(path)


# ---------------------------------------------------------------------------

def parse_args(argv):
    """Read our own arguments from Blender's command line.

    Blender stops parsing at `--` and hands the rest over. `build_gub.sh` adds
    a `--` of its own so that both `build_gub.sh --emission 0.25` and the form
    §7 of the design spec writes, `build_gub.sh -- --emission 0.25`, work; bare
    separators are skipped here rather than counted.

    The default is the value that shipped: 0.15, picked by rendering the night
    island and the firing range with it and without it and measuring the Gub
    against what it stands in. Unlit undergrowth at 20 m went from 1.04× the
    background's luminance to 1.28× (readable as a character rather than a
    smudge), while a torch-lit Gub gained only a sixth of its brightness and
    clipped no pixels — it is still shaded, not a lamp. So a plain `build_gub.sh`
    reproduces the asset in the tree, and any other number is somebody
    deliberately re-judging night readability.
    """
    emission = 0.15
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    i = 0
    while i < len(argv):
        if argv[i] == "--":
            i += 1
        elif argv[i] == "--emission" and i + 1 < len(argv):
            emission = float(argv[i + 1])
            i += 2
        else:
            raise SystemExit("usage: build_gub.py [-- --emission FLOAT] (got %r)" % argv[i])
    return emission


def check_tables():
    """Catch a clip renamed in CLIPS but not in the tables that key off it.

    Both tables are looked up with `.get`, so a stale name would silently mean
    "no rule" instead of failing, and the rule it was meant to express would be
    missing from the shipped asset with nothing in the log to say so.
    """
    names = set(clip for _f, clip, _l, _r in CLIPS)
    for table, what in ((VERTICAL_RISE_KEPT, "VERTICAL_RISE_KEPT"),
                        (FLOOR_LIMIT, "FLOOR_LIMIT")):
        unknown = sorted(set(table) - names)
        if unknown:
            raise SystemExit("%s names clips that are not built: %s"
                             % (what, ", ".join(unknown)))
    missing = sorted(set(VERTICAL_RISE_KEPT) - set(FLOOR_LIMIT))
    if missing:
        raise SystemExit("no FLOOR_LIMIT for %s, so its vertical rule would go "
                         "unchecked" % ", ".join(missing))


def main():
    started = time.time()
    check_tables()
    emission = parse_args(list(sys.argv))
    log("=== build_gub  Blender %s, %d source files, target %.2f m, emission %.2f"
        % (bpy.app.version_string, len(CLIPS), TARGET_HEIGHT, emission))

    log("\n-- import")
    imported = import_sources()
    assert_same_character(imported)
    arm, mesh, actions = consolidate(imported)

    log("\n-- names")
    strip_bone_prefix(arm, mesh, actions)

    log("\n-- scale")
    scale_to_height(arm, mesh, actions)
    report_rest_pose(arm, mesh)

    log("\n-- authored motion (measured before anything is locked or clamped)")
    rows = [measure_clip(arm, actions[clip], clip) for _f, clip, _l, _r in CLIPS]
    report_measurements(rows)

    log("\n-- root motion")
    ground = {}
    for _f, clip, _loop, _ref in CLIPS:
        pulled = lock_root_motion(actions[clip], clip)
        row = next(r for r in rows if r["clip"] == clip)
        note = ""
        if clip in VERTICAL_RISE_KEPT:
            kept = VERTICAL_RISE_KEPT[clip]
            note = (", %.0f%% of its %.3f m rise kept"
                    % (kept * 100.0, row["hips_max"] - row["hips_first"]))
            if pulled:
                note += " (%d up keys pulled toward %.3f m)" % (pulled, row["hips_first"])
        log("  %-11s locked %.3f m of travel (%.3f m/s over %.3f s)%s"
            % (clip, row["travel"], row["speed"], row["duration"], note))
        if clip in VERTICAL_RISE_KEPT:
            ground[clip] = check_ground(arm, actions[clip], clip)

    log("\n-- CrouchIdle")
    source_clip, source_frame, hold = CROUCH_IDLE
    actions["CrouchIdle"] = synth_crouch_idle(arm, actions, source_clip, source_frame, hold)

    log("\n-- facing")
    references = dict((clip, ref) for _f, clip, _l, ref in CLIPS)
    references["CrouchIdle"] = LOOP_MEAN
    align_facing(arm, actions, references)

    log("\n-- loops")
    loops = set(clip for _f, clip, loop, _r in CLIPS if loop)
    loops.add("CrouchIdle")
    ranges = {}
    for clip, action in actions.items():
        first, last = action_frame_span(action)
        if clip in loops and clip != "CrouchIdle" and DROP_LOOP_TAIL:
            first, last, removed = trim_loop_tail(action, clip)
            log("  %-11s loops: dropped %d keys on frame %d, now %d..%d (%.4f s)"
                % (clip, removed, last + 1, first, last, (last - first) / FPS))
        else:
            log("  %-11s %s: frames %d..%d (%.4f s)"
                % (clip, "loops" if clip in loops else "one-shot", first, last,
                   (last - first) / FPS))
        ranges[clip] = (first, last)

    log("\n-- material")
    build_material(mesh, emission)

    log("\n-- export")
    log("  %d clips loop; they carry '%s' in the GLB and lose it on import"
        % (len(loops), LOOP_SUFFIX))
    stage_nla(arm, actions, ranges, loops)
    size = export_glb(OUT_PATH)
    log("  wrote %s  %.2f MB in %.1f s"
        % (os.path.relpath(OUT_PATH, REPO).replace("\\", "/"), size / 1e6,
           time.time() - started))

    log("\n=== for gub.gd: authored ground speeds (m/s at %.2f m)" % TARGET_HEIGHT)
    for name, clip in (("AUTHORED_WALK", "Walk"), ("AUTHORED_RUN", "Run"),
                       ("AUTHORED_CROUCH_WALK", "CrouchWalk")):
        row = next(r for r in rows if r["clip"] == clip)
        log("    %-22s := %.3f   # %s: %.3f m over %.3f s"
            % (name, row["speed"], clip, row["travel"], row["duration"]))
    # A moment that never happens in a clip prints as "n/a" rather than
    # crashing the summary after the asset has already been written.
    def at(row, key):
        return "%.3f" % row[key] if row[key] is not None else "  n/a"

    log("=== for gub_animator.gd: the moments its windows are cut from")
    for clip in ("JumpOne", "JumpTwo"):
        row = next(r for r in rows if r["clip"] == clip)
        log("    %-11s length %.3f  feet leave %s  apex %.3f  feet touch %s%s"
            % (clip, row["duration"], at(row, "leave_wide"), row["hips_apex"],
               at(row, "land_wide"),
               "  roll %s..%s, up %s" % (at(row, "low_from"), at(row, "low_to"),
                                         at(row, "stood_up"))
               if row["low_from"] is not None else ""))
        # The same clip after the vertical rule, which is the one the game plays:
        # the hips apex is the APEX the airborne scrub interpolates through, and
        # the hand plant is where the landing has to have happened by.
        rule = ground[clip]
        kept = VERTICAL_RISE_KEPT[clip]
        log("    %-11s rise kept %3.0f%%, hips %s at the %.3f s apex, hands plant "
            "%s, lowest joint %+.3f m at %.3f s"
            % ("", kept * 100.0,
               "reach %.3f m" % row["hips_max"] if kept > 0.0
               else "pinned at %.3f m" % row["hips_first"],
               row["hips_apex"],
               "%.3f..%.3f" % rule["plant"] if rule["plant"] else "never",
               rule["lowest"], rule["lowest_at"]))
    row = next(r for r in rows if r["clip"] == "Slide")
    log("    %-11s length %.3f  low %s..%s (hips %.3f m)  standing again %s"
        % ("Slide", row["duration"], at(row, "low_from"), at(row, "low_to"),
           row["hips_min"], at(row, "stood_up")))
    row = next(r for r in rows if r["clip"] == "Throw")
    log("    %-11s length %.3f  release %.3f (right hand at peak %.2f m/s), "
        "furthest forward %.3f"
        % ("Throw", row["duration"], row["hand_peak_at"], row["hand_peak"],
           row["hand_reach_at"]))
    log("\ndone.")


if __name__ == "__main__":
    main()
