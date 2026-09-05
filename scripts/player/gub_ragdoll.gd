class_name GubRagdoll
extends Node3D
## The corpse a Gub leaves behind. Cosmetic, local, and short-lived.
##
## Ragdolls are deliberately **not** replicated. Each client simulates its own,
## so two players will see the same corpse land slightly differently — which
## costs nothing, because by the time a Gub is a ragdoll it has stopped being
## part of the game. Replicating thirteen rigid bodies per death, at eight
## players and an instant-kill weapon, would be most of the bandwidth budget
## spent on something no one makes a decision from.
##
## Spawned by whoever saw the death; see `spawn_from`.

const MODEL := preload("res://art/generated/gub.glb")

## How long a corpse stays before it fades out, and how long the fade takes.
const LINGER := 9.0
const FADE := 1.6

## How much of the spear's speed the corpse leaves with.
##
## A spear flies at 42 m/s and a Gub's thirteen bodies weigh about 38 kg between
## them, so the physically honest answer is "almost none of it" — the Gub would
## twitch and drop where it stood. That is the wrong answer twice over. A spear
## that lands is an instant kill, so the corpse's flight is the *entire*
## feedback for the most important event in the game, and it has to be legible
## from across the arena. And a Gub is a cartoon, so being knocked off your feet
## by a thrown stick is the read everyone already expects.
##
## At 0.15, a flat hit sends the body off at about 6 m/s — knocked off its feet
## and thrown a few metres, which is the read. Higher was tried and is worse for
## a reason worth knowing: above about 0.2 the corpse arrives at the ground fast
## enough that the contact starts amplifying, and it gets punted into the sky
## rather than tumbling along it.
const IMPACT_TRANSFER := 0.15
## The struck bone takes well over its share and the rest take less, which is
## what makes a leg shot cartwheel the Gub while a chest shot launches it flat.
const STRUCK_SHARE := 1.35
const BODY_SHARE := 0.95
## Even a spent spear should tip a Gub over rather than let it fold in place.
const MIN_SPEED := 2.5
## A little lift so the body leaves the ground instead of scraping along it.
const UPWARD_BIAS := 0.30

var _skeleton: Skeleton3D
var _simulator: PhysicalBoneSimulator3D
var _meshes: Array[MeshInstance3D] = []
var _age: float = 0.0


## Build a corpse matching `source` and let it fall.
##
## `blow` is the killing blow's **velocity** — direction and speed both, because
## the speed is what decides whether the corpse is shoved or launched.
## `hit_bone` is where it landed, so a spear through the chest sends the body
## differently from one through a leg. An empty `hit_bone` pushes the torso.
static func spawn_from(source: Gub, parent: Node, blow: Vector3,
		hit_bone: String = "") -> GubRagdoll:
	var corpse := GubRagdoll.new()
	corpse.name = "Corpse_%s" % source.display_name
	parent.add_child(corpse)
	corpse.global_transform = source.global_transform
	corpse._adopt(source)
	corpse._collapse(blow, hit_bone)
	corpse._adopt_spears(source)
	return corpse


func _ready() -> void:
	set_process(true)


func _adopt(source: Gub) -> void:
	var model := MODEL.instantiate() as Node3D
	# The visual model carries a 180 degree turn (the mesh is authored facing
	# +Z); copying the live Gub's Model node keeps the corpse facing the same way
	# the Gub was.
	var source_model := source.get_node("Model") as Node3D
	var holder := Node3D.new()
	holder.transform = source_model.transform
	add_child(holder)
	holder.add_child(model)

	_skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton == null:
		push_error("GubRagdoll: imported model has no Skeleton3D")
		return

	# The corpse must start in the pose the Gub died in, mid-stride and all.
	var source_skeleton := source_model.find_child("Skeleton3D", true, false) as Skeleton3D
	if source_skeleton != null:
		for bone in mini(_skeleton.get_bone_count(), source_skeleton.get_bone_count()):
			_skeleton.set_bone_pose_position(bone, source_skeleton.get_bone_pose_position(bone))
			_skeleton.set_bone_pose_rotation(bone, source_skeleton.get_bone_pose_rotation(bone))
			_skeleton.set_bone_pose_scale(bone, source_skeleton.get_bone_pose_scale(bone))

	# The imported scene brings its own AnimationPlayer, which would keep
	# driving the skeleton and fight the physics.
	var player := model.find_child("AnimationPlayer", true, false)
	if player != null:
		player.queue_free()

	for node in _find_meshes(model):
		# Corpses need their own material to fade out without dissolving every
		# living Gub sharing the imported one.
		for surface in node.mesh.get_surface_count():
			var material := node.mesh.surface_get_material(surface)
			if material != null:
				var copy := material.duplicate() as BaseMaterial3D
				copy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				node.set_surface_override_material(surface, copy)
		_meshes.append(node)


func _collapse(blow: Vector3, hit_bone: String) -> void:
	if _skeleton == null:
		return
	_simulator = RagdollBuilder.build(_skeleton)
	RagdollBuilder.snap_to_pose(_skeleton, _simulator)
	_simulator.physical_bones_start_simulation()

	# `push` is a velocity, and every body is given an impulse of mass x push,
	# which is the definition of a velocity change. Scaling by each body's own
	# mass is the point: without it the 0.8 kg foot would leave at eleven times
	# the speed of the 9 kg torso and the corpse would come apart at the seams.
	var push := blow * IMPACT_TRANSFER
	if push.length() < MIN_SPEED:
		push = push.normalized() * MIN_SPEED if push.length() > 0.01 else Vector3.ZERO
	push += Vector3.UP * push.length() * UPWARD_BIAS

	var struck := _find_bone_body(hit_bone)
	for child in _simulator.get_children():
		var physical := child as PhysicalBone3D
		if physical == null:
			continue
		var share := STRUCK_SHARE if physical == struck else BODY_SHARE
		physical.apply_central_impulse(push * physical.mass * share)


## Take any spear that struck the Gub on the way down and hang it off the bone
## it went through, so it rides the corpse instead of blinking out at the moment
## of the kill.
##
## The spear is re-parented rather than positioned each frame: once it is a child
## of the physical bone the physics carries it for free, it tumbles with the
## limb, and it is freed along with the corpse without anything having to
## remember it exists. Its world transform is preserved across the move so it
## stays exactly where it entered the body.
func _adopt_spears(source: Gub) -> void:
	for entry: Dictionary in source.take_embedded_spears():
		var spear: Node3D = entry["spear"]
		if not is_instance_valid(spear):
			continue
		var body := _find_bone_body(String(entry["bone"]))
		if body == null:
			# No rigid body for that bone — a toe, or a rig without it. The
			# torso is always present and is a better home than the floor.
			body = _find_bone_body("spine.002")
		if body == null:
			spear.queue_free()
			continue
		var world := spear.global_transform
		spear.get_parent().remove_child(spear)
		body.add_child(spear)
		spear.global_transform = world
		if spear.has_method("mark_embedded"):
			spear.call("mark_embedded")


func _find_bone_body(bone_name: String) -> PhysicalBone3D:
	if bone_name.is_empty() or _simulator == null:
		return null
	for child in _simulator.get_children():
		var physical := child as PhysicalBone3D
		if physical != null and physical.bone_name == bone_name:
			return physical
	return null


func _process(delta: float) -> void:
	_age += delta
	if _age < LINGER:
		return
	var alpha := 1.0 - clampf((_age - LINGER) / FADE, 0.0, 1.0)
	if alpha <= 0.0:
		queue_free()
		return
	for mesh in _meshes:
		mesh.transparency = 1.0 - alpha


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for child in node.get_children():
		out.append_array(_find_meshes(child))
	return out
