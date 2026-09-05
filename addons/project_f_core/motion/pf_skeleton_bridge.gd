extends Node
class_name PFSkeletonBridge

## Copy matching bone names from a body skeleton onto an attachment skeleton
## (cloak / hair). Bones that exist only on the attachment are left alone
## so PFBonePhysics can simulate TypeHair / TypeCloth on top.

@export var source: Skeleton3D
@export var target: Skeleton3D

var _links: Array[Vector2i] = []


func setup(new_source: Skeleton3D = null, new_target: Skeleton3D = null) -> void:
	if new_source:
		source = new_source
	if new_target:
		target = new_target
	_links.clear()
	if source == null or target == null:
		return
	for target_index in target.get_bone_count():
		var bone_name := target.get_bone_name(target_index)
		# Simulated / driver bones stay on the attachment.
		if PFTypeParser.type_of(bone_name) != "":
			continue
		var source_index := source.find_bone(bone_name)
		if source_index >= 0:
			_links.append(Vector2i(source_index, target_index))


func sync() -> void:
	if _links.is_empty() or source == null or target == null:
		return
	for link in _links:
		var world_pose := source.global_transform * source.get_bone_global_pose(link.x)
		var local_pose := target.global_transform.affine_inverse() * world_pose
		target.set_bone_global_pose_override(link.y, local_pose, 1.0, true)
