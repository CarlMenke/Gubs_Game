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

## Hits are amplified into something readable. A spear that lands is an instant
## kill, so the corpse's flight is the whole feedback for it — an anatomically
## honest impulse just makes the Gub sag.
const IMPULSE_SCALE := 2.2
const MIN_IMPULSE := 2.5
const UPWARD_BIAS := 0.35

var _skeleton: Skeleton3D
var _simulator: PhysicalBoneSimulator3D
var _meshes: Array[MeshInstance3D] = []
var _age: float = 0.0


## Build a corpse matching `source` and let it fall.
##
## `impulse` points the way the killing blow was travelling; `hit_bone` is where
## it landed, so a spear through the chest spins the body differently from one
## through a leg. An empty `hit_bone` pushes the torso.
static func spawn_from(source: Gub, parent: Node, impulse: Vector3,
		hit_bone: String = "") -> GubRagdoll:
	var corpse := GubRagdoll.new()
	corpse.name = "Corpse_%s" % source.display_name
	parent.add_child(corpse)
	corpse.global_transform = source.global_transform
	corpse._adopt(source)
	corpse._collapse(impulse, hit_bone)
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


func _collapse(impulse: Vector3, hit_bone: String) -> void:
	if _skeleton == null:
		return
	_simulator = RagdollBuilder.build(_skeleton)
	RagdollBuilder.snap_to_pose(_skeleton, _simulator)
	_simulator.physical_bones_start_simulation()

	var push := impulse * IMPULSE_SCALE
	if push.length() < MIN_IMPULSE:
		push = push.normalized() * MIN_IMPULSE if push.length() > 0.01 else Vector3.ZERO
	# A little lift makes the body leave the ground instead of scraping along it.
	push += Vector3.UP * push.length() * UPWARD_BIAS

	var struck := _find_bone_body(hit_bone)
	for child in _simulator.get_children():
		var physical := child as PhysicalBone3D
		if physical == null:
			continue
		if struck != null and physical == struck:
			# The bone that was actually hit takes the brunt, which is what
			# makes a leg shot spin the Gub instead of launching it flat.
			physical.apply_central_impulse(push * physical.mass * 1.25)
		else:
			physical.apply_central_impulse(push * physical.mass * 0.45)


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
