extends RefCounted
class_name PFColliderSet

## Body colliders authored in Blender, replayed against the Verlet chains.
##
## The old set was nineteen hardcoded bone names with hardcoded round radii.
## A torso is not round — roughly 0.16 wide by 0.10 deep — so one radius is
## either too small at the sides (cloth sinks in) or too large front and back
## (cloth floats). That is the clipping.
##
## So a collider is now a shape you model in Blender, parented to a bone, and
## every shape carries a **per-axis** radius. An ellipsoid costs the same as a
## sphere here: the test is done in the collider's own space, where dividing by
## the radius makes it round again.
##
## Everything is stored in **bone space**, which survives Blender's Z-up to
## Godot's Y-up conversion untouched — the glTF converter rotates the root, not
## each joint's own axes.

enum Shape { SPHERE, CAPSULE, BOX }

const _SHAPE_NAMES := {"sphere": Shape.SPHERE, "capsule": Shape.CAPSULE, "box": Shape.BOX}


class Collider extends RefCounted:
	var name: String = ""
	var bone_name: String = ""
	var bone_index: int = -1
	var shape: int = Shape.CAPSULE
	## Placement inside the bone, including orientation.
	var local: Transform3D = Transform3D.IDENTITY
	## Semi-axes. A sphere with unequal components is an ellipsoid. A capsule
	## uses x and z for its cross-section and derives its cap from them; its y
	## component is unused, the cylinder length lives in `height`.
	var radius: Vector3 = Vector3.ONE * 0.05
	## Cylindrical part of a capsule, or the y semi-extent of a box.
	var height: float = 0.0
	## Chains rooted at these bones ignore this collider, so a skirt does not
	## fight the hip it hangs from.
	var ignore_chains: PackedStringArray = PackedStringArray()

	# Recomputed each frame, in the simulated skeleton's space.
	var xform: Transform3D = Transform3D.IDENTITY
	var inv_xform: Transform3D = Transform3D.IDENTITY


var colliders: Array[Collider] = []
var source_path: String = ""


func load_from(path: String, skeleton: Skeleton3D) -> int:
	colliders.clear()
	source_path = path
	if path.is_empty() or not FileAccess.file_exists(path):
		return 0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PFColliderSet: invalid JSON at %s" % path)
		return 0
	for raw in (parsed as Dictionary).get("colliders", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var c := _from_dict(raw, skeleton)
		if c != null:
			colliders.append(c)
	return colliders.size()


func _from_dict(raw: Dictionary, skeleton: Skeleton3D) -> Collider:
	var bone := str(raw.get("bone", ""))
	if skeleton == null or bone.is_empty():
		return null
	var idx := skeleton.find_bone(bone)
	if idx < 0:
		push_warning("PFColliderSet: no bone '%s' for collider '%s'" % [bone, raw.get("name", "?")])
		return null
	var c := Collider.new()
	c.name = str(raw.get("name", bone))
	c.bone_name = bone
	c.bone_index = idx
	c.shape = _SHAPE_NAMES.get(str(raw.get("shape", "capsule")).to_lower(), Shape.CAPSULE)
	c.radius = _vec3(raw.get("radius"), Vector3.ONE * 0.05)
	c.height = float(raw.get("height", 0.0))
	var basis_rows: Variant = raw.get("basis")
	var basis := Basis.IDENTITY
	if typeof(basis_rows) == TYPE_ARRAY and (basis_rows as Array).size() == 3:
		var rows: Array = basis_rows
		basis = Basis(_vec3(rows[0], Vector3.RIGHT), _vec3(rows[1], Vector3.UP), _vec3(rows[2], Vector3.BACK))
	c.local = Transform3D(basis, _vec3(raw.get("offset"), Vector3.ZERO))
	for n in raw.get("ignore_chains", []):
		c.ignore_chains.append(str(n))
	# Degenerate radii would divide by zero in the push-out.
	c.radius = Vector3(maxf(c.radius.x, 0.001), maxf(c.radius.y, 0.001), maxf(c.radius.z, 0.001))
	return c


static func _vec3(value: Variant, fallback: Vector3) -> Vector3:
	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		var a: Array = value
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback


## Refresh every collider into *sim_skeleton* space for this frame.
func update(source: Skeleton3D, sim_skeleton: Skeleton3D) -> void:
	if source == null or sim_skeleton == null:
		return
	var to_sim := sim_skeleton.global_transform.affine_inverse() * source.global_transform
	for c in colliders:
		c.xform = to_sim * source.get_bone_global_pose(c.bone_index) * c.local
		c.inv_xform = c.xform.affine_inverse()


## Push *p* (sim-skeleton space) out of every collider it is inside.
func resolve(p: Vector3, chain_root: String) -> Vector3:
	for c in colliders:
		if not c.ignore_chains.is_empty() and c.ignore_chains.has(chain_root):
			continue
		p = push_out(p, c)
	return p


static func push_out(p: Vector3, c: Collider) -> Vector3:
	var local: Vector3 = c.inv_xform * p
	var fixed: Vector3
	match c.shape:
		Shape.BOX:
			fixed = _push_box(local, c.radius)
		Shape.SPHERE:
			fixed = _push_ellipsoid(local, c.radius)
		_:
			fixed = _push_capsule(local, c.radius, c.height)
	if fixed == local:
		return p
	return c.xform * fixed


## Scaling to unit space makes an ellipsoid a sphere; the push direction is then
## exact in that space and only approximate once scaled back, which is what any
## soft-body solver wants anyway.
static func _push_ellipsoid(local: Vector3, radius: Vector3) -> Vector3:
	var q := local / radius
	var d := q.length()
	if d >= 1.0:
		return local
	if d < 0.00001:
		return Vector3(0.0, radius.y, 0.0)
	return (q / d) * radius


static func _push_capsule(local: Vector3, radius: Vector3, height: float) -> Vector3:
	var half := maxf(height, 0.0) * 0.5
	var y := clampf(local.y, -half, half)
	# The rounded end is a cap on the cross-section, so its along-axis extent
	# comes from x and z. radius.y describes nothing on a capsule, and reading
	# it here turned the caps into whatever happened to be in that component.
	var cap := Vector3(radius.x, (radius.x + radius.z) * 0.5, radius.z)
	var offset := Vector3(local.x, local.y - y, local.z)
	var q := offset / cap
	var d := q.length()
	if d >= 1.0:
		return local
	if d < 0.00001:
		return Vector3(cap.x, y, 0.0)
	var pushed := (q / d) * cap
	return Vector3(pushed.x, y + pushed.y, pushed.z)


## Boxes leave along the face they are least deep into, so a particle that has
## just crossed a surface comes back out the way it came in.
static func _push_box(local: Vector3, half: Vector3) -> Vector3:
	var depth := half - local.abs()
	if depth.x <= 0.0 or depth.y <= 0.0 or depth.z <= 0.0:
		return local
	var out := local
	if depth.x <= depth.y and depth.x <= depth.z:
		out.x = half.x if local.x >= 0.0 else -half.x
	elif depth.y <= depth.z:
		out.y = half.y if local.y >= 0.0 else -half.y
	else:
		out.z = half.z if local.z >= 0.0 else -half.z
	return out


func debug_lines(segments: int = 12) -> PackedVector3Array:
	"""Wireframe of every collider, in sim-skeleton space, for an ImmediateMesh."""
	var out := PackedVector3Array()
	for c in colliders:
		match c.shape:
			Shape.BOX:
				_box_lines(out, c)
			Shape.SPHERE:
				_ring_lines(out, c, c.radius, 0.0, segments)
			_:
				var half := c.height * 0.5
				_ring_lines(out, c, c.radius, half, segments)
				_ring_lines(out, c, c.radius, -half, segments)
				for s in 4:
					var a := TAU * float(s) / 4.0
					var d := Vector3(cos(a) * c.radius.x, 0.0, sin(a) * c.radius.z)
					out.append(c.xform * (d + Vector3(0.0, half, 0.0)))
					out.append(c.xform * (d - Vector3(0.0, half, 0.0)))
	return out


func _ring_lines(out: PackedVector3Array, c: Collider, r: Vector3, y: float, segments: int) -> void:
	for plane in 3:
		for s in segments:
			var a0 := TAU * float(s) / float(segments)
			var a1 := TAU * float(s + 1) / float(segments)
			var p0 := _ring_point(plane, a0, r, y)
			var p1 := _ring_point(plane, a1, r, y)
			out.append(c.xform * p0)
			out.append(c.xform * p1)
		if c.shape != Shape.SPHERE:
			break


static func _ring_point(plane: int, a: float, r: Vector3, y: float) -> Vector3:
	match plane:
		1:
			return Vector3(cos(a) * r.x, sin(a) * r.y + y, 0.0)
		2:
			return Vector3(0.0, sin(a) * r.y + y, cos(a) * r.z)
		_:
			return Vector3(cos(a) * r.x, y, sin(a) * r.z)


func _box_lines(out: PackedVector3Array, c: Collider) -> void:
	var h := c.radius
	var corners: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				corners.append(Vector3(h.x * sx, h.y * sy, h.z * sz))
	var edges := [[0,1],[1,3],[3,2],[2,0],[4,5],[5,7],[7,6],[6,4],[0,4],[1,5],[2,6],[3,7]]
	for e in edges:
		out.append(c.xform * corners[e[0]])
		out.append(c.xform * corners[e[1]])
