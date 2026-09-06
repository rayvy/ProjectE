@tool
class_name PFClipBinder
extends RefCounted

## Re-points imported animation tracks at the skeletons that actually exist.
##
## The anim .glb holds two skeletons side by side, so its tracks read
## "Rig/Skeleton3D:hand.R" and "Proxy/Skeleton3D:bolt". In the game the arms
## and the weapon are separate scenes, sitting wherever the viewmodel put
## them, so those paths resolve to nothing.
##
## Rebinding is done by **bone name**, not by the node prefix in the .glb.
## The manifest lists which bones belong to which skeleton, so a bone finds
## its home even if the exporter renames a node or someone reorganises the
## viewmodel scene. Tracks whose bone belongs to neither skeleton - the skin
## anchor's own object track, for instance - are dropped rather than left
## pointing at nothing and warning once per frame.

## Returns an AnimationLibrary whose animations are ready for `player`,
## or null when the anim file is missing.
static func build_library(
		manifest: PFManifest,
		rig_skeleton: NodePath,
		asset_skeleton: NodePath) -> AnimationLibrary:
	if manifest == null or manifest.anim_path.is_empty():
		return null
	if not ResourceLoader.exists(manifest.anim_path):
		push_warning("PFClipBinder: no anim file at %s" % manifest.anim_path)
		return null

	var packed: PackedScene = load(manifest.anim_path)
	if packed == null:
		return null
	var scene: Node = packed.instantiate()
	var player := _find_player(scene)
	if player == null:
		scene.free()
		push_warning("PFClipBinder: %s has no AnimationPlayer" % manifest.anim_path)
		return null

	var owner_of := _bone_owner_table(manifest)
	var targets := {"rig": rig_skeleton, "asset": asset_skeleton}
	var library := AnimationLibrary.new()

	for source_name: StringName in player.get_animation_list():
		var animation: Animation = player.get_animation(source_name).duplicate(true)
		var clip_id := String(source_name)
		_rebind(animation, owner_of, targets)
		animation.loop_mode = manifest.loop_mode_of(clip_id)
		library.add_animation(StringName(clip_id), animation)

	scene.free()
	return library


static func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


## bone name -> "rig" | "asset"
static func _bone_owner_table(manifest: PFManifest) -> Dictionary:
	var table := {}
	for role in ["rig", "asset"]:
		for bone in manifest.bones_of(role):
			# First writer wins: a name shared by both skeletons stays with the
			# rig, which is the only one guaranteed to be present.
			if not table.has(bone):
				table[bone] = role
	return table


static func _rebind(animation: Animation, owner_of: Dictionary, targets: Dictionary) -> void:
	for index in range(animation.get_track_count() - 1, -1, -1):
		var path := animation.track_get_path(index)
		var bone := String(path.get_concatenated_subnames())
		var role: String = owner_of.get(bone, "")
		var target: NodePath = targets.get(role, NodePath())
		if bone.is_empty() or target.is_empty():
			animation.remove_track(index)
			continue
		animation.track_set_path(index, NodePath("%s:%s" % [String(target), bone]))
