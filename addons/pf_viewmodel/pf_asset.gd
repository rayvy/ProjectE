@tool
class_name PFAsset
extends Node3D

## One exported thing: the arms rig, a weapon, a bottle. The .tscn the Blender
## add-on writes already has this script and its manifest path filled in, so
## dropping the scene into a level is the whole setup.
##
## Its job is small on purpose - own a skeleton, hand out sockets by name, and
## say what clips it claims to have. Playback belongs to PFViewmodel, because
## a clip usually moves two of these at once.

@export_file("*.json") var manifest_path: String = "":
	set(value):
		manifest_path = value
		if is_inside_tree():
			reload()

## Draw a small marker at every socket. Handy while placing SK.* in Blender.
@export var debug_sockets: bool = false:
	set(value):
		debug_sockets = value
		_refresh_debug()

var manifest: PFManifest = null
var skeleton: Skeleton3D = null

var _sockets: Dictionary = {}          # socket id -> Node3D
var _debug_nodes: Array[Node3D] = []


func _ready() -> void:
	reload()


func reload() -> void:
	manifest = PFManifest.from_file(manifest_path) if not manifest_path.is_empty() else null
	skeleton = _find_skeleton(self)
	_sockets.clear()
	if manifest != null and not manifest.is_valid():
		push_warning("PFAsset %s: %s" % [name, manifest.error])
	# Build every socket up front. They are one BoneAttachment3D each, and
	# having them in the tree is what makes a live scene inspectable - a socket
	# that only exists once somebody asks for it cannot be checked.
	for socket_id in socket_ids():
		socket(socket_id)
	_refresh_debug()


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func skeleton_path_from(origin: Node) -> NodePath:
	return origin.get_path_to(skeleton) if skeleton != null else NodePath()


## The attachment point named `socket_id`, made on first use.
## Returns null when the socket is not in this asset's manifest - callers are
## expected to check, because a missing socket means a rig change, not a bug
## worth crashing over.
func socket(socket_id: String) -> Node3D:
	if _sockets.has(socket_id):
		var cached: Node3D = _sockets[socket_id]
		if is_instance_valid(cached):
			return cached
	if manifest == null:
		return null
	# A weapon's manifest lists the arms' sockets too, so that one file
	# describes the whole pairing. Serving them here would look for SK.cam in
	# the rifle; whoever asked falls through to the rig instead.
	var owned_by_rig := manifest.socket_owner(socket_id) == "rig"
	if owned_by_rig != (manifest.kind == "RIG"):
		return null

	var bone := manifest.socket_bone(socket_id)
	var node: Node3D = null
	if not bone.is_empty() and skeleton != null:
		if skeleton.find_bone(bone) < 0:
			push_warning("PFAsset %s: manifest names bone '%s' but the skeleton has no such bone"
				% [name, bone])
			return null
		var attachment := BoneAttachment3D.new()
		attachment.name = "SK_" + socket_id.replace(".", "_")
		attachment.bone_name = bone
		skeleton.add_child(attachment)
		node = attachment
	else:
		# A rigid prop carries Empties instead of bones; glTF made them nodes.
		node = _find_named(self, "SK." + socket_id) as Node3D
	if node != null:
		_sockets[socket_id] = node
	return node


func socket_ids() -> PackedStringArray:
	if manifest == null:
		return PackedStringArray()
	var out := PackedStringArray()
	for key: String in manifest.sockets:
		out.append(key)
	out.sort()
	return out


func _find_named(node: Node, wanted: String) -> Node:
	if node.name == wanted:
		return node
	for child in node.get_children():
		var found := _find_named(child, wanted)
		if found != null:
			return found
	return null


func _refresh_debug() -> void:
	for node in _debug_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_debug_nodes.clear()
	if not debug_sockets or manifest == null:
		return
	for socket_id in socket_ids():
		var anchor := socket(socket_id)
		if anchor == null:
			continue
		var marker := _marker(socket_id)
		anchor.add_child(marker)
		_debug_nodes.append(marker)


func _marker(label: String) -> Node3D:
	var root := Node3D.new()
	root.name = "debug_" + label.replace(".", "_")
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.012
	mesh.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.35, 0.0)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	mesh.material_override = material
	root.add_child(mesh)
	var text := Label3D.new()
	text.text = label
	text.pixel_size = 0.0006
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text.no_depth_test = true
	text.modulate = Color(1.0, 0.7, 0.3)
	text.position = Vector3(0.0, 0.02, 0.0)
	root.add_child(text)
	return root
