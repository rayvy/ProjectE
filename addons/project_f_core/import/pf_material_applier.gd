extends RefCounted
class_name PFMaterialApplier

## Binds Project F shader presets onto imported meshes.
## Textures come from the imported StandardMaterial3D first, then sidecar maps.

var assignment_count: int = 0
var warnings: PackedStringArray = PackedStringArray()
var _sidecar: Dictionary = {}


func apply_to_tree(root: Node, sidecar_path: String = "") -> int:
	assignment_count = 0
	warnings.clear()
	_sidecar.clear()
	if not sidecar_path.is_empty() and FileAccess.file_exists(sidecar_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
		if parsed is Dictionary:
			_index_sidecar(parsed)
	_walk(root)
	return assignment_count


func _index_sidecar(data: Dictionary) -> void:
	var mats: Variant = data.get("materials", [])
	if typeof(mats) != TYPE_ARRAY:
		return
	for entry in mats:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var name := str(entry.get("name", ""))
		if name.is_empty():
			continue
		_sidecar[name] = entry


func _walk(node: Node) -> void:
	if node is MeshInstance3D:
		_apply_mesh(node as MeshInstance3D)
	for child in node.get_children():
		_walk(child)


func _apply_mesh(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	for surface in mesh_instance.mesh.get_surface_count():
		var source := mesh_instance.get_surface_override_material(surface)
		if source == null:
			source = mesh_instance.mesh.surface_get_material(surface)
		if source == null:
			warnings.append("%s surface %d has no material" % [mesh_instance.name, surface])
			continue
		if source is ShaderMaterial:
			var existing := source as ShaderMaterial
			var shader_path := str(existing.shader.resource_path) if existing.shader else ""
			if shader_path.begins_with("res://shaders/") and not shader_path.ends_with("skin_face_sdf.gdshader"):
				var existing_kind := PFMaterialRules.classify(existing.resource_name)
				if existing_kind == "eyes":
					mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				continue
		var material_name := source.resource_name
		if material_name.is_empty():
			material_name = str(source.get("name")) if source.get("name") else ""
		var sidecar: Dictionary = {}
		if _sidecar.has(material_name) and typeof(_sidecar[material_name]) == TYPE_DICTIONARY:
			sidecar = _sidecar[material_name]
		var group_name := str(sidecar.get("group", ""))
		var kind := str(sidecar.get("family", ""))
		if kind.is_empty():
			kind = PFMaterialRules.classify(material_name, group_name)
		if kind == "face":
			kind = "skin"
		if kind.is_empty():
			warnings.append("leaving unknown material '%s' on %s[%d]" % [material_name, mesh_instance.name, surface])
			continue
		if kind == "skin" and _is_alpha_card(source, mesh_instance.name):
			mesh_instance.set_surface_override_material(surface, _build_lash_card(source))
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			assignment_count += 1
			continue
		var replacement := _make_preset(kind, source, material_name, sidecar)
		if replacement == null:
			warnings.append("preset missing for %s (%s)" % [material_name, kind])
			continue
		replacement.resource_name = material_name
		if kind == "skin":
			# Forced to 0 for now: the baked PF_SkinData AO/curvature channel
			# shows a hard rectangular patch wherever Subdivision Surface
			# meets one of the mesh's n-gons (Catmull-Clark averages the
			# n-gon's virtual center from its corner colors, which can read
			# as a flat block against the smoothly-interpolated quads around
			# it). Confirmed live: toggling baked_channels_strength to 0
			# removes the patch entirely and falls back to the procedural
			# skin_support_pack AO, which has no such artifact. Re-enable
			# once the bake either avoids n-gons or blends across them.
			var baked := 0.0
			var pass_mat: Material = replacement
			var guard := 0
			while pass_mat != null and guard < 6:
				guard += 1
				if pass_mat is ShaderMaterial:
					(pass_mat as ShaderMaterial).set_shader_parameter("baked_channels_strength", baked)
				pass_mat = pass_mat.next_pass
		mesh_instance.set_surface_override_material(surface, replacement)
		if kind == "eyes":
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Hair now casts shadows (hair_endfield.gdshader sets ALPHA_SCISSOR_THRESHOLD,
		# which Godot's shadow pass honors, so strands shadow correctly rather than
		# as a solid card). Flat, shadowless hair on the face/neck was part of why
		# the face read as cheap next to a reference like Kiriko's.
		assignment_count += 1


func _is_alpha_card(source: Material, mesh_name: String) -> bool:
	if mesh_name.begins_with("Eyes+Eyebrow+Eyelashes"):
		return true
	var base := source as BaseMaterial3D
	return base != null and base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED


func _build_lash_card(source: Material) -> Material:
	var card: BaseMaterial3D
	if source is BaseMaterial3D:
		card = (source as BaseMaterial3D).duplicate(true) as BaseMaterial3D
	else:
		card = StandardMaterial3D.new()
	card.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	card.alpha_scissor_threshold = 0.42
	card.cull_mode = BaseMaterial3D.CULL_DISABLED
	return card


func _make_preset(kind: String, source: Material, material_name: String, sidecar: Dictionary) -> Material:
	var preset := load(PFMaterialRules.preset_path(kind)) as Material
	if preset == null:
		return null
	var instance := preset.duplicate(true) as Material
	instance.resource_name = material_name
	_bind_textures(instance, source, kind, sidecar)
	if kind == "skin":
		_ensure_skin_chain(instance as ShaderMaterial, source, kind, sidecar)
	return instance


func _ensure_skin_chain(result: ShaderMaterial, source: Material, kind: String, sidecar: Dictionary) -> void:
	if result == null:
		return
	var outline := load(PFMaterialRules.OUTLINE_PRESET) as ShaderMaterial
	var rain := load(PFMaterialRules.RAIN_PRESET) as ShaderMaterial
	if outline:
		outline = outline.duplicate(true) as ShaderMaterial
		_bind_shader_maps(outline, source, kind, sidecar)
	if rain:
		rain = rain.duplicate(true) as ShaderMaterial
		result.next_pass = rain
		rain.next_pass = outline
	else:
		result.next_pass = outline


func _bind_textures(instance: Material, source: Material, kind: String, sidecar: Dictionary) -> void:
	if instance is ShaderMaterial:
		_bind_shader_maps(instance as ShaderMaterial, source, kind, sidecar)
	elif instance is BaseMaterial3D:
		_bind_standard(instance as BaseMaterial3D, source)


func _bind_shader_maps(target: ShaderMaterial, source: Material, kind: String, sidecar: Dictionary) -> void:
	# Everything the Blender PF_Mat group exposed, applied by name. A socket
	# added in Blender lands here as a shader parameter with no code change;
	# a shader that does not declare it simply ignores the write.
	_apply_generic(target, sidecar)
	_apply_legacy_fallbacks(target, source, kind, sidecar)


## PF_SkinData/PF_SkinAux are read straight from COLOR/UV1 by the skin shader,
## never through a Blender material node, so there is no socket in the PF_Mat
## contract for "does this mesh have baked channels" — it is a property of the
## mesh's vertex data, not of the material. Detect it directly instead.
func _has_vertex_colors(mesh_instance: MeshInstance3D, surface: int) -> bool:
	var mesh := mesh_instance.mesh
	if mesh == null or surface >= mesh.get_surface_count():
		return false
	return (mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR) != 0


func _apply_generic(target: ShaderMaterial, sidecar: Dictionary) -> void:
	var maps: Variant = sidecar.get("maps", {})
	if typeof(maps) == TYPE_DICTIONARY:
		for uniform: String in maps:
			var rec: Variant = maps[uniform]
			if typeof(rec) != TYPE_DICTIONARY:
				continue
			var path := str(rec.get("godot_path", ""))
			if path.is_empty() or not ResourceLoader.exists(path):
				if not path.is_empty():
					warnings.append("missing texture %s for %s" % [path, uniform])
				continue
			var tex := load(path) as Texture2D
			if tex == null:
				continue
			_set_param(target, uniform, tex)
	var params: Variant = sidecar.get("params", {})
	if typeof(params) == TYPE_DICTIONARY:
		for uniform: String in params:
			var value: Variant = params[uniform]
			if typeof(value) == TYPE_ARRAY:
				var arr: Array = value
				if arr.size() >= 4:
					_set_param(target, uniform, Color(arr[0], arr[1], arr[2], arr[3]))
				elif arr.size() == 3:
					_set_param(target, uniform, Vector3(arr[0], arr[1], arr[2]))
				continue
			_set_param(target, uniform, float(value))


func _set_param(target: ShaderMaterial, uniform: String, value: Variant) -> void:
	target.set_shader_parameter(uniform, value)
	var alias: Variant = PFMaterialRules.UNIFORM_ALIASES.get(uniform)
	if alias != null:
		target.set_shader_parameter(str(alias), value)


func _apply_legacy_fallbacks(target: ShaderMaterial, source: Material, kind: String, sidecar: Dictionary) -> void:
	# The GLB still carries albedo/normal for materials exported before the
	# contract, and for anything the sidecar could not resolve.
	var maps: Dictionary = sidecar.get("maps", {})
	if not maps.has("pf_base_color") and source is BaseMaterial3D:
		var albedo := (source as BaseMaterial3D).albedo_texture
		if albedo:
			target.set_shader_parameter("base_texture", albedo)
	if not maps.has("pf_normal") and source is BaseMaterial3D:
		var normal := (source as BaseMaterial3D).normal_texture
		if normal:
			target.set_shader_parameter("normal_texture", normal)
	if maps.has("pf_normal") or (source is BaseMaterial3D and (source as BaseMaterial3D).normal_texture):
		if kind == "skin":
			target.set_shader_parameter("normal_map_strength", 0.35)
		elif kind == "cloth":
			target.set_shader_parameter("normal_strength", 0.72)


func _bind_standard(target: BaseMaterial3D, source: Material) -> void:
	if source is BaseMaterial3D:
		var base := source as BaseMaterial3D
		target.albedo_texture = base.albedo_texture
		target.albedo_color = base.albedo_color
		target.normal_enabled = base.normal_enabled
		target.normal_texture = base.normal_texture
		target.transparency = base.transparency
		target.cull_mode = BaseMaterial3D.CULL_DISABLED
	target.metallic = 0.0
	target.roughness = 0.16


