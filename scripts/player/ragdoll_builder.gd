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
## Not every bone: the rig has 29, and toes, heels and the finger-ish spine tip
## contribute nothing to how a corpse falls while costing a solver island each.
## Thirteen bodies is enough for a Gub to tumble convincingly.
##
##   tip     — the bone whose head marks the end of this one, giving length and
##             direction. Capsules are built along that line.
##   girth   — capsule radius as a fraction of length. The Gub is a blob with
##             stick limbs, so the torso is deliberately much fatter than
##             anatomical proportions would suggest.
##   mass    — kilograms. The head and torso carry most of it, which is what
##             makes the body flop rather than cartwheel.
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
const SEGMENTS: Array[Dictionary] = [
	{"bone": "spine",       "tip": "spine.002", "girth": 0.52, "mass": 9.0, "swing": 45.0, "twist": 30.0},
	{"bone": "spine.002",   "tip": "spine.004", "girth": 0.58, "mass": 8.0, "swing": 40.0, "twist": 26.0},
	{"bone": "spine.004",   "tip": "spine.006", "girth": 0.50, "mass": 5.0, "swing": 50.0, "twist": 40.0},
	{"bone": "upper_arm.L", "tip": "forearm.L", "girth": 0.26, "mass": 1.3, "swing": 95.0, "twist": 60.0},
	{"bone": "forearm.L",   "tip": "hand.L",    "girth": 0.22, "mass": 0.9, "swing": 105.0, "twist": 35.0},
	{"bone": "upper_arm.R", "tip": "forearm.R", "girth": 0.26, "mass": 1.3, "swing": 95.0, "twist": 60.0},
	{"bone": "forearm.R",   "tip": "hand.R",    "girth": 0.22, "mass": 0.9, "swing": 105.0, "twist": 35.0},
	{"bone": "thigh.L",     "tip": "shin.L",    "girth": 0.28, "mass": 2.6, "swing": 85.0, "twist": 40.0},
	{"bone": "shin.L",      "tip": "foot.L",    "girth": 0.24, "mass": 1.8, "swing": 105.0, "twist": 25.0},
	{"bone": "foot.L",      "tip": "toe.L",     "girth": 0.34, "mass": 0.8, "swing": 50.0, "twist": 25.0},
	{"bone": "thigh.R",     "tip": "shin.R",    "girth": 0.28, "mass": 2.6, "swing": 85.0, "twist": 40.0},
	{"bone": "shin.R",      "tip": "foot.R",    "girth": 0.24, "mass": 1.8, "swing": 105.0, "twist": 25.0},
	{"bone": "foot.R",      "tip": "toe.R",     "girth": 0.34, "mass": 0.8, "swing": 50.0, "twist": 25.0},
]

const LAYER_WORLD := 1
const LAYER_RAGDOLL := 16

const MIN_RADIUS := 0.035
const MAX_RADIUS := 0.30


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
		# Swept collision. A shin capsule is 4 cm across and a thrown corpse
		# arrives at 9 m/s, which is 15 cm per physics tick — nearly four times
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
