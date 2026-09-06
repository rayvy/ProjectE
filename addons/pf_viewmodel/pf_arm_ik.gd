@tool
class_name PFArmIK
extends SkeletonModifier3D

## Two-bone IK that pulls a hand onto a point the animation could not know.
##
## This is *not* the Blender IK. The baked clip is still the performance: the
## arm swings, the fingers close, the weapon recoils, all exactly as authored.
## This modifier only closes the last few centimetres when the world disagrees
## with the animation - the ladder rung is where the level put it, the door
## handle is at the height that door has, the wall is where the player stopped.
##
## Bone names come from the manifest, never from here. Point it at the three
## bones of an arm and a target node; the influence slider decides how much of
## the authored pose survives, so a context clip can fade the correction in
## over its first few frames instead of snapping.

@export var upper_bone: String = "arm_upper.R"
@export var lower_bone: String = "arm_lower.R"
@export var tip_bone: String = "hand.R"

## Where the hand should end up. Usually a Marker3D on the world object.
@export var target: NodePath
## Which way the elbow points. Without one the elbow keeps its authored plane.
@export var pole: NodePath
## Also match the hand's rotation to the target's, not just its position.
@export var match_rotation: bool = false

var _warned: bool = false


func _process_modification() -> void:
	_solve()


func _process_modification_with_delta(_delta: float) -> void:
	_solve()


func _solve() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or influence <= 0.0:
		return
	var target_node := get_node_or_null(target) as Node3D
	if target_node == null:
		return

	var upper := skeleton.find_bone(upper_bone)
	var lower := skeleton.find_bone(lower_bone)
	var tip := skeleton.find_bone(tip_bone)
	if upper < 0 or lower < 0 or tip < 0:
		if not _warned:
			_warned = true
			push_warning("PFArmIK on %s: bones %s / %s / %s not all present"
				% [skeleton.name, upper_bone, lower_bone, tip_bone])
		return
	_warned = false

	# Everything below is in skeleton space: it is the space bone poses live
	# in, so no per-bone conversion is needed and the maths stays readable.
	var to_local := skeleton.global_transform.affine_inverse()
	var pose_upper := skeleton.get_bone_global_pose(upper)
	var pose_lower := skeleton.get_bone_global_pose(lower)
	var pose_tip := skeleton.get_bone_global_pose(tip)

	var root := pose_upper.origin
	var mid := pose_lower.origin
	var end := pose_tip.origin
	var goal := to_local * target_node.global_position

	var upper_len := root.distance_to(mid)
	var lower_len := mid.distance_to(end)
	if upper_len < 1e-5 or lower_len < 1e-5:
		return

	var to_goal := goal - root
	var reach := to_goal.length()
	if reach < 1e-5:
		return
	# Just short of full extension: a perfectly straight arm has no defined
	# elbow plane and the joint flips as the target crosses the limit.
	var span := clampf(reach, absf(upper_len - lower_len) + 1e-4,
		upper_len + lower_len - 1e-4)
	var axis := to_goal / reach

	var cos_root := clampf(
		(upper_len * upper_len + span * span - lower_len * lower_len)
		/ (2.0 * upper_len * span), -1.0, 1.0)
	var root_angle := acos(cos_root)

	# The bend plane: towards the pole if there is one, otherwise keep the
	# plane the animator drew, which is what makes this read as a correction
	# rather than as a different pose.
	var bend_hint := mid - root
	var pole_node := get_node_or_null(pole) as Node3D
	if pole_node != null:
		bend_hint = (to_local * pole_node.global_position) - root
	var bend := bend_hint - axis * bend_hint.dot(axis)
	if bend.length_squared() < 1e-10:
		bend = axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT)
	bend = bend.normalized()

	var mid_solved := root + axis * (upper_len * cos(root_angle)) \
		+ bend * (upper_len * sin(root_angle))
	var end_solved := root + axis * span

	var swing_upper := _arc(mid - root, mid_solved - root)
	var swing_lower := _arc(swing_upper * (end - mid), end_solved - mid_solved)

	var solved_upper := pose_upper
	solved_upper.basis = Basis(swing_upper) * pose_upper.basis
	var solved_lower := pose_lower
	solved_lower.basis = Basis(swing_lower) * Basis(swing_upper) * pose_lower.basis
	solved_lower.origin = mid_solved
	var solved_tip := pose_tip
	solved_tip.basis = solved_lower.basis * (pose_lower.basis.inverse() * pose_tip.basis)
	solved_tip.origin = end_solved
	if match_rotation:
		solved_tip.basis = (to_local * target_node.global_transform).basis

	var amount := clampf(influence, 0.0, 1.0)
	skeleton.set_bone_global_pose(upper, _blend(pose_upper, solved_upper, amount))
	skeleton.set_bone_global_pose(lower, _blend(pose_lower, solved_lower, amount))
	skeleton.set_bone_global_pose(tip, _blend(pose_tip, solved_tip, amount))


## Shortest-arc rotation between two directions, safe on the degenerate cases.
static func _arc(from: Vector3, to: Vector3) -> Quaternion:
	if from.length_squared() < 1e-12 or to.length_squared() < 1e-12:
		return Quaternion.IDENTITY
	return Quaternion(from.normalized(), to.normalized())


static func _blend(a: Transform3D, b: Transform3D, amount: float) -> Transform3D:
	if amount >= 0.999:
		return b
	return a.interpolate_with(b, amount)
