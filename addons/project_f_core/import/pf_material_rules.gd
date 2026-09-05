extends RefCounted
class_name PFMaterialRules

## Blender → Godot material families.
## Node group PF_Mat.Skin / prefix Mat.Skin both resolve here.

const PREFIXES := {
	"Mat.Skin": "skin",
	"Mat.Face": "skin",
	"Mat.Eyes": "eyes",
	"Mat.Hair": "hair",
	"Mat.Cloth": "cloth",
	"Mat.Stockings": "nylon",
	"Mat.Nylon": "nylon",
}

const GROUPS := {
	"PF_Mat.Skin": "skin",
	"PF_Mat.Face": "skin",
	"PF_Mat.Eyes": "eyes",
	"PF_Mat.Hair": "hair",
	"PF_Mat.Cloth": "cloth",
	"PF_Mat.Nylon": "nylon",
}

const PRESETS := {
	"skin": "res://shaders/mat_skin.tres",
	"eyes": "res://shaders/mat_eyes.tres",
	"hair": "res://shaders/mat_hair.tres",
	"cloth": "res://shaders/mat_cloth.tres",
	"nylon": "res://shaders/mat_nylon.tres",
}

const OUTLINE_PRESET := "res://shaders/mat_skin_outline.tres"
const RAIN_PRESET := "res://shaders/mat_skin_rain.tres"

## Blender socket names slugify straight to shader uniforms — "Wrinkle Height"
## becomes "pf_wrinkle_height" and needs no entry anywhere. This table exists
## only because a few uniforms in shaders/ predate the contract; the applier
## sets the generic name AND the legacy alias, so both spellings work and new
## sockets need no code at all.
const UNIFORM_ALIASES := {
	"pf_base_color": "base_texture",
	"pf_normal": "normal_texture",
	"pf_normal_strength": "normal_map_strength",
	"pf_metallic": "metallic_map",
	"pf_roughness": "roughness_map",
	"pf_ao": "ao_map",
	"pf_region": "region_map",
	"pf_direction": "direction_map",
	"pf_strand": "strand_map",
	"pf_pattern": "pattern_texture",
}


static func classify(material_name: String, group_name: String = "") -> String:
	if not group_name.is_empty():
		for key: String in GROUPS:
			if group_name == key or group_name.begins_with(key + "."):
				return GROUPS[key]
	for prefix: String in PREFIXES:
		if material_name == prefix or material_name.begins_with(prefix + "."):
			return PREFIXES[prefix]
	return ""


static func preset_path(kind: String) -> String:
	return PRESETS.get(kind, "")
