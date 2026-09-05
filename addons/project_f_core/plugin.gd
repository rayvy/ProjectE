@tool
extends EditorPlugin

## Stamps imported/character GLBs with the material post-import script
## so a Blender re-export remaps shaders with zero Import-dock clicks.

const IMPORT_SCRIPT := "res://addons/project_f_core/import/pf_material_post_import.gd"
const WATCH_PREFIX := "res://imported/"

var _fs: EditorFileSystem
var _pending: PackedStringArray = PackedStringArray()


func _enter_tree() -> void:
	_fs = get_editor_interface().get_resource_filesystem()
	if _fs:
		_fs.resources_reimported.connect(_on_reimported)
		_fs.filesystem_changed.connect(_scan_and_stamp)
	_scan_and_stamp()


func _exit_tree() -> void:
	if _fs:
		if _fs.resources_reimported.is_connected(_on_reimported):
			_fs.resources_reimported.disconnect(_on_reimported)
		if _fs.filesystem_changed.is_connected(_scan_and_stamp):
			_fs.filesystem_changed.disconnect(_scan_and_stamp)


func _on_reimported(_files: PackedStringArray) -> void:
	_scan_and_stamp()


func _scan_and_stamp() -> void:
	var dirty: PackedStringArray = PackedStringArray()
	_collect_glbs("res://imported", dirty)
	for path in dirty:
		if _stamp_import_script(path):
			if _fs:
				_fs.reimport_files(PackedStringArray([path]))


func _collect_glbs(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			_collect_glbs(full, out)
		elif name.ends_with(".glb"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _stamp_import_script(glb_path: String) -> bool:
	var import_path := glb_path + ".import"
	if not FileAccess.file_exists(import_path):
		return false
	var cfg := ConfigFile.new()
	if cfg.load(import_path) != OK:
		return false
	var current := str(cfg.get_value("params", "import_script/path", ""))
	if current == IMPORT_SCRIPT:
		return false
	cfg.set_value("params", "import_script/path", IMPORT_SCRIPT)
	if cfg.save(import_path) != OK:
		push_warning("PF import: could not stamp %s" % import_path)
		return false
	print("[PF Material Remap] stamped import script on %s" % glb_path)
	return true
