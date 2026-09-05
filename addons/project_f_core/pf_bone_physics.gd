extends Node
class_name PFBonePhysics

## Drop onto a character. Discovers TypeJiggle / TypeHair / TypeCloth chains
## on `skeleton` and steps the portable solver. TypeNone is ignored here.

@export var skeleton: Skeleton3D
@export var collider_skeleton: Skeleton3D
## Colliders modelled in Blender. Empty = fall back to the built-in bone capsules.
@export_file("*.json") var collider_path: String = "res://imported/character/character.colliders.json"
@export var auto_setup: bool = true
@export var auto_step: bool = true

var controller: PFMotionController


func _ready() -> void:
	process_priority = 10
	if auto_setup and skeleton:
		setup(skeleton)


func setup(target: Skeleton3D) -> void:
	skeleton = target
	if controller:
		controller.queue_free()
	controller = PFMotionController.new()
	controller.name = "PFMotion"
	# Copies run at process_priority 1. This node steps after them.
	controller.external_step_driver = true
	controller.collider_skeleton = collider_skeleton if collider_skeleton else target
	controller.collider_path = collider_path
	add_child(controller)
	controller.setup(skeleton)
	var profiles := PFTypeParser.discover_profiles(skeleton)
	for profile in profiles:
		controller.register_chain(profile)


func chain_count() -> int:
	if controller == null:
		return 0
	return controller.chain_count()


func collider_debug_lines() -> PackedVector3Array:
	if controller == null:
		return PackedVector3Array()
	return controller.collider_set.debug_lines()


func collider_count() -> int:
	if controller == null:
		return 0
	return controller.collider_count()


func last_lag() -> float:
	if controller == null:
		return 0.0
	return controller.last_max_lag


func resync() -> void:
	if controller:
		controller.resync_targets()


func step(delta: float) -> void:
	if controller:
		controller.step(delta)


func _process(delta: float) -> void:
	if auto_step and controller:
		controller.step(delta)
