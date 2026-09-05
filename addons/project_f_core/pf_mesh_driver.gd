@tool
extends Node
class_name PFMeshDriver

## Armature-driven float channels -> skin shader parameters.
##
## The channel values ride the bones; the PF_Mat sockets in Blender decide what
## they mean. Everything else about a material (its maps, its constants) comes
## from the materials sidecar via PFMaterialApplier, not from here.
##
## Blender material drivers do not survive glTF, so the exporter serializes
## them into `<name>.drivers.json` under "material_channels" and this node
## replays them. Read or write a channel by name:
##
##     $MeshDriver.ArmPitClosedL              # current value
##     $MeshDriver.ArmPitClosedL = 1.0        # manual override, holds until released
##     $MeshDriver.release("ArmPitClosedL")   # back to the armature
##
## Channels declared in Blender beyond the four named below are still driven
## and pushed; reach them with get_channel()/set_channel().
##
## Shader contract (see skin_endfield_reference.gdshader):
##     uniform vec4 pf_ch;          // channel values, one per slot
##     uniform vec4 pf_zone_0..3;   // xyz = zone centre in model space, w = radius
##     uniform float pf_zone_debug;   // magenta tint for placing the zone
##
## Zones are stored in the JSON as a pair of bones plus a blend factor rather
## than a vector, so they survive Blender's Z-up -> Godot's Y-up conversion
## without any axis bookkeeping.

const SLOT_COUNT := 4

@export_file("*.json") var driver_data_path: String = ""
@export var search_root: NodePath

@export_group("Debug")
## Tints the active zone magenta so you can place it. 0 = normal shading;
## the wrinkle itself is always on.
@export_range(0.0, 1.0) var zone_debug: float = 0.0:
	set(v):
		zone_debug = v
		_dirty = true
## Ignore the armature and drive every channel to this value. Use it to place
## the zones before trusting the drivers.
@export var force_all_channels: bool = false:
	set(v):
		force_all_channels = v
		_dirty = true
@export_range(0.0, 1.0) var force_value: float = 1.0
## Multiplies every zone radius from the JSON. Tune the blobs live, then copy
## the number back into the Blender channel nodes.
@export_range(0.1, 4.0) var zone_radius_scale: float = 1.0

# channel name -> {slot, material, zone, variables, expression, curve, value, override}
var _channels: Dictionary = {}
var _order: PackedStringArray = PackedStringArray()
# material name -> {materials: [ShaderMaterial], mesh: MeshInstance3D}
var _targets: Dictionary = {}
var _axis_maps: Dictionary = {}
# "armature|bone" -> Skeleton3D. Channels and zones ask for the same handful of
# bones every frame; walking the tree each time is the whole per-frame cost.
var _skel_cache: Dictionary = {}
var _sample_buf: Dictionary = {}
var _calibrated: bool = false
var _calib_error: float = 0.0
var _resolved: bool = false
var _dirty: bool = true
var _player: AnimationPlayer
var _fps: float = 30.0


# The four channels the exporter builds by default get real properties so
# `$MeshDriver.ArmPitClosedL` type-checks. Everything else goes through _get/_set.
var ArmPitClosedL: float:
	get:
		return get_channel("ArmPitClosedL")
	set(value):
		set_channel("ArmPitClosedL", value)

var ArmPitClosedR: float:
	get:
		return get_channel("ArmPitClosedR")
	set(value):
		set_channel("ArmPitClosedR", value)

var FeetFoldL: float:
	get:
		return get_channel("FeetFoldL")
	set(value):
		set_channel("FeetFoldL", value)

var FeetFoldR: float:
	get:
		return get_channel("FeetFoldR")
	set(value):
		set_channel("FeetFoldR", value)


func _ready() -> void:
	# After AnimationPlayer and after BlenderDrivers, so bone poses are final.
	process_priority = 2
	if driver_data_path.is_empty():
		driver_data_path = _guess_driver_path()
	_load()
	# @tool is only here so extra channels show up in the inspector. Writing
	# shader params from the editor would dirty the .tres presets on save.
	set_process(not Engine.is_editor_hint())


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _channels.is_empty():
		return
	if not _resolved:
		_resolve_targets()
	_maybe_calibrate()
	for name in _order:
		_channels[name]["value"] = _compute(_channels[name])
	# Push every frame, not only when a value moved: the zone centres ride the
	# bones, so a channel sitting at a constant 1.0 still needs its sphere
	# re-anchored or the mesh skins straight out of it.
	_push()
	_dirty = false


# ------------------------------------------------------------------- public --

func get_channel(name: String) -> float:
	var rec: Variant = _channels.get(name)
	return float(rec["value"]) if rec else 0.0


func set_channel(name: String, value: float) -> void:
	var rec: Variant = _channels.get(name)
	if rec == null:
		push_warning("PFMeshDriver: unknown channel '%s'" % name)
		return
	rec["override"] = clampf(value, 0.0, 1.0)
	_dirty = true


func release(name: String) -> void:
	var rec: Variant = _channels.get(name)
	if rec:
		rec["override"] = null
		_dirty = true


func release_all() -> void:
	for name in _order:
		_channels[name]["override"] = null
	_dirty = true


func channel_names() -> PackedStringArray:
	return _order.duplicate()


func get_debug_snapshot() -> Dictionary:
	var rows: Array = []
	for name in _order:
		var rec: Dictionary = _channels[name]
		rows.append({
			"channel": name,
			"slot": int(rec["slot"]),
			"material": str(rec["material"]),
			"value": float(rec["value"]),
			"raw": float(rec.get("last_raw", 0.0)),
			"overridden": rec.get("override") != null,
			"zone_ok": bool(rec.get("zone_ok", false)),
			"material_bound": _targets.has(str(rec["material"])),
			"zone_pos": rec.get("last_zone", Vector4.ZERO),
		})
	return {
		"channels": rows,
		"materials_bound": _targets.size(),
		"calibrated": _calibrated,
		"calib_error": _calib_error,
		"needs_calibration": _needs_calibration(),
		"debug": zone_debug,
	}


# ------------------------------------------------------------- dynamic props --

func _get(property: StringName) -> Variant:
	var name := String(property)
	if _channels.has(name):
		return float(_channels[name]["value"])
	return null


func _set(property: StringName, value: Variant) -> bool:
	var name := String(property)
	if _channels.has(name) and (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT):
		set_channel(name, float(value))
		return true
	return false


func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var extra: PackedStringArray = PackedStringArray()
	for name in _order:
		if name in ["ArmPitClosedL", "ArmPitClosedR", "FeetFoldL", "FeetFoldR"]:
			continue
		extra.append(name)
	if extra.is_empty():
		return out
	out.append({
		"name": "Channels",
		"type": TYPE_NIL,
		"usage": PROPERTY_USAGE_GROUP,
	})
	for name in extra:
		out.append({
			"name": name,
			"type": TYPE_FLOAT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "0.0,1.0,0.001",
			"usage": PROPERTY_USAGE_EDITOR,
		})
	return out


# -------------------------------------------------------------------- loading --

func _guess_driver_path() -> String:
	var p := get_parent()
	if p and p.scene_file_path != "":
		return p.scene_file_path.get_basename() + ".drivers.json"
	return ""


func _load() -> void:
	_channels.clear()
	_order = PackedStringArray()
	if driver_data_path.is_empty() or not FileAccess.file_exists(driver_data_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(driver_data_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PFMeshDriver: invalid JSON at %s" % driver_data_path)
		return
	var data: Dictionary = parsed
	_fps = float(data.get("fps", 30.0))
	for raw in data.get("material_channels", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		if raw.has("error"):
			push_warning("PFMeshDriver: %s::%s %s" % [
				raw.get("material", "?"), raw.get("channel", "?"), raw.get("error", "")])
			continue
		var name := str(raw.get("channel", ""))
		if name.is_empty():
			continue
		var rec: Dictionary = {
			"slot": clampi(int(raw.get("slot", 0)), 0, SLOT_COUNT - 1),
			"material": str(raw.get("material", "")),
			"zone": raw.get("zone", null),
			"variables": raw.get("variables", []),
			"curve": raw.get("curve", {}),
			"verify_samples": raw.get("verify_samples", []),
			"has_driver": bool(raw.get("has_driver", false)),
			"default": float(raw.get("default", 0.0)),
			"value": float(raw.get("default", 0.0)),
			"last_raw": 0.0,
			"override": null,
			"zone_ok": false,
			"expression_obj": null,
		}
		var expr_text := str(raw.get("expression", ""))
		if not expr_text.is_empty():
			var expr := Expression.new()
			var names: PackedStringArray = PackedStringArray()
			for v in rec["variables"]:
				names.append(str(v.get("name", "var")))
			if expr.parse(expr_text, names) == OK:
				rec["expression_obj"] = expr
			else:
				push_warning("PFMeshDriver: cannot parse '%s'" % expr_text)
		_channels[name] = rec
		_order.append(name)
	notify_property_list_changed()


# ------------------------------------------------------------------ resolving --

func _root() -> Node:
	if not search_root.is_empty():
		var n := get_node_or_null(search_root)
		if n:
			return n
	return get_parent() if get_parent() else self


func _resolve_targets() -> void:
	_targets.clear()
	var wanted: Dictionary = {}
	for name in _order:
		wanted[str(_channels[name]["material"])] = true
	var stack: Array[Node] = [_root()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			if not (mat is ShaderMaterial):
				continue
			var mat_name := mat.resource_name
			if not wanted.has(mat_name):
				continue
			if not _targets.has(mat_name):
				_targets[mat_name] = {"materials": [], "mesh": mi}
			var bucket: Array = _targets[mat_name]["materials"]
			if not bucket.has(mat):
				bucket.append(mat)
	# The material applier swaps presets in after this node's _ready, so keep
	# retrying until something with the right resource_name shows up.
	if not _targets.is_empty():
		_resolved = true
		_dirty = true


func rescan() -> void:
	_resolved = false
	_skel_cache.clear()


# ----------------------------------------------------------------- evaluation --

func _compute(rec: Dictionary) -> float:
	if force_all_channels:
		return clampf(force_value, 0.0, 1.0)
	var ov: Variant = rec.get("override")
	if ov != null:
		return float(ov)
	if not bool(rec["has_driver"]):
		return float(rec["default"])
	var values: Array = []
	for v in rec["variables"]:
		values.append(_eval_variable(v))
	var raw := 0.0
	var expr: Expression = rec["expression_obj"]
	if expr:
		var got: Variant = expr.execute(values, self, false)
		if not expr.has_execute_failed() and (typeof(got) == TYPE_FLOAT or typeof(got) == TYPE_INT):
			raw = float(got)
		elif values.size() == 1:
			raw = float(values[0])
	elif values.size() == 1:
		raw = float(values[0])
	rec["last_raw"] = raw
	return clampf(_eval_curve(rec["curve"], raw), 0.0, 1.0)


func _eval_variable(var_def: Dictionary) -> float:
	var targets: Array = var_def.get("targets", [])
	if targets.is_empty():
		return 0.0
	var vtype := str(var_def.get("type", ""))
	if vtype == "ROTATION_DIFF":
		if targets.size() < 2:
			return 0.0
		# Blender's ROTATION_DIFF compares pose bones in armature space and can
		# return the long way round; Quaternion.angle_to() always takes the
		# short arc. The exported expression folds Blender's value into the same
		# range, so these agree.
		return _bone_quat(targets[0]).angle_to(_bone_quat(targets[1]))
	if vtype == "LOC_DIFF":
		if targets.size() < 2:
			return 0.0
		return _bone_origin(targets[0]).distance_to(_bone_origin(targets[1]))
	if vtype != "TRANSFORMS":
		return 0.0
	var target: Dictionary = targets[0]
	var arm := str(target.get("id", ""))
	var bone := str(target.get("bone", ""))
	var sk := _find_skeleton(arm, bone)
	if sk == null:
		return 0.0
	var idx := sk.find_bone(bone)
	if idx < 0:
		return 0.0
	var pose := _rest_relative_pose(sk, idx)
	var e := pose.basis.get_euler()
	var ttype := str(target.get("transform_type", "ROT_Z"))
	var key := "%s|%s|%s" % [arm, bone, ttype]
	if _axis_maps.has(key):
		var m: Dictionary = _axis_maps[key]
		var axis := int(m["axis"])
		var comp := e.x if axis == 0 else (e.y if axis == 1 else e.z)
		return float(m["sign"]) * comp
	match ttype:
		"ROT_X": return e.x
		"ROT_Y": return e.y
		"ROT_Z": return e.z
		"LOC_X": return pose.origin.x
		"LOC_Y": return pose.origin.y
		"LOC_Z": return pose.origin.z
	return 0.0


func _bone_quat(target: Dictionary) -> Quaternion:
	var bone := str(target.get("bone", ""))
	var sk := _find_skeleton(str(target.get("id", "")), bone)
	if sk == null:
		return Quaternion.IDENTITY
	var idx := sk.find_bone(bone)
	if idx < 0:
		return Quaternion.IDENTITY
	# Armature space, to match Blender. A parent-local rotation would disagree
	# on every bone that has a parent, which is all of them.
	return sk.get_bone_global_pose(idx).basis.get_rotation_quaternion()


func _bone_origin(target: Dictionary) -> Vector3:
	var bone := str(target.get("bone", ""))
	var sk := _find_skeleton(str(target.get("id", "")), bone)
	if sk == null:
		return Vector3.ZERO
	var idx := sk.find_bone(bone)
	return Vector3.ZERO if idx < 0 else sk.get_bone_global_pose(idx).origin


func _rest_relative_pose(sk: Skeleton3D, idx: int) -> Transform3D:
	var glob := sk.get_bone_global_pose(idx)
	var parent := sk.get_bone_parent(idx)
	var parent_glob := Transform3D.IDENTITY
	if parent >= 0:
		parent_glob = sk.get_bone_global_pose(parent)
	return sk.get_bone_rest(idx).affine_inverse() * parent_glob.affine_inverse() * glob


func _eval_curve(curve: Dictionary, x: float) -> float:
	var points: Array = curve.get("points", [])
	var xs: Array[Vector2] = []
	for p in points:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var co: Array = p.get("co", [])
		if co.size() >= 2:
			xs.append(Vector2(float(co[0]), float(co[1])))
	if xs.is_empty():
		return x
	xs.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	if x <= xs[0].x:
		return xs[0].y
	if x >= xs[-1].x:
		return xs[-1].y
	for i in range(xs.size() - 1):
		var a := xs[i]
		var b := xs[i + 1]
		if x >= a.x and x <= b.x:
			if is_equal_approx(a.x, b.x):
				return b.y
			return lerpf(a.y, b.y, (x - a.x) / (b.x - a.x))
	return xs[-1].y


func _names_equiv(a: String, b: String) -> bool:
	return a == b or a.replace(".", "_") == b.replace(".", "_")


func _find_skeleton(armature_name: String, bone_name: String) -> Skeleton3D:
	if bone_name.is_empty():
		return null
	var cache_key := armature_name + "|" + bone_name
	if _skel_cache.has(cache_key):
		var cached: Skeleton3D = _skel_cache[cache_key]
		if is_instance_valid(cached):
			return cached
		_skel_cache.erase(cache_key)
	var found: Skeleton3D = null
	var stack: Array[Node] = [_root()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is Skeleton3D):
			continue
		var sk := n as Skeleton3D
		if sk.find_bone(bone_name) < 0:
			continue
		if armature_name.is_empty():
			_skel_cache[cache_key] = sk
			return sk
		var parent_name := n.get_parent().name if n.get_parent() else ""
		if _names_equiv(n.name, armature_name) or _names_equiv(parent_name, armature_name):
			found = sk
	if found != null:
		_skel_cache[cache_key] = found
	return found


# -------------------------------------------------------------------- pushing --

func _zone_vector(rec: Dictionary, mesh: MeshInstance3D) -> Vector4:
	var zone: Variant = rec.get("zone")
	rec["zone_ok"] = false
	if typeof(zone) != TYPE_DICTIONARY or mesh == null:
		return Vector4(0.0, 0.0, 0.0, -1.0)
	var z: Dictionary = zone
	var arm := str(z.get("armature", ""))
	var bone := str(z.get("bone", ""))
	var sk := _find_skeleton(arm, bone)
	if sk == null:
		return Vector4(0.0, 0.0, 0.0, -1.0)
	var idx := sk.find_bone(bone)
	if idx < 0:
		return Vector4(0.0, 0.0, 0.0, -1.0)
	var world: Vector3 = (sk.global_transform * sk.get_bone_global_pose(idx)).origin
	var ref_name := str(z.get("ref_bone", ""))
	if not ref_name.is_empty():
		var ridx := sk.find_bone(ref_name)
		if ridx >= 0:
			var ref_world: Vector3 = (sk.global_transform * sk.get_bone_global_pose(ridx)).origin
			world = world.lerp(ref_world, clampf(float(z.get("t", 0.0)), 0.0, 1.0))
	var inv := mesh.global_transform.affine_inverse()
	var local := inv * world
	# Radius is authored in Blender world units; take it into model space too.
	var scale := mesh.global_transform.basis.get_scale()
	var avg_scale := maxf((scale.x + scale.y + scale.z) / 3.0, 0.0001)
	var radius := float(z.get("radius", 0.15)) * zone_radius_scale / avg_scale
	rec["zone_ok"] = true
	var out := Vector4(local.x, local.y, local.z, radius)
	rec["last_zone"] = out
	return out


func _push() -> void:
	for mat_name in _targets:
		var entry: Dictionary = _targets[mat_name]
		var mesh: MeshInstance3D = entry["mesh"]
		var pack := Vector4.ZERO
		var zones: Array[Vector4] = [
			Vector4(0.0, 0.0, 0.0, -1.0), Vector4(0.0, 0.0, 0.0, -1.0),
			Vector4(0.0, 0.0, 0.0, -1.0), Vector4(0.0, 0.0, 0.0, -1.0),
		]
		for name in _order:
			var rec: Dictionary = _channels[name]
			if str(rec["material"]) != mat_name:
				continue
			var slot := int(rec["slot"])
			var v := float(rec["value"])
			match slot:
				0: pack.x = v
				1: pack.y = v
				2: pack.z = v
				3: pack.w = v
			zones[slot] = _zone_vector(rec, mesh)
		for mat in entry["materials"]:
			_push_material(mat as ShaderMaterial, pack, zones)


func _push_material(mat: ShaderMaterial, pack: Vector4, zones: Array[Vector4]) -> void:
	# Walk the next_pass chain too: the skin preset stacks rain + outline, and a
	# wrinkle that only lands on the base pass reads as a seam.
	var walk: Material = mat
	var guard := 0
	while walk != null and guard < 8:
		guard += 1
		if walk is ShaderMaterial:
			var sm := walk as ShaderMaterial
			sm.set_shader_parameter("pf_ch", pack)
			for i in SLOT_COUNT:
				sm.set_shader_parameter("pf_zone_%d" % i, zones[i])
			sm.set_shader_parameter("pf_zone_debug", zone_debug)
		walk = walk.next_pass


# ---------------------------------------------------------------- calibration --

## Blender euler components and Godot bone euler components do not line up
## after the Y-up conversion. The exporter ships a few frames of ground truth;
## match each component against them once and remember the mapping.
## True only while some channel still reads a raw euler component. ROTATION_DIFF
## channels are already frame-of-reference agnostic and need no fitting.
func _needs_calibration() -> bool:
	for name in _order:
		for v in _channels[name]["variables"]:
			if str(v.get("type", "")) == "TRANSFORMS":
				return true
	return false


func _maybe_calibrate() -> void:
	if _calibrated or not _needs_calibration():
		return
	if _player == null:
		_player = _find_player()
	if _player == null or not _player.is_playing():
		return
	var frame := int(round(_player.current_animation_position * _fps))
	for name in _order:
		var rec: Dictionary = _channels[name]
		for s in rec["verify_samples"]:
			if int(s.get("frame", -999)) == frame:
				_collect_sample(rec, s)
	_try_lock()


func _collect_sample(rec: Dictionary, sample: Dictionary) -> void:
	var expected: Dictionary = sample.get("variables", {})
	var frame := int(sample.get("frame", 0))
	# Frame 0 is the rest pose: every component reads 0, so every axis ties and
	# the fit is meaningless. Only samples with actual signal teach anything.
	var has_signal := false
	for k in expected:
		if absf(float(expected[k])) > 0.02:
			has_signal = true
			break
	if not has_signal:
		return
	for v in rec["variables"]:
		if str(v.get("type", "")) != "TRANSFORMS":
			continue
		var targets: Array = v.get("targets", [])
		if targets.is_empty():
			continue
		var t: Dictionary = targets[0]
		var arm := str(t.get("id", ""))
		var bone := str(t.get("bone", ""))
		var ttype := str(t.get("transform_type", "ROT_Z"))
		var sk := _find_skeleton(arm, bone)
		if sk == null:
			continue
		var idx := sk.find_bone(bone)
		if idx < 0:
			continue
		var key := "%s|%s|%s" % [arm, bone, ttype]
		if not _sample_buf.has(key):
			_sample_buf[key] = []
		var rows: Array = _sample_buf[key]
		for existing in rows:
			if int(existing["frame"]) == frame:
				return
		rows.append({
			"frame": frame,
			"e": _rest_relative_pose(sk, idx).basis.get_euler(),
			"expected": float(expected.get(str(v.get("name", "")), 0.0)),
		})


func _try_lock() -> void:
	if _sample_buf.is_empty():
		return
	# Lock each component on its own. Requiring every key to be ready first let
	# one barely-moving bone (FeetFoldR standing still) hold up calibration for
	# every other channel.
	var pending := false
	for k in _sample_buf.keys():
		if _axis_maps.has(k):
			continue
		var rows: Array = _sample_buf[k]
		if rows.size() < 3:
			pending = true
			continue
		var best_axis := 2
		var best_sign := 1.0
		var best_err := INF
		for axis in range(3):
			for sign in [1.0, -1.0]:
				var err := 0.0
				for row in rows:
					var e: Vector3 = row["e"]
					var comp := e.x if axis == 0 else (e.y if axis == 1 else e.z)
					err += absf(sign * comp - float(row["expected"]))
				err /= float(rows.size())
				if err < best_err:
					best_err = err
					best_axis = axis
					best_sign = sign
		_axis_maps[k] = {"axis": best_axis, "sign": best_sign, "error": best_err}
		_calib_error = maxf(_calib_error, best_err)
	_calibrated = not pending


func _find_player() -> AnimationPlayer:
	var stack: Array[Node] = [_root()]
	var best: AnimationPlayer = null
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is AnimationPlayer:
			var ap := n as AnimationPlayer
			if best == null or ap.get_animation_list().size() > best.get_animation_list().size():
				best = ap
	return best
