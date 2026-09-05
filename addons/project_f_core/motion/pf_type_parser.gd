extends RefCounted
class_name PFTypeParser

## Parses the Type* bone-name contract and returns chain profiles.
## TypeNone is intentionally omitted — that prefix is Blender-driver only.

const PREFIX_JIGGLE := "TypeJiggle."
const PREFIX_HAIR := "TypeHair."
const PREFIX_CLOTH := "TypeCloth."
const PREFIX_NONE := "TypeNone."


static func type_of(bone_name: String) -> String:
	if bone_name.begins_with(PREFIX_JIGGLE):
		return "jiggle"
	if bone_name.begins_with(PREFIX_HAIR):
		return "hair"
	if bone_name.begins_with(PREFIX_CLOTH):
		return "cloth"
	if bone_name.begins_with(PREFIX_NONE):
		return "none"
	return ""


static func discover_profiles(skeleton: Skeleton3D) -> Array[PFMotionProfile]:
	var out: Array[PFMotionProfile] = []
	if skeleton == null:
		return out
	out.append_array(_chains_for(skeleton, PREFIX_JIGGLE, PFMotionProfile.ChainKind.JIGGLE))
	out.append_array(_chains_for(skeleton, PREFIX_HAIR, PFMotionProfile.ChainKind.HAIR))
	out.append_array(_chains_for(skeleton, PREFIX_CLOTH, PFMotionProfile.ChainKind.CLOTH))
	return out


static func _chains_for(skeleton: Skeleton3D, prefix: String, kind: PFMotionProfile.ChainKind) -> Array[PFMotionProfile]:
	var typed: Dictionary = {} # index -> name
	for i in skeleton.get_bone_count():
		var n := String(skeleton.get_bone_name(i))
		if n.begins_with(prefix):
			typed[i] = n
	var leaves: Array[int] = []
	for idx: int in typed:
		var has_typed_child := false
		for child in skeleton.get_bone_children(idx):
			if typed.has(child):
				has_typed_child = true
				break
		if not has_typed_child:
			leaves.append(idx)
	var seen: Dictionary = {}
	var profiles: Array[PFMotionProfile] = []
	for leaf in leaves:
		var walk := leaf
		var root := leaf
		while true:
			var parent := skeleton.get_bone_parent(walk)
			if parent < 0 or not typed.has(parent):
				root = walk
				break
			walk = parent
		var key := "%d:%d" % [root, leaf]
		if seen.has(key):
			continue
		seen[key] = true
		var root_name: String = typed[root]
		var leaf_name: String = typed[leaf]
		if root == leaf:
			# Single-bone chain: still solvable if we treat it as root=parent's child with a virtual tip.
			# Skip — the inertial solver needs a segment (two bones).
			continue
		var id := StringName("%s%s" % [prefix, _chain_id(root_name, prefix)])
		profiles.append(PFMotionProfile.make(id, kind, StringName(root_name), StringName(leaf_name)))
	return profiles


static func _chain_id(root_name: String, prefix: String) -> String:
	var rest := root_name.trim_prefix(prefix)
	var parts := rest.split(".")
	var kept: PackedStringArray = []
	for p in parts:
		if not p.is_valid_int():
			kept.append(p)
	return ".".join(kept)
