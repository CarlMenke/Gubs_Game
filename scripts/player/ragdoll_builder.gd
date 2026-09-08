class_name RagdollBuilder
extends RefCounted
## Builds a physical-bone skeleton for the Gub rig at runtime.
##
## The alternative is the editor's "Create physical skeleton", which writes ~13
## `PhysicalBone3D` nodes with hand-fitted capsules straight into a `.tscn`.
## That file cannot be reviewed in a diff, cannot carry a comment explaining why
## a shin is 0.3 units wide, and silently goes stale the moment `Gub.glb` is
## re-imported with a different rest pose. Deriving it from the skeleton's own
## rest pose instead means it is always correct by construction.
##
## See docs/DECISIONS.md D-006.

## Which bones get a rigid body, and what each one is like.
##
## Not every bone: the rig has 49, and toes, fingers, shoulders and the
## intermediate spine links contribute nothing to how a corpse *falls* while
## costing a solver island each. Thirteen bodies is enough for a Gub to tumble
## convincingly. They are not enough for it to *deform* convincingly — an
## undriven link keeps the local pose it died with while the bodies either side
## of it are driven by physics, and the skin across that ring pays for the
## difference. See the note under the neck spans below.
##
##   tip     — the bone whose head marks the end of this one, giving length and
##             direction. Capsules are built along that line.
##   girth   — capsule radius as a fraction of length. Values **above 1.0 are
##             normal here**: the Gub is a pear-shaped blob whose pelvis and
##             chest bones are only 18 and 24 cm long inside a body 50 cm wide
##             and 75 cm deep, so those two capsules are wider than they are
##             long. `CapsuleShape3D.height` counts the caps, so a segment whose
##             radius exceeds half its length is simply a sphere — which is the
##             right shape for this character's torso.
##   mass    — kilograms. The head and torso carry two thirds of it, which is
##             what makes the body flop rather than cartwheel.
##   swing   — cone half-angle, degrees: how far this bone may fold away from
##             the one above it. An elbow and a knee need a *lot* of this.
##   twist   — how far it may rotate about its own length.
##
## These spans have to cover the whole range a falling body actually reaches,
## because a cone-twist joint that is driven past its limit does not clamp —
## Godot's limit solver pushes back hard enough to add energy, and a chain of
## thirteen of them turns that into an explosion within a few ticks. The corpse
## survived every drop test until it first touched the ground, at which point
## the legs folded past the old 44-degree knee and the whole ragdoll detonated.
## See D-013. When in doubt, open a joint up: a corpse that bends too freely
## looks rubbery, which is the intended look anyway, whereas one that bends too
## little does not look stiff — it explodes.
##
## The girths are measured, not guessed. Every skinned vertex was assigned to
## the segment that dominates its weights and its distance from that segment's
## axis recorded. For the **limbs** each radius sits between the median and the
## 90th percentile of that distance — at the p90 where the limb really is round,
## and down near the median for the hand and the foot, whose splayed fingers and
## toes drag the p90 out to twice the median and would otherwise inflate a 9 cm
## shin-and-ankle capsule to 18. For the **torso and head** the radius is fitted
## to the mesh's own extent instead, for a reason worth knowing:
##
##   segment              length   mesh radius p50/p90/max   capsule radius
##   Hips -> Spine1        0.183     0.214 / 0.337 / 0.357       0.330
##   Spine1 -> Neck        0.239     0.225 / 0.259 / 0.289       0.301
##   Head -> HeadTop_End   0.368     0.155 / 0.207 / 0.246       0.320
##   Arm -> ForeArm        0.156     0.073 / 0.087 / 0.106       0.084
##   ForeArm -> Hand       0.287     0.086 / 0.183 / 0.213       0.089
##   UpLeg -> Leg          0.268     0.021 / 0.051 / 0.081       0.056
##   Leg -> Foot           0.237     0.024 / 0.043 / 0.046       0.045
##   Foot -> ToeBase       0.256     0.092 / 0.181 / 0.213       0.090
##
## The first pass fitted all three torso bodies near their p90 (0.26 / 0.25 /
## 0.26) and the corpse came out as a ball: `--debug-collisions` showed a
## cluster of capsules visibly smaller than the mesh, with essentially nothing
## underneath the big belly, and a settled corpse only 0.59 m across for a
## 1.80 m character. A p90 fit is the right call for a cylinder. It is the wrong
## call for three overlapping blobs that between them *are* the character: the
## Gub's body is 0.47 m wide and 0.75 m deep, its head is 0.5 m of skull on a
## 0.37 m bone, and a sphere sized to hug the average vertex of a blob that
## wide leaves the rest of the blob outside the physics entirely — so the mesh
## rests on nothing, and the two halves of the torso pass through each other.
## These three are fitted to the mesh's outer extent instead:
##
##   pelvis 0.33 — the belly's own half-depth (0.357 max, 0.337 p90). It is
##                 wider than the 0.24 m half-width, so a corpse on its side
##                 floats a couple of centimetres; that is the right way round,
##                 because the alternative (fit the width) buries the belly.
##   chest  0.30 — the mesh's max around that axis is 0.289; rounded up so the
##                 chest and pelvis spheres overlap rather than leaving a waist
##                 gap the mesh can crease into.
##   head   0.32 — the head runs 0.77 m along its bone (antennae included) and
##                 is 0.25 m from the axis at its widest, so the sphere is sized
##                 to fill the skull rather than to hug the average vertex. It is
##                 also what the settled corpse rests its head on.
##
## `MAX_RADIUS` had to come up from 0.30 for these to take effect at all — at
## 0.30 the pelvis and the head were being silently clamped.
##
## The neck span is the other half of the same fix, and it has a hard floor.
## At the first pass's 60 degree swing and 50 degrees of twist the head folded
## into the chest on the first bounce and stayed there. Tightening it works —
## with 35/25 a settled corpse holds its head 0.325 m from its chest instead of
## 0.289 (0.42 at rest) — but **below 30 degrees the ragdoll detonates**, and
## that is D-013's warning
## arriving on schedule rather than a solver mystery: the spans have to cover the
## poses a Gub actually dies in, and those poses already exceed them. Measured
## with this file's own frame maths — the swing the *animation* puts into each
## joint, worst sample per clip:
##
##   joint    Idle  Walk  Run  Crouch  Slide  JumpOne  JumpTwo  Throw   span
##   Spine1     22    22   25      14     31       49       23     11     45
##   Head       38    23   69      34     40       39       71     16     35
##   Arm        67    56   63      60    150       77      173    126     95
##   ForeArm    ..    ..   ..      ..     ..       ..       ..    123    105
##   UpLeg      66    77  127     124     124     125      143     79     90
##   Foot       24    87   52      85      71       61      102    117     55
##
## A corpse is snapped to the pose it died in, so every one of those numbers
## above a span is a joint that starts *outside* its limit. Soft joints
## (softness 0.92, bias 0.25 below) absorb that and relax it over a few ticks —
## which is why the limbs survive being 60 degrees past their span — but the
## margin is finite: a 30 degree neck starting 8 degrees out in `Idle` alone was
## enough for `ragdoll_stability` to hit 137 m/s by tick 43. Stiffening the
## joints instead (softness 0.70, bias 0.50) explodes it faster. So: 35 degrees
## on the neck, 45 on the spine, and the limbs left wide open where the
## animation genuinely swings them.
##
## Two things this table was *blamed* for and did not cause. The report that a
## corpse's "eyeball meshes end up outside the head surface" with "black
## self-intersecting seams" was the corpse's material going transparent at
## spawn and so stopping writing depth — see `gub_ragdoll.gd`; the bodies were
## always where they should be. And a settled spread of 0.59 m for a 1.80 m
## character read as a ball only because that figure is `ragdoll_stability`'s
## radius from the centroid, not a length: a prone Gub's thirteen body centres
## occupy 0.70 x 0.29 x 0.89 m, which is a body lying down, and a radius much
## above 0.75 is geometrically impossible for this rig.
##
## What is genuinely still imperfect: at 35 degrees the head can tip far enough
## to push the *skin* of a skull that is a third of the character into the skin
## of the torso, and the arms — which the `Idle` guard holds up beside the head —
## are pressed into it on landing. Linear blend skinning on Mixamo's stock
## weights creases hard at the neck and shoulder rings when that happens (D-023
## measured those rings as the worst in the rig). Resetting the undriven links
## (Spine, Spine2, Neck, the shoulders) to their rest pose at death was tried to
## halve that shear and rejected: it did not visibly help and it costs the
## corpse the pose it died in. The real fix is more bodies, so the neck and the
## shoulders are driven rather than frozen — which is a change to this table's
## size, not to its numbers.
const SEGMENTS: Array[Dictionary] = [
	{"bone": "Hips",         "tip": "Spine1",      "girth": 1.80, "mass": 9.0, "swing": 45.0, "twist": 30.0},
	{"bone": "Spine1",       "tip": "Neck",        "girth": 1.26, "mass": 8.0, "swing": 45.0, "twist": 35.0},
	{"bone": "Head",         "tip": "HeadTop_End", "girth": 0.87, "mass": 9.0, "swing": 35.0, "twist": 25.0},
	{"bone": "LeftArm",      "tip": "LeftForeArm", "girth": 0.54, "mass": 1.2, "swing": 95.0, "twist": 60.0},
	{"bone": "LeftForeArm",  "tip": "LeftHand",    "girth": 0.31, "mass": 1.4, "swing": 105.0, "twist": 40.0},
	{"bone": "RightArm",     "tip": "RightForeArm", "girth": 0.54, "mass": 1.2, "swing": 95.0, "twist": 60.0},
	{"bone": "RightForeArm", "tip": "RightHand",   "girth": 0.31, "mass": 1.4, "swing": 105.0, "twist": 40.0},
	{"bone": "LeftUpLeg",    "tip": "LeftLeg",     "girth": 0.21, "mass": 1.6, "swing": 90.0, "twist": 45.0},
	{"bone": "LeftLeg",      "tip": "LeftFoot",    "girth": 0.19, "mass": 1.2, "swing": 105.0, "twist": 30.0},
	{"bone": "LeftFoot",     "tip": "LeftToeBase", "girth": 0.35, "mass": 1.1, "swing": 55.0, "twist": 30.0},
	{"bone": "RightUpLeg",   "tip": "RightLeg",    "girth": 0.21, "mass": 1.6, "swing": 90.0, "twist": 45.0},
	{"bone": "RightLeg",     "tip": "RightFoot",   "girth": 0.19, "mass": 1.2, "swing": 105.0, "twist": 30.0},
	{"bone": "RightFoot",    "tip": "RightToeBase", "girth": 0.35, "mass": 1.1, "swing": 55.0, "twist": 30.0},
]

const LAYER_WORLD := 1
const LAYER_RAGDOLL := 16

const MIN_RADIUS := 0.035
## Sized to sit *above* the fitted torso bodies (the widest is the pelvis at
## 0.330), not under them: at 0.30 this clamp was quietly shaving the pelvis and
## the head down to a cluster of capsules smaller than the mesh they carry.
## It is a guard against a typo in a girth, nothing more.
const MAX_RADIUS := 0.40


## Create a simulator full of physical bones under `skeleton` and return it.
## Nothing simulates until `physical_bones_start_simulation()` is called.
static func build(skeleton: Skeleton3D) -> PhysicalBoneSimulator3D:
	var simulator := PhysicalBoneSimulator3D.new()
	simulator.name = "Ragdoll"
	skeleton.add_child(simulator)

	for segment: Dictionary in SEGMENTS:
		var bone: int = skeleton.find_bone(segment["bone"])
		var tip: int = skeleton.find_bone(segment["tip"])
		if bone < 0 or tip < 0:
			push_warning("RagdollBuilder: rig has no %s -> %s"
				% [segment["bone"], segment["tip"]])
			continue
		var physical := _make_bone(skeleton, bone, tip, segment)
		simulator.add_child(physical)
		# Swept collision. A shin capsule is 9 cm across and a thrown corpse
		# arrives at 9 m/s, which is 15 cm per physics tick — over three times
		# its own radius. Discrete detection lets it land deep inside the
		# ground, and the shove that pushes it back out is what was punting
		# corpses into the sky.
		PhysicsServer3D.body_set_enable_continuous_collision_detection(
			physical.get_rid(), true)

	return simulator


static func _make_bone(skeleton: Skeleton3D, bone: int, tip: int,
		segment: Dictionary) -> PhysicalBone3D:
	var rest := skeleton.get_bone_global_rest(bone)
	var axis := skeleton.get_bone_global_rest(tip).origin - rest.origin
	var length := maxf(axis.length(), 0.02)
	var radius := clampf(length * float(segment["girth"]), MIN_RADIUS, MAX_RADIUS)

	var physical := PhysicalBone3D.new()
	physical.name = "PB_%s" % segment["bone"]
	physical.bone_name = segment["bone"]
	physical.mass = segment["mass"]
	physical.friction = 0.8
	physical.bounce = 0.0
	# Barely any damping. It is tempting to damp a ragdoll heavily to stop it
	# twitching, but overdo it and the corpse wades through treacle — at 1.6
	# angular damping this one was stiff enough to stay standing after death,
	# which is the single worst thing a ragdoll can do. Let gravity win, and
	# rely on `can_sleep` to stop the jitter once it has settled.
	physical.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	physical.linear_damp = 0.02
	physical.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	physical.angular_damp = 0.22
	physical.can_sleep = true

	# Ragdolls collide with the world and nothing else. They do not push living
	# Gubs around, they do not tangle with each other, and — because every bone
	# shares one layer that is not in its own mask — they do not self-collide,
	# which is the usual cause of a corpse exploding on the first frame.
	physical.collision_layer = LAYER_RAGDOLL
	physical.collision_mask = LAYER_WORLD

	# The body sits at the midpoint of the bone with its +Y running along it,
	# which is the axis a CapsuleShape3D is built around.
	var placement := Transform3D(_basis_along(axis / length),
		rest.origin + axis * 0.5)
	physical.transform = placement
	# Godot recovers the bone pose as `physical.global_transform * body_offset⁻¹`,
	# so the offset is exactly how the body sits relative to the bone at rest.
	physical.body_offset = rest.affine_inverse() * placement
	# The joint belongs at the *head* of the bone — the elbow, not the middle of
	# the forearm — which in body-local space is half a length down the Y axis.
	#
	# The basis matters as much as the origin. A cone-twist measures swing and
	# twist about its frame's local **X**, but the capsule (and so the bone) runs
	# along the body's local **Y**. Left as identity, the cone opened sideways
	# across the limb: "swing" then limited rotation about the bone and "twist"
	# limited the actual bend, so a knee folding on impact was read as twist and
	# checked against a 14-degree limit. Rotating the frame 90 degrees about Z
	# maps its X onto the body's Y, which points the cone down the limb where it
	# belongs.
	physical.joint_offset = Transform3D(
		Basis(Vector3(0.0, 0.0, 1.0), PI * 0.5), Vector3(0.0, -length * 0.5, 0.0))
	physical.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
	physical.set("joint_constraints/swing_span", segment["swing"])
	physical.set("joint_constraints/twist_span", segment["twist"])
	# Soft, slack joints: the Gub is a rubbery cartoon blob, not a skeleton.
	physical.set("joint_constraints/softness", 0.92)
	physical.set("joint_constraints/relaxation", 0.6)
	physical.set("joint_constraints/bias", 0.25)

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	# CapsuleShape3D.height counts the hemispherical caps, so it can never be
	# shorter than the sphere it would otherwise be.
	capsule.height = maxf(length, radius * 2.0 + 0.01)
	shape.shape = capsule
	physical.add_child(shape)

	return physical


## Orthonormal basis whose +Y runs along `up`.
static func _basis_along(up: Vector3) -> Basis:
	# Any reference vector works as long as it is not parallel to the bone.
	var reference := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var right := reference.cross(up).normalized()
	# The third column must be x cross y, not y cross x. Get it the wrong way
	# round and the basis is a reflection — determinant -1 — which still puts the
	# capsule along the bone and still *looks* right, so the corpse falls
	# correctly for about half a second. Then the mirrored joint frames start
	# fighting the solver and the limbs stretch away to infinity.
	var forward := right.cross(up).normalized()
	return Basis(right, up, forward)


## Move every body to where its bone currently is. Needed before simulation
## starts so the corpse begins in the pose the Gub died in rather than snapping
## to the rest pose first.
static func snap_to_pose(skeleton: Skeleton3D, simulator: PhysicalBoneSimulator3D) -> void:
	for child in simulator.get_children():
		var physical := child as PhysicalBone3D
		if physical == null:
			continue
		var bone := skeleton.find_bone(physical.bone_name)
		if bone < 0:
			continue
		physical.transform = skeleton.get_bone_global_pose(bone) * physical.body_offset
