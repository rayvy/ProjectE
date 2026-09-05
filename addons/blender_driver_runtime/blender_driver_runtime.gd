extends Node
## Evaluates Blender shapekey drivers exported as JSON.
## Does not author drivers: it only replays the exported graph.

@export_file("*.json") var driver_data_path: String = ""
@export var search_root: NodePath
@export var auto_play_animation: bool = true
@export var animation_name: String = ""
@export var apply_constraints: bool = true

var _data: Dictionary = {}
var _compiled: Array = []
var _constraints: Array = []
var _player: AnimationPlayer
var _fps: float = 30.0
var _axis_maps: Dictionary = {}
var _calibrated: bool = false
var _sample_buf: Dictionary = {}
var _last_copy_err: float = 0.0
var _shapekey_anim_tracks: int = 0


func _ready() -> void:
	# After AnimationPlayer (priority 0) so copies see this frame's pose.
	process_priority = 1
	if driver_data_path.is_empty():
		driver_data_path = _guess_driver_path()
	_load_data()
	_compile()
	_player = _find_animation_player(_root())
	_count_shapekey_tracks()
	if auto_play_animation:
		_play_primary_animation(_root())


func _process(_delta: float) -> void:
	if apply_constraints and not _constraints.is_empty():
		_apply_constraints()
	if _compiled.is_empty():
		return
	_maybe_calibrate()
	for rec in _compiled:
		_evaluate_driver(rec)


func get_debug_snapshot() -> Dictionary:
	var drivers_out: Array = []
	for rec in _compiled:
		drivers_out.append({
			"key": rec.get("key", ""),
			"objects": rec.get("object_names", []),
			"last_input": rec.get("last_input", 0.0),
			"last_output": rec.get("last_output", 0.0),
		})
	var pairs: Array = []
	var err_acc := 0.0
	var err_n := 0
	for c in _constraints:
		if str(c.get("type", "")) != "COPY_TRANSFORMS":
			continue
		var src: Skeleton3D = _find_skeleton(_root(), str(c.get("target_armature", "")), str(c.get("target_bone", "")))
		var dst: Skeleton3D = _find_skeleton(_root(), str(c.get("owner_armature", "")), str(c.get("owner_bone", "")))
		if src == null or dst == null:
			continue
		var si := src.find_bone(str(c.get("target_bone", "")))
		var di := dst.find_bone(str(c.get("owner_bone", "")))
		if si < 0 or di < 0:
			continue
		var sw: Transform3D = src.global_transform * src.get_bone_global_pose(si)
		var dw: Transform3D = dst.global_transform * dst.get_bone_global_pose(di)
		var e := sw.origin.distance_to(dw.origin)
		err_acc += e
		err_n += 1
		if pairs.size() < 4:
			pairs.append({
				"src": "%s/%s" % [c.get("target_armature"), c.get("target_bone")],
				"dst": "%s/%s" % [c.get("owner_armature"), c.get("owner_bone")],
				"pos_err": e,
			})
	_last_copy_err = err_acc / maxf(float(err_n), 1.0)
	var probe := _probe_bone("rig.Main", "root.x", "rig.MainSkirt", "root.x")
	return {
		"probe": probe,
		"source_blend": _data.get("source_blend", ""),
		"collection": _data.get("collection", ""),
		"exported_unix": int(_data.get("exported_unix", 0)),
		"export_objects": _data.get("objects", []),
		"drivers": drivers_out,
		"constraint_count": _constraints.size(),
		"proxy_armatures": _data.get("proxy_armatures", []),
		"independent_bones": _data.get("independent_bones", {}),
		"copy_pairs": pairs,
		"copy_pos_err": _last_copy_err,
		"shapekey_anim_tracks": _shapekey_anim_tracks,
		"constraints_enabled": apply_constraints,
	}


func _probe_bone(src_arm: String, src_bone: String, dst_arm: String, dst_bone: String) -> Dictionary:
	var src: Skeleton3D = _find_skeleton(_root(), src_arm, src_bone)
	var dst: Skeleton3D = _find_skeleton(_root(), dst_arm, dst_bone)
	var out := {
		"src_raw": Vector3.ZERO,
		"src_from_global": Vector3.ZERO,
		"dst_raw": Vector3.ZERO,
		"dst_from_global": Vector3.ZERO,
		"found": false,
	}
	if src:
		var si := src.find_bone(src_bone)
		if si >= 0:
			out["src_raw"] = src.get_bone_pose(si).basis.get_euler()
			out["src_from_global"] = _rest_relative_pose(src, si).basis.get_euler()
	if dst:
		var di := dst.find_bone(dst_bone)
		if di >= 0:
			out["dst_raw"] = dst.get_bone_pose(di).basis.get_euler()
			out["dst_from_global"] = _rest_relative_pose(dst, di).basis.get_euler()
			out["found"] = true
	return out


func _root() -> Node:
	if search_root.is_empty():
		return get_parent() if get_parent() else self
	var n := get_node_or_null(search_root)
	return n if n else (get_parent() if get_parent() else self)


func _guess_driver_path() -> String:
	var p := get_parent()
	if p and p.scene_file_path != "":
		return p.scene_file_path.get_basename() + ".drivers.json"
	return ""


func _load_data() -> void:
	if driver_data_path.is_empty() or not FileAccess.file_exists(driver_data_path):
		push_warning("BlenderDrivers: missing driver JSON: %s" % driver_data_path)
		return
	var txt := FileAccess.get_file_as_string(driver_data_path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("BlenderDrivers: invalid JSON")
		return
	_data = parsed
	_fps = float(_data.get("fps", 30.0))


func _compile() -> void:
	_compiled.clear()
	_constraints.clear()
	var root := _root()
	var raw_cons: Array = _data.get("constraints", [])
	for c in raw_cons:
		if typeof(c) == TYPE_DICTIONARY and bool(c.get("cross_armature", true)):
			_constraints.append(c)
	var drivers: Array = _data.get("drivers", [])
	for raw in drivers:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		if str(raw.get("id_type", "")) != "SHAPEKEY":
			continue
		var rec: Dictionary = raw.duplicate(true)
		rec["meshes"] = _find_meshes(root, rec.get("objects", []), rec.get("key", ""))
		rec["last_input"] = 0.0
		rec["last_output"] = 0.0
		rec["object_names"] = rec.get("objects", [])
		var expr := Expression.new()
		var var_names: PackedStringArray = PackedStringArray()
		for v in rec.get("variables", []):
			var_names.append(str(v.get("name", "var")))
		var expr_text := str(rec.get("expression", "0"))
		if expr.parse(expr_text, var_names) != OK:
			push_warning("BlenderDrivers: cannot parse expression '%s'" % expr_text)
			rec["expression_obj"] = null
		else:
			rec["expression_obj"] = expr
		_compiled.append(rec)


func _find_meshes(root: Node, object_names: Array, key_name: String) -> Array:
	var found: Array = []
	var wanted: Dictionary = {}
	for n in object_names:
		wanted[str(n)] = true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var name_ok := wanted.is_empty() or wanted.has(mi.name)
			if not name_ok:
				continue
			if key_name == "" or _blend_index(mi, key_name) >= 0:
				found.append(mi)
	if found.is_empty() and key_name != "":
		stack = [root]
		while not stack.is_empty():
			var n2: Node = stack.pop_back()
			for c2 in n2.get_children():
				stack.append(c2)
			if n2 is MeshInstance3D:
				var mi2 := n2 as MeshInstance3D
				if _blend_index(mi2, key_name) >= 0:
					found.append(mi2)
	return found


func _blend_index(mi: MeshInstance3D, key_name: String) -> int:
	var mesh := mi.mesh
	if mesh == null:
		return -1
	for i in mesh.get_blend_shape_count():
		if mesh.get_blend_shape_name(i) == key_name:
			return i
	return -1


func _names_equiv(a: String, b: String) -> bool:
	if a == b:
		return true
	return a.replace(".", "_") == b.replace(".", "_")


func _find_skeleton(root: Node, armature_name: String, bone_name: String) -> Skeleton3D:
	if armature_name == "" or bone_name == "":
		return null
	var named: Skeleton3D = null
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is Skeleton3D):
			continue
		var sk := n as Skeleton3D
		if sk.find_bone(bone_name) < 0:
			continue
		var parent_name := n.get_parent().name if n.get_parent() else ""
		if _names_equiv(n.name, armature_name) or _names_equiv(parent_name, armature_name):
			named = sk
	return named


func _find_animation_player(root: Node) -> AnimationPlayer:
	var stack: Array = [root]
	var found: AnimationPlayer = null
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is AnimationPlayer:
			var ap := n as AnimationPlayer
			if found == null or ap.get_animation_list().size() > found.get_animation_list().size():
				found = ap
	return found


func _play_primary_animation(root: Node) -> void:
	var player: AnimationPlayer = _find_animation_player(root)
	if player == null:
		return
	_player = player
	var names: PackedStringArray = player.get_animation_list()
	if names.is_empty():
		return
	var pick := animation_name
	if pick == "" or not names.has(pick):
		pick = ""
		for n in names:
			if n.to_lower() == "reset":
				continue
			pick = n
			break
		if pick == "" and names.size() > 0:
			pick = names[0]
	_loop_and_play(player, pick)


func _count_shapekey_tracks() -> void:
	_shapekey_anim_tracks = 0
	if _player == null:
		return
	for clip_name in _player.get_animation_list():
		var anim: Animation = _player.get_animation(clip_name)
		if anim == null:
			continue
		for i in anim.get_track_count():
			var path := String(anim.track_get_path(i))
			if path.contains("blend_shapes") or path.contains("morph"):
				_shapekey_anim_tracks += 1


func _apply_constraints() -> void:
	# Godot 4.7 skinning reads bone pose, not global_pose_override.
	# Write parent-local poses, parents first, so the mesh actually moves.
	var root := _root()
	var by_dst: Dictionary = {}
	for c in _constraints:
		var ttype := str(c.get("type", ""))
		if ttype != "COPY_TRANSFORMS" and ttype != "COPY_LOCATION":
			continue
		var src: Skeleton3D = _find_skeleton(root, str(c.get("target_armature", "")), str(c.get("target_bone", "")))
		var dst: Skeleton3D = _find_skeleton(root, str(c.get("owner_armature", "")), str(c.get("owner_bone", "")))
		if src == null or dst == null:
			continue
		var si := src.find_bone(str(c.get("target_bone", "")))
		var di := dst.find_bone(str(c.get("owner_bone", "")))
		if si < 0 or di < 0:
			continue
		var src_world: Transform3D = src.global_transform * src.get_bone_global_pose(si)
		var glob_skel: Transform3D = dst.global_transform.affine_inverse() * src_world
		if ttype == "COPY_LOCATION":
			var cur: Transform3D = dst.get_bone_global_pose(di)
			cur.origin = glob_skel.origin
			glob_skel = cur
		var key := dst.get_instance_id()
		if not by_dst.has(key):
			by_dst[key] = {"sk": dst, "items": []}
		var items: Array = by_dst[key]["items"]
		items.append({
			"di": di,
			"glob": glob_skel,
			"inf": float(c.get("influence", 1.0)),
			"depth": _bone_depth(dst, di),
		})
	for key in by_dst:
		_apply_pose_copies(by_dst[key]["sk"], by_dst[key]["items"])


func _bone_depth(sk: Skeleton3D, idx: int) -> int:
	var depth := 0
	var walk := sk.get_bone_parent(idx)
	while walk >= 0:
		depth += 1
		walk = sk.get_bone_parent(walk)
	return depth


func _sort_copy_depth(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("depth", 0)) < int(b.get("depth", 0))


func _apply_pose_copies(sk: Skeleton3D, items: Array) -> void:
	items.sort_custom(_sort_copy_depth)
	var desired: Dictionary = {}
	for it in items:
		desired[int(it["di"])] = it["glob"]
	for it in items:
		var di := int(it["di"])
		var glob: Transform3D = it["glob"]
		var parent := sk.get_bone_parent(di)
		var parent_glob := Transform3D.IDENTITY
		if parent >= 0:
			if desired.has(parent):
				parent_glob = desired[parent]
			else:
				parent_glob = sk.get_bone_global_pose(parent)
		var local := parent_glob.affine_inverse() * glob
		var inf := float(it["inf"])
		if inf < 0.999:
			local = sk.get_bone_pose(di).interpolate_with(local, inf)
		sk.set_bone_pose_position(di, local.origin)
		sk.set_bone_pose_rotation(di, local.basis.get_rotation_quaternion())
		sk.set_bone_pose_scale(di, local.basis.get_scale())
	sk.force_update_all_bone_transforms()


func _loop_and_play(player: AnimationPlayer, clip: String) -> void:
	var anim: Animation = player.get_animation(clip)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR
	player.play(clip)


func _evaluate_driver(rec: Dictionary) -> void:
	var values: Array = []
	for v in rec.get("variables", []):
		values.append(_eval_variable(v, rec))
	var raw := 0.0
	var expr: Expression = rec.get("expression_obj")
	if expr:
		var got: Variant = expr.execute(values, self, false)
		if not expr.has_execute_failed() and (typeof(got) == TYPE_FLOAT or typeof(got) == TYPE_INT):
			raw = float(got)
		elif values.size() == 1:
			raw = float(values[0])
	elif values.size() == 1:
		raw = float(values[0])
	var out := _eval_curve(rec.get("curve", {}), raw)
	var smin := float(rec.get("slider_min", 0.0))
	var smax := float(rec.get("slider_max", 1.0))
	out = clampf(out, smin, smax)
	rec["last_input"] = raw
	rec["last_output"] = out
	var key := str(rec.get("key", ""))
	for mi in rec.get("meshes", []):
		if mi == null or not is_instance_valid(mi):
			continue
		var idx := _blend_index(mi, key)
		if idx >= 0:
			mi.set_blend_shape_value(idx, out)


func _eval_variable(var_def: Dictionary, rec: Dictionary) -> float:
	var vtype := str(var_def.get("type", ""))
	var targets: Array = var_def.get("targets", [])
	if targets.is_empty():
		return 0.0
	if vtype == "TRANSFORMS":
		return _eval_transform(targets[0], rec, var_def)
	if vtype == "ROTATION_DIFF" and targets.size() >= 2:
		var q0 := _bone_quat(targets[0])
		var q1 := _bone_quat(targets[1])
		if q0 == Quaternion.IDENTITY and q1 == Quaternion.IDENTITY:
			return 0.0
		return q0.angle_to(q1)
	if vtype == "LOC_DIFF" and targets.size() >= 2:
		var a := _bone_origin(targets[0])
		var b := _bone_origin(targets[1])
		return a.distance_to(b)
	return 0.0


func _eval_transform(target: Dictionary, rec: Dictionary, var_def: Dictionary) -> float:
	var bone := str(target.get("bone", ""))
	var arm := str(target.get("id", ""))
	var sk := _find_skeleton(_root(), arm, bone)
	if sk == null:
		return 0.0
	var idx := sk.find_bone(bone)
	if idx < 0:
		return 0.0
	var pose := _rest_relative_pose(sk, idx)
	var e := pose.basis.get_euler()
	var loc := pose.origin
	var scl := pose.basis.get_scale()
	var ttype := str(target.get("transform_type", "ROT_Z"))
	var map_key := "%s|%s|%s" % [arm, bone, ttype]
	if _axis_maps.has(map_key):
		return _apply_axis_map(_axis_maps[map_key], e, loc, scl, ttype)
	return _raw_component(ttype, e, loc, scl)


func _rest_relative_pose(sk: Skeleton3D, idx: int) -> Transform3D:
	# Prefer global pose so COPY_TRANSFORMS overrides are visible to drivers.
	var glob := sk.get_bone_global_pose(idx)
	var parent := sk.get_bone_parent(idx)
	var parent_glob := Transform3D.IDENTITY
	if parent >= 0:
		parent_glob = sk.get_bone_global_pose(parent)
	var rest := sk.get_bone_rest(idx)
	return rest.affine_inverse() * parent_glob.affine_inverse() * glob


func _raw_component(ttype: String, e: Vector3, loc: Vector3, scl: Vector3) -> float:
	match ttype:
		"LOC_X":
			return loc.x
		"LOC_Y":
			return loc.y
		"LOC_Z":
			return loc.z
		"ROT_X":
			return e.x
		"ROT_Y":
			return e.y
		"ROT_Z":
			return e.z
		"SCALE_X":
			return scl.x
		"SCALE_Y":
			return scl.y
		"SCALE_Z":
			return scl.z
		"SCALE_AVG":
			return (scl.x + scl.y + scl.z) / 3.0
		_:
			return e.z


func _apply_axis_map(amap: Dictionary, e: Vector3, loc: Vector3, scl: Vector3, ttype: String) -> float:
	var src := str(amap.get("source", "euler"))
	var axis := int(amap.get("axis", 2))
	var sign := float(amap.get("sign", 1.0))
	var v := Vector3.ZERO
	if src == "location":
		v = loc
	elif src == "scale":
		v = scl
	else:
		v = e
	var comp := v.x if axis == 0 else (v.y if axis == 1 else v.z)
	return sign * comp


func _bone_quat(target: Dictionary) -> Quaternion:
	var bone := str(target.get("bone", ""))
	var arm := str(target.get("id", ""))
	var sk := _find_skeleton(_root(), arm, bone)
	if sk == null:
		return Quaternion.IDENTITY
	var idx := sk.find_bone(bone)
	if idx < 0:
		return Quaternion.IDENTITY
	# Armature space: Blender's ROTATION_DIFF compares pose bones there.
	return sk.get_bone_global_pose(idx).basis.get_rotation_quaternion()


func _bone_origin(target: Dictionary) -> Vector3:
	var bone := str(target.get("bone", ""))
	var arm := str(target.get("id", ""))
	var sk := _find_skeleton(_root(), arm, bone)
	if sk == null:
		return Vector3.ZERO
	var idx := sk.find_bone(bone)
	if idx < 0:
		return Vector3.ZERO
	return sk.get_bone_global_pose(idx).origin


func _eval_curve(curve: Dictionary, x: float) -> float:
	var points: Array = curve.get("points", [])
	if points.is_empty():
		return x
	var xs: Array = []
	for p in points:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var co: Array = p.get("co", [0.0, 0.0])
		if co.size() < 2:
			continue
		xs.append(Vector2(float(co[0]), float(co[1])))
	if xs.is_empty():
		return x
	xs.sort_custom(func(a, b): return a.x < b.x)
	if x <= xs[0].x:
		return xs[0].y
	if x >= xs[xs.size() - 1].x:
		return xs[xs.size() - 1].y
	for i in range(xs.size() - 1):
		var a: Vector2 = xs[i]
		var b: Vector2 = xs[i + 1]
		if x >= a.x and x <= b.x:
			if is_equal_approx(a.x, b.x):
				return b.y
			var t := (x - a.x) / (b.x - a.x)
			return lerpf(a.y, b.y, t)
	return xs[xs.size() - 1].y


func _maybe_calibrate() -> void:
	if _calibrated:
		return
	if _player == null or not _player.is_playing():
		return
	var t := _player.current_animation_position
	var frame := int(round(t * _fps))
	for rec in _compiled:
		var samples: Array = rec.get("verify_samples", [])
		if samples.is_empty():
			continue
		for s in samples:
			if int(s.get("frame", -999)) != frame:
				continue
			_collect_sample(rec, s)
	_try_lock_maps()


func _collect_sample(rec: Dictionary, sample: Dictionary) -> void:
	var expected_vars: Dictionary = sample.get("variables", {})
	for v in rec.get("variables", []):
		if str(v.get("type", "")) != "TRANSFORMS":
			continue
		var targets: Array = v.get("targets", [])
		if targets.is_empty():
			continue
		var target: Dictionary = targets[0]
		var bone := str(target.get("bone", ""))
		var arm := str(target.get("id", ""))
		var ttype := str(target.get("transform_type", "ROT_Z"))
		var map_key := "%s|%s|%s" % [arm, bone, ttype]
		var sk := _find_skeleton(_root(), arm, bone)
		if sk == null:
			continue
		var idx := sk.find_bone(bone)
		if idx < 0:
			continue
		var pose := _rest_relative_pose(sk, idx)
		var e := pose.basis.get_euler()
		var expected := float(expected_vars.get(str(v.get("name", "")), 0.0))
		if not _sample_buf.has(map_key):
			_sample_buf[map_key] = []
		_sample_buf[map_key].append({"e": e, "expected": expected, "ttype": ttype})


func _try_lock_maps() -> void:
	if _sample_buf.is_empty():
		return
	var ready := true
	for k in _sample_buf.keys():
		if (_sample_buf[k] as Array).size() < 3:
			ready = false
			break
	if not ready:
		return
	for k in _sample_buf.keys():
		var rows: Array = _sample_buf[k]
		var best_axis := 2
		var best_sign := 1.0
		var best_err := INF
		for axis in range(3):
			for sign in [1.0, -1.0]:
				var err := 0.0
				var n := 0
				for row in rows:
					var e: Vector3 = row["e"]
					var comp := e.x if axis == 0 else (e.y if axis == 1 else e.z)
					err += absf(sign * comp - float(row["expected"]))
					n += 1
				err /= maxf(float(n), 1.0)
				if err < best_err:
					best_err = err
					best_axis = axis
					best_sign = sign
		_axis_maps[k] = {"source": "euler", "axis": best_axis, "sign": best_sign, "error": best_err}
	_calibrated = true
