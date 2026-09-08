class_name HeldSpear
extends Node3D
## The spear a Gub is carrying, pinned to the bone of its right hand.
##
## A Gub always has one visible unless it is in the air or on cooldown, because
## the spear is the whole read on whether an opponent is dangerous right now:
## seeing an empty hand across the clearing is how you know it is safe to
## approach. That makes this cosmetic node gameplay-critical, so it is driven
## straight off the same cooldown the throw checks rather than by its own timer.
##
## Attaching to the bone is done in code rather than by adding a
## `BoneAttachment3D` inside `gub.tscn`, because that would mean turning on
## editable children for the imported `.glb` and hand-writing a node into a
## subtree that a re-import can renumber.

const MODEL := preload("res://art/generated/spear.glb")

const HAND_BONE := "RightHand"

## Where the shaft sits in the fist.
##
## The spear mesh's origin is at the butt and it runs 1.236 m along its own +Y,
## so the whole grip is two things: which way that +Y points in the hand's frame
## (`GRIP_ROTATION`), and which point of the shaft is in the palm
## (`GRIP_OFFSET`, the butt's position in hand-local metres).
##
## `RightHand`'s local +Y runs up the arm and out through the fingers, +X across
## the palm toward the fingertips (they reach x = +0.22 in this cartoon mitten)
## and +Z is the palm normal. A shaft near local +Y is therefore a shaft along
## the forearm, which is why the rotation below is a small tilt off identity.
##
## **A near-vertical carry, decided in `Idle`.** The Gub's `Idle` is a hunched
## boxer's guard: the right fist is up beside a head that is thrust forward, and
## the head is 0.5 m of blob 0.25 m thick. The first pass aimed the tip
## forward-and-up (a 21 deg tilt off the forearm) and scored it against three
## small ellipsoids standing in for the body — which under-measured the Gub
## badly, and the shipped result ran the shaft in under the chin and out above
## the crown. So this pass scored candidates against the **real skinned mesh**:
## every head- and torso-weighted vertex, skinned at 27 poses spread over the
## six clips the spear is carried in, with the shaft's distance to the nearest
## one as the constraint.
## The target — chosen because `Idle` is the pose read across a clearing, and a
## Gub in a guard stance with a spear held upright reads as armed — is a shaft
## 75-85 deg above horizontal, leaning slightly forward and outward to the
## Gub's own right, away from the head. What the numbers below deliver:
##
##   clip        shaft elevation      lowest end   nearest skin
##   Idle        +81 to +86 deg         0.33 m        0.11 m
##   Walk        -42 to -14 deg         0.23 m        0.15 m
##   Run         -59 to -43 deg         0.15 m        0.26 m
##   CrouchWalk  +70 to +75 deg         0.59 m        0.19 m
##   CrouchIdle  +72 deg                0.59 m        0.19 m
##   Throw       -10 to +59 deg         0.43 m        0.06 m
##
## The mean `Idle` carry is 86 deg up and 53 deg round from forward toward the
## Gub's right: a near-vertical shaft leaning as much outward as forward.
## Nothing touches the skin anywhere; the tightest is the throw follow-through
## at 6 cm.
##
## `Walk` and `Run` still point the tip *down*, and that is not fixable with a
## rigid attachment: the hand's world orientation differs by more than 100 deg
## between a raised guard and a hanging arm, so a grip that stands the shaft up
## in one lays it over in the other. What was fixable is the tip ploughing the
## ground — it used to reach +0.01 m in `Walk` — and both ends now stay at least
## 0.15 m up in every ground clip.
##
## **`GRIP_OFFSET` is derived, not free.** It is
##
##     (-0.03, 0.06, -0.04) - 0.55 * 1.236 * shaft_direction
##
## where the first term is the point of the palm the shaft passes through and
## the second puts the fist 55% of the way up the shaft (which is what lifts the
## butt clear of the ground when the arm hangs in `Walk`). That palm point is
## deliberately *off* the wrist bone's axis, because a hand holds a stick in its
## palm rather than through its own bones: the `RightHand`-weighted skin spans
## x -0.083..0.085, z -0.065..0.065, y -0.025..0.103 in hand-local rest space,
## so 5 cm off the axis and 6 cm up toward the knuckles is inside the fist with
## room to spare — and moving the shaft those 5 cm is what takes it from 6 cm
## off the face to 11 cm. Change `GRIP_ROTATION` and recompute this, or the
## shaft stops passing through the hand.
##
## Swept with `tools/preview_grip.tscn` (which takes both vectors on the command
## line) at 2400x700 in all five clips, plus the `Throw` window 1.40-1.75.
const GRIP_OFFSET := Vector3(-0.206, -0.582, 0.097)
const GRIP_ROTATION := Vector3(-12.0, 0.0, -15.0)


var _attachment: BoneAttachment3D
var _model: Node3D


func attach_to(skeleton: Skeleton3D) -> bool:
	if skeleton == null or skeleton.find_bone(HAND_BONE) < 0:
		push_warning("HeldSpear: rig has no %s bone" % HAND_BONE)
		return false

	_attachment = BoneAttachment3D.new()
	_attachment.name = "SpearHand"
	_attachment.bone_name = HAND_BONE
	skeleton.add_child(_attachment)

	_model = MODEL.instantiate() as Node3D
	_attachment.add_child(_model)
	set_grip(GRIP_OFFSET, GRIP_ROTATION)
	return true


## Exposed so `tools/preview_grip.tscn` can sweep values without a rebuild;
## the constants above are what that sweep settled on.
func set_grip(offset: Vector3, rotation_degrees: Vector3) -> void:
	if _model == null:
		return
	_model.position = offset
	_model.rotation_degrees = rotation_degrees


## Hidden while the spear is in flight or regrowing. Kept as a visibility toggle
## rather than freeing and rebuilding, so throwing rapidly costs nothing.
func set_carried(carried: bool) -> void:
	if _model != null:
		_model.visible = carried


func is_carried() -> bool:
	return _model != null and _model.visible


## World transform of the spear tip, used as the spawn point for a throw so the
## projectile leaves the hand rather than the middle of the Gub.
func tip_transform() -> Transform3D:
	if _model == null:
		return global_transform
	return _model.global_transform
