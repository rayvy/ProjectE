@tool
class_name PFManifest
extends RefCounted

## Reads what the Blender add-on wrote. Nothing here decides anything - it
## parses, validates shape, and hands back typed accessors.
##
## The contract lives in tools/blender/godot_fps_export/contract.py and in
## docs/FPS_ANIMATION_CONTRACT.txt. If a field disappears from under this
## script, the export version changed and both halves need looking at.

const SUPPORTED_VERSION := 1
const CONTENT_INDEX := "res://content/fps_contract.json"

var id: String = ""
var kind: String = ""
var rig_id: String = ""
var mount_socket: String = ""
var fps: float = 60.0
var model_path: String = ""
var anim_path: String = ""
var source_blend: String = ""
var notes: String = ""

## socket id -> { space, bone/node, owner }
var sockets: Dictionary = {}
## role ("rig" / "asset") -> { object, bones: PackedStringArray, deform }
var skeletons: Dictionary = {}
## clip id -> clip record
var clips: Dictionary = {}
var warnings: PackedStringArray = []

var _raw: Dictionary = {}
var error: String = ""


static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("PFManifest: no file at %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("PFManifest: %s is not a JSON object" % path)
		return {}
	return parsed


## The content index: every asset the .blend exported, by id.
static func load_index() -> Dictionary:
	var data := load_json(CONTENT_INDEX)
	var out := {}
	for row: Variant in data.get("assets", []):
		if typeof(row) == TYPE_DICTIONARY and row.has("id"):
			out[String(row["id"])] = row
	return out


static func from_file(path: String) -> PFManifest:
	var manifest := PFManifest.new()
	manifest._parse(load_json(path), path)
	return manifest


func _parse(data: Dictionary, path: String) -> void:
	_raw = data
	if data.is_empty():
		error = "empty or unreadable: %s" % path
		return
	var version := int(data.get("version", 0))
	if version != SUPPORTED_VERSION:
		# Not fatal: a newer export usually only adds keys. Say so and carry on,
		# because refusing to load would hide the rest of the file's problems.
		warnings.append("manifest version %d, this runtime speaks %d"
			% [version, SUPPORTED_VERSION])
	id = String(data.get("id", ""))
	kind = String(data.get("kind", ""))
	rig_id = String(data.get("rig", ""))
	mount_socket = String(data.get("mount_socket", ""))
	fps = float(data.get("fps", 60.0))
	model_path = String(data.get("model", ""))
	anim_path = String(data.get("anim", ""))
	source_blend = String(data.get("source_blend", ""))
	notes = String(data.get("notes", ""))
	sockets = data.get("sockets", {})
	skeletons = data.get("skeletons", {})
	clips = data.get("clips", {})
	for w: Variant in data.get("warnings", []):
		warnings.append(String(w))


func is_valid() -> bool:
	return error.is_empty() and not id.is_empty()


func clip_ids(include_stubs: bool = false) -> PackedStringArray:
	var out := PackedStringArray()
	for key: String in clips:
		if include_stubs or not bool(clips[key].get("stub", false)):
			out.append(key)
	out.sort()
	return out


func clip(clip_id: String) -> Dictionary:
	return clips.get(clip_id, {})


func has_clip(clip_id: String) -> bool:
	return clips.has(clip_id)


## Bone names belonging to one half of the animation, for track remapping.
func bones_of(role: String) -> PackedStringArray:
	var record: Dictionary = skeletons.get(role, {})
	var out := PackedStringArray()
	for name: Variant in record.get("bones", []):
		out.append(String(name))
	return out


func socket_bone(socket_id: String) -> String:
	var record: Dictionary = sockets.get(socket_id, {})
	if String(record.get("space", "")) != "bone":
		return ""
	return String(record.get("bone", ""))


func socket_owner(socket_id: String) -> String:
	return String(sockets.get(socket_id, {}).get("owner", ""))


func loop_mode_of(clip_id: String) -> Animation.LoopMode:
	match String(clip(clip_id).get("loop", "NONE")):
		"LINEAR":
			return Animation.LOOP_LINEAR
		"PINGPONG":
			return Animation.LOOP_PINGPONG
		_:
			return Animation.LOOP_NONE


func describe() -> String:
	var animated := clip_ids(false).size()
	var total := clips.size()
	return "%s (%s) - %d/%d clips animated, %d sockets" % [
		id, kind, animated, total, sockets.size()]
