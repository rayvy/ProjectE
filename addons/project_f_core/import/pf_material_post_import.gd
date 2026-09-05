@tool
extends EditorScenePostImport

## Assigned on imported/character/*.glb. Remaps Mat.* / PF_Mat.* to Project F shaders.


func _post_import(scene: Node) -> Object:
	var sidecar := get_source_file().get_basename() + ".materials.json"
	var applier := PFMaterialApplier.new()
	var count := applier.apply_to_tree(scene, sidecar)
	print("[PF Material Remap] assigned %d surfaces in %s" % [count, get_source_file()])
	for warning in applier.warnings:
		push_warning("[PF Material Remap] " + warning)
	return scene
