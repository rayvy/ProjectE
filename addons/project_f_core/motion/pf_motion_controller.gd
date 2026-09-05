extends Node
class_name PFMotionController

## World-space Verlet chains for TypeHair / TypeCloth, plus the original
## bounded spring for TypeJiggle. Hair/cloth lag in world space so they
## react to body motion, then get pushed out of body-bone capsules.

const MAX_SUBSTEP_PHASE := 0.25
const MAX_SUBSTEPS := 8
const VERLET_ITERS := 4
const TELEPORT_METERS := 0.45

const COLLIDER_NAMES := [
	"spine_01.x", "spine_02.x", "spine_03.x",
	"neck.x", "head.x",
	"shoulder.l", "shoulder.r",
	"thigh_stretch.l", "thigh_stretch.r",
	"leg_stretch.l", "leg_stretch.r",
	"foot.l", "foot.r",
	"arm_stretch.l", "arm_stretch.r",
	"forearm_stretch.l", "forearm_stretch.r",
	"hand.l", "hand.r",
]
const COLLIDER_RADII := [
	0.10, 0.11, 0.10,
	0.05, 0.10,
	0.06, 0.06,
	0.08, 0.08,
	0.055, 0.055,
	0.045, 0.045,
	0.045, 0.045,
	0.04, 0.04,
	0.05, 0.05,
]

var skeleton: Skeleton3D
var collider_skeleton: Skeleton3D
## Authored colliders. When this loads anything, the hardcoded bone capsules
## below are not used at all — modelled shapes beat guessed radii.
var collider_set: PFColliderSet = PFColliderSet.new()
var collider_path: String = ""
var paused: bool = false
var use_fixed_step: bool = true
var fixed_step: float = 1.0 / 60.0
var external_step_driver: bool = false
var last_max_lag: float = 0.0

var _chains: Array = []
var _accumulator: float = 0.0
var _resync_pending: bool = false
var _collider_defs: Array = []
var _capsules: Array = []


class _Chain extends RefCounted:
	var profile: PFMotionProfile
	var bones: PackedInt32Array = PackedInt32Array()
	var directions: PackedVector3Array = PackedVector3Array()
	var velocities: PackedVector3Array = PackedVector3Array()
	var rest_directions: PackedVector3Array = PackedVector3Array()
	var rest_lengths: PackedFloat32Array = PackedFloat32Array()
	var previous_root_position: Vector3 = Vector3.ZERO
	var initialised: bool = false
	var target_positions: PackedVector3Array = PackedVector3Array()
	var target_bases: Array[Basis] = []
	var particles: PackedVector3Array = PackedVector3Array()
	var prev_particles: PackedVector3Array = PackedVector3Array()
	var bind_local: PackedVector3Array = PackedVector3Array()
	var skip_parent_name: String = ""
	var chain_names: Dictionary = {}
	var use_verlet: bool = false


class _Capsule extends RefCounted:
	var bone_index: int = -1
	var radius: float = 0.05
	var length: float = 0.1
	var bone_name: String = ""
	var a: Vector3 = Vector3.ZERO
	var b: Vector3 = Vector3.ZERO


func setup(target: Skeleton3D) -> void:
	skeleton = target
	_chains.clear()
	_accumulator = 0.0
	last_max_lag = 0.0
	_setup_colliders()
	var loaded := collider_set.load_from(collider_path, collider_skeleton if collider_skeleton else skeleton)
	if loaded > 0:
		# Authored shapes supersede the guessed ones entirely; mixing the two
		# would double up on the torso and pinch everything that passes it.
		_collider_defs.clear()
		_capsules.clear()


func chain_count() -> int:
	return _chains.size()


func collider_count() -> int:
	return _collider_defs.size() + collider_set.colliders.size()


func register_chain(profile: PFMotionProfile) -> bool:
	if skeleton == null or profile == null or not profile.is_valid():
		return false
	var bones := _resolve_chain(profile.root_bone, profile.end_bone)
	if bones.size() < 2:
		push_warning("PFMotionController: '%s' -> '%s' is not a 2+ bone chain" % [profile.root_bone, profile.end_bone])
		return false
	var chain := _Chain.new()
	chain.profile = profile
	chain.bones = bones
	chain.use_verlet = (
		profile.kind == PFMotionProfile.ChainKind.HAIR
		or profile.kind == PFMotionProfile.ChainKind.CLOTH
	)
	var parent := skeleton.get_bone_parent(bones[0])
	if parent >= 0:
		chain.skip_parent_name = skeleton.get_bone_name(parent)
	for idx in bones:
		chain.chain_names[skeleton.get_bone_name(idx)] = true
	if chain.use_verlet:
		_initialise_verlet(chain)
	else:
		_initialise_chain(chain)
	_chains.append(chain)
	return true


func _resolve_chain(root_name: StringName, end_name: StringName) -> PackedInt32Array:
	var root_index := skeleton.find_bone(String(root_name))
	var end_index := skeleton.find_bone(String(end_name))
	if root_index < 0 or end_index < 0:
		return PackedInt32Array()
	var reversed: Array[int] = []
	var walk := end_index
	while walk >= 0:
		reversed.append(walk)
		if walk == root_index:
			break
		walk = skeleton.get_bone_parent(walk)
	if reversed.is_empty() or reversed[reversed.size() - 1] != root_index:
		return PackedInt32Array()
	reversed.reverse()
	return PackedInt32Array(reversed)


func _attachment_global(chain: _Chain) -> Transform3D:
	var parent := skeleton.get_bone_parent(chain.bones[0])
	if parent >= 0:
		return skeleton.get_bone_global_pose(parent)
	return Transform3D.IDENTITY


func _pin_position(chain: _Chain) -> Vector3:
	return (_attachment_global(chain) * skeleton.get_bone_rest(chain.bones[0])).origin


func _initialise_chain(chain: _Chain) -> void:
	var count := chain.bones.size()
	chain.directions.resize(maxi(0, count - 1))
	chain.velocities.resize(maxi(0, count - 1))
	chain.rest_directions.resize(maxi(0, count - 1))
	chain.rest_lengths.resize(maxi(0, count - 1))
	chain.target_positions.resize(count)
	chain.target_bases.resize(count)
	_compute_targets(chain)
	for segment in maxi(0, count - 1):
		var offset: Vector3 = chain.target_positions[segment + 1] - chain.target_positions[segment]
		var length := offset.length()
		var direction := offset.normalized() if length > 0.00001 else Vector3.DOWN
		chain.rest_directions[segment] = direction
		chain.rest_lengths[segment] = length
		chain.directions[segment] = direction
		chain.velocities[segment] = Vector3.ZERO
	chain.previous_root_position = skeleton.to_global(chain.target_positions[0])
	chain.initialised = true


func _initialise_verlet(chain: _Chain) -> void:
	var n := chain.bones.size()
	chain.particles.resize(n + 1)
	chain.prev_particles.resize(n + 1)
	chain.rest_lengths.resize(n)
	chain.bind_local.resize(n)
	for i in n:
		chain.particles[i] = skeleton.get_bone_global_pose(chain.bones[i]).origin
	var last_pose := skeleton.get_bone_global_pose(chain.bones[n - 1])
	var leaf_len := 0.05
	var kids := skeleton.get_bone_children(chain.bones[n - 1])
	if kids.size() > 0:
		leaf_len = skeleton.get_bone_rest(kids[0]).origin.length()
	elif n >= 2:
		leaf_len = chain.particles[n - 1].distance_to(chain.particles[n - 2])
	leaf_len = maxf(leaf_len, 0.02)
	var axis := last_pose.basis.y
	if axis.length_squared() < 0.000001:
		axis = Vector3.DOWN
	chain.particles[n] = last_pose.origin + axis.normalized() * leaf_len
	var attach := _attachment_global(chain)
	for i in n:
		var delta: Vector3 = chain.particles[i + 1] - chain.particles[i]
		var length := maxf(delta.length(), 0.01)
		chain.rest_lengths[i] = length
		chain.bind_local[i] = attach.basis.inverse() * (delta / length)
	chain.prev_particles = chain.particles.duplicate()
	chain.particles[0] = _pin_position(chain)
	chain.prev_particles[0] = chain.particles[0]
	chain.initialised = true


func _compute_targets(chain: _Chain) -> void:
	var root_parent := skeleton.get_bone_parent(chain.bones[0])
	var parent_transform := (
		skeleton.get_bone_global_pose(root_parent)
		if root_parent >= 0 else Transform3D.IDENTITY
	)
	for i in chain.bones.size():
		var target := parent_transform * skeleton.get_bone_rest(chain.bones[i])
		chain.target_positions[i] = target.origin
		chain.target_bases[i] = target.basis
		parent_transform = target


func _setup_colliders() -> void:
	_collider_defs.clear()
	_capsules.clear()
	var src := collider_skeleton if collider_skeleton else skeleton
	if src == null:
		return
	for i in COLLIDER_NAMES.size():
		var idx := src.find_bone(COLLIDER_NAMES[i])
		if idx < 0:
			continue
		var cap := _Capsule.new()
		cap.bone_index = idx
		cap.radius = COLLIDER_RADII[i]
		cap.length = maxf(_estimate_bone_length(src, idx), 0.04)
		cap.bone_name = COLLIDER_NAMES[i]
		_collider_defs.append(cap)


func _estimate_bone_length(sk: Skeleton3D, idx: int) -> float:
	var kids := sk.get_bone_children(idx)
	if kids.size() > 0:
		var best := 0.0
		for child in kids:
			best = maxf(best, sk.get_bone_rest(child).origin.length())
		if best > 0.01:
			return best
	return 0.08


func _update_capsules() -> void:
	var src := collider_skeleton if collider_skeleton else skeleton
	if src == null:
		return
	_capsules.clear()
	for entry in _collider_defs:
		var cap := entry as _Capsule
		var pose := src.get_bone_global_pose(cap.bone_index)
		var world := src.global_transform * pose
		var sim := skeleton.global_transform.affine_inverse() * world
		var axis := sim.basis.y
		if axis.length_squared() < 0.000001:
			axis = Vector3.DOWN
		var live := _Capsule.new()
		live.bone_index = cap.bone_index
		live.radius = cap.radius
		live.length = cap.length
		live.bone_name = cap.bone_name
		var y := axis.normalized()
		# Keep the joint-end sphere from swallowing cloth at the attachment.
		live.a = sim.origin + y * minf(0.03, cap.length * 0.2)
		live.b = sim.origin + y * cap.length
		_capsules.append(live)


func _physics_process(delta: float) -> void:
	if external_step_driver:
		return
	step(delta)


func step(delta: float) -> void:
	if paused or skeleton == null:
		return
	if use_fixed_step:
		_accumulator += delta
		var steps := 0
		while _accumulator >= fixed_step and steps < 4:
			_solve(fixed_step)
			_accumulator -= fixed_step
			steps += 1
	else:
		_solve(delta)


func _solve(step_size: float) -> void:
	if _resync_pending:
		_resync_pending = false
		_resync_now()
	_update_capsules()
	collider_set.update(collider_skeleton if collider_skeleton else skeleton, skeleton)
	last_max_lag = 0.0
	for entry in _chains:
		var chain := entry as _Chain
		if not chain.initialised:
			continue
		if chain.use_verlet:
			_solve_verlet_chain(chain, step_size)
		else:
			_solve_spring_chain(chain, step_size)


func _substeps_for(k: float, step_size: float) -> int:
	if k <= 0.0 or step_size <= 0.0:
		return 1
	var phase := sqrt(k) * step_size
	if phase <= MAX_SUBSTEP_PHASE:
		return 1
	return mini(MAX_SUBSTEPS, int(ceil(phase / MAX_SUBSTEP_PHASE)))


func _solve_spring_chain(chain: _Chain, step_size: float) -> void:
	var profile := chain.profile
	_compute_targets(chain)
	var root_position := skeleton.to_global(chain.target_positions[0])
	var world_motion := root_position - chain.previous_root_position
	chain.previous_root_position = root_position
	var root_motion: Vector3 = skeleton.global_transform.basis.inverse() * world_motion

	var frequency_scale := maxf(0.01, profile.frequency_scale)
	var stiffness := lerpf(2.0, 60.0, profile.stiffness) * frequency_scale
	var damping := lerpf(1.0, 18.0, profile.drag) * sqrt(frequency_scale) * maxf(0.01, profile.damping_scale)
	var gravity_vector := profile.gravity_direction.normalized() * profile.gravity * profile.amplitude
	var segment_count := chain.directions.size()
	var substeps := _substeps_for(stiffness, step_size)
	var substep_dt := step_size / float(substeps)

	for segment in segment_count:
		var target_from_basis: Basis = chain.target_bases[segment]
		var rest_direction := (chain.target_positions[segment + 1] - chain.target_positions[segment]).normalized()
		var current: Vector3 = chain.directions[segment]
		var velocity: Vector3 = chain.velocities[segment]

		var previous_target: Vector3 = chain.rest_directions[segment]
		if previous_target.length_squared() > 0.000001:
			var authored_delta := Quaternion(previous_target, rest_direction)
			var transported_delta := Quaternion.IDENTITY.slerp(
				authored_delta,
				1.0 - clampf(profile.angular_inertia_strength, 0.0, 0.9),
			)
			current = (transported_delta * current).normalized()
			velocity = authored_delta * velocity
		chain.rest_directions[segment] = rest_direction

		var falloff_t := float(segment) / maxf(1.0, float(segment_count - 1))
		var segment_stiffness := stiffness * lerpf(1.0, 1.0 - profile.segment_falloff, falloff_t)
		var segment_damping := damping * lerpf(1.0, 1.0 - profile.segment_falloff * 0.5, falloff_t)
		var inertia := (-root_motion / maxf(step_size, 0.00001)) * profile.inertia_strength * profile.amplitude
		var driving_force := gravity_vector + inertia
		var local_force := target_from_basis.inverse() * driving_force
		local_force.x *= profile.lateral_response
		local_force.y *= profile.vertical_response
		local_force.z *= profile.depth_response
		driving_force = target_from_basis * local_force

		for _substep in substeps:
			var acceleration := (rest_direction - current) * segment_stiffness + driving_force - velocity * segment_damping
			velocity += acceleration * substep_dt
			current = (current + velocity * substep_dt).normalized()
			var angle := rest_direction.angle_to(current)
			if angle > profile.max_angle_radians:
				current = rest_direction.slerp(current, profile.max_angle_radians / maxf(angle, 0.00001)).normalized()
				velocity = velocity.slide(current)
		chain.directions[segment] = current
		chain.velocities[segment] = velocity
		_apply_segment(chain, segment, rest_direction, current, target_from_basis)


func _solve_verlet_chain(chain: _Chain, step_size: float) -> void:
	var profile := chain.profile
	var n := chain.bones.size()
	var pin := _pin_position(chain)
	var delta: Vector3 = pin - chain.particles[0]
	chain.particles[0] = pin
	if delta.length() > TELEPORT_METERS:
		for i in range(1, chain.particles.size()):
			chain.particles[i] += delta
			chain.prev_particles[i] += delta
	chain.prev_particles[0] = pin

	var gravity_world := profile.gravity_direction
	if gravity_world.length_squared() < 0.000001:
		gravity_world = Vector3.DOWN
	var g_skel: Vector3 = skeleton.global_transform.basis.inverse() * gravity_world.normalized() * profile.gravity
	var vel_keep := exp(-lerpf(0.8, 14.0, profile.drag) * step_size)
	var follow_hz := lerpf(0.15, 10.0, profile.stiffness) * (1.0 - clampf(profile.angular_inertia_strength, 0.0, 0.9) * 0.75)
	var follow := 1.0 - exp(-follow_hz * step_size)
	var attach := _attachment_global(chain)

	for i in range(1, chain.particles.size()):
		var vel: Vector3 = (chain.particles[i] - chain.prev_particles[i]) * vel_keep
		chain.prev_particles[i] = chain.particles[i]
		chain.particles[i] = chain.particles[i] + vel + g_skel * step_size * step_size

	var shaped := PackedVector3Array()
	shaped.resize(chain.particles.size())
	shaped[0] = pin
	for i in n:
		var bind_dir: Vector3 = attach.basis * chain.bind_local[i]
		if bind_dir.length_squared() < 0.000001:
			bind_dir = Vector3.DOWN
		else:
			bind_dir = bind_dir.normalized()
		shaped[i + 1] = shaped[i] + bind_dir * chain.rest_lengths[i]
		chain.particles[i + 1] = chain.particles[i + 1].lerp(shaped[i + 1], follow)

	for _iter in VERLET_ITERS:
		for i in n:
			var offset: Vector3 = chain.particles[i + 1] - chain.particles[i]
			var dist := offset.length()
			if dist < 0.000001:
				continue
			chain.particles[i + 1] = chain.particles[i] + offset * (chain.rest_lengths[i] / dist)
		for i in n:
			var bind_dir: Vector3 = attach.basis * chain.bind_local[i]
			if bind_dir.length_squared() < 0.000001:
				continue
			bind_dir = bind_dir.normalized()
			var cur: Vector3 = chain.particles[i + 1] - chain.particles[i]
			var dist := cur.length()
			if dist < 0.000001:
				continue
			var cur_n := cur / dist
			var ang := bind_dir.angle_to(cur_n)
			if ang > profile.max_angle_radians:
				cur_n = bind_dir.slerp(cur_n, profile.max_angle_radians / maxf(ang, 0.00001))
				chain.particles[i + 1] = chain.particles[i] + cur_n * chain.rest_lengths[i]
		_collide_chain(chain)

	var lag := 0.0
	for i in range(1, chain.particles.size()):
		lag = maxf(lag, chain.particles[i].distance_to(shaped[i]))
	last_max_lag = maxf(last_max_lag, lag)
	_apply_verlet_bones(chain)


func _collide_chain(chain: _Chain) -> void:
	if not collider_set.colliders.is_empty():
		var root := str(chain.skip_parent_name)
		for i in range(1, chain.particles.size()):
			chain.particles[i] = collider_set.resolve(chain.particles[i], root)
		return
	if _capsules.is_empty():
		return
	for i in range(1, chain.particles.size()):
		var p: Vector3 = chain.particles[i]
		for entry in _capsules:
			var cap := entry as _Capsule
			if chain.chain_names.has(cap.bone_name):
				continue
			if i <= 1 and (
				cap.bone_name == chain.skip_parent_name
				or cap.bone_name.begins_with("spine_")
				or cap.bone_name == "head.x"
				or cap.bone_name == "neck.x"
			):
				continue
			p = _push_out_capsule(p, cap)
		chain.particles[i] = p


func _push_out_capsule(p: Vector3, cap: _Capsule) -> Vector3:
	var ab: Vector3 = cap.b - cap.a
	var ab_len_sq := ab.length_squared()
	var t := 0.0
	if ab_len_sq > 0.000001:
		t = clampf((p - cap.a).dot(ab) / ab_len_sq, 0.0, 1.0)
	var closest: Vector3 = cap.a + ab * t
	var offset: Vector3 = p - closest
	var dist := offset.length()
	if dist >= cap.radius:
		return p
	if dist < 0.000001:
		var fallback := cap.b - cap.a
		if fallback.length_squared() < 0.000001:
			fallback = Vector3.UP
		return closest + fallback.normalized() * cap.radius
	return closest + offset * (cap.radius / dist)


func _apply_verlet_bones(chain: _Chain) -> void:
	var parent := skeleton.get_bone_parent(chain.bones[0])
	var parent_glob := (
		skeleton.get_bone_global_pose(parent)
		if parent >= 0 else Transform3D.IDENTITY
	)
	for i in chain.bones.size():
		var bone := chain.bones[i]
		var rest := skeleton.get_bone_rest(bone)
		var rest_glob := parent_glob * rest
		var desired: Vector3 = chain.particles[i + 1] - chain.particles[i]
		if desired.length_squared() < 0.000001:
			parent_glob = rest_glob
			continue
		desired = desired.normalized()
		var rest_y := rest_glob.basis.y
		if rest_y.length_squared() < 0.000001:
			rest_y = Vector3.UP
		else:
			rest_y = rest_y.normalized()
		var rot := Quaternion(rest_y, desired)
		var new_basis := Basis(rot) * rest_glob.basis
		var local_basis := parent_glob.basis.inverse() * new_basis
		skeleton.set_bone_pose_rotation(bone, local_basis.get_rotation_quaternion())
		parent_glob = Transform3D(new_basis, rest_glob.origin)


func _apply_segment(chain: _Chain, segment: int, rest_direction: Vector3, solved: Vector3, authored_global_basis: Basis) -> void:
	var bone := chain.bones[segment]
	var parent := skeleton.get_bone_parent(bone)
	var parent_basis := skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var delta_rotation := Quaternion(rest_direction, solved)
	var target_global_basis := Basis(delta_rotation) * authored_global_basis
	var local_basis := parent_basis.inverse() * target_global_basis
	skeleton.set_bone_pose_rotation(bone, local_basis.get_rotation_quaternion())
	var max_translation := chain.profile.max_translation_meters
	if max_translation > 0.0:
		var rest_position := skeleton.get_bone_rest(bone).origin
		var offset := (solved - rest_direction) * chain.rest_lengths[segment] * 0.5
		if offset.length() > max_translation:
			offset = offset.normalized() * max_translation
		skeleton.set_bone_pose_position(bone, rest_position + offset)


func resync_targets() -> void:
	_resync_pending = true
	_resync_now()


func _resync_now() -> void:
	for entry in _chains:
		var chain := entry as _Chain
		if not chain.initialised:
			continue
		if chain.use_verlet:
			_initialise_verlet(chain)
			continue
		_compute_targets(chain)
		for segment in chain.directions.size():
			var new_rest := (chain.target_positions[segment + 1] - chain.target_positions[segment]).normalized()
			var old_rest: Vector3 = chain.rest_directions[segment]
			if old_rest.length_squared() > 0.000001 and new_rest.length_squared() > 0.000001 and old_rest.dot(new_rest) > -0.9999:
				var delta := Quaternion(old_rest, new_rest)
				chain.directions[segment] = (delta * chain.directions[segment]).normalized()
				chain.velocities[segment] = delta * chain.velocities[segment]
			chain.rest_directions[segment] = new_rest
		if chain.bones.size() > 0:
			chain.previous_root_position = skeleton.to_global(chain.target_positions[0])
