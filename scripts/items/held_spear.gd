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

const HAND_BONE := "hand.R"

## Where the shaft sits in the hand. The mesh's origin is at the butt of the
## spear and it runs along its own +Y, which the hand bone happens to point
## roughly upward, so an identity grip leaves the Gub holding the very end of a
## vertical pole. Sliding it 0.58 back puts the fist just under halfway up the
## shaft; the small tilt leans the tip back off the head. Tuned by eye against
## the idle and run cycles with `tools/preview_grip.tscn`.
const GRIP_OFFSET := Vector3(0.0, -0.58, 0.02)
const GRIP_ROTATION := Vector3(16.0, 0.0, -8.0)

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
