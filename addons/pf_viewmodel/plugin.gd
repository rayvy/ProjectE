@tool
extends EditorPlugin

## Nothing to register but the custom types - the runtime is plain nodes, and
## the content it reads is written by the Blender side, not by the editor.

func _enter_tree() -> void:
	add_custom_type("PFViewmodel", "Node3D",
		preload("res://addons/pf_viewmodel/pf_viewmodel.gd"), null)
	add_custom_type("PFArmIK", "SkeletonModifier3D",
		preload("res://addons/pf_viewmodel/pf_arm_ik.gd"), null)


func _exit_tree() -> void:
	remove_custom_type("PFArmIK")
	remove_custom_type("PFViewmodel")
