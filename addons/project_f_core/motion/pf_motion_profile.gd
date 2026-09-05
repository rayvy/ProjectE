@tool
extends Resource
class_name PFMotionProfile

## One simulated chain. Scene-path free — copy this resource between projects.

enum ChainKind { JIGGLE, HAIR, CLOTH }

@export var chain_id: StringName = &""
@export var kind: ChainKind = ChainKind.JIGGLE
@export var root_bone: StringName = &""
@export var end_bone: StringName = &""

@export_range(0.0, 1.0, 0.01) var stiffness: float = 0.5
@export_range(0.0, 1.0, 0.01) var drag: float = 0.4
@export_range(1.0, 16.0, 0.1) var frequency_scale: float = 1.0
@export_range(0.1, 3.0, 0.01) var damping_scale: float = 1.0
@export_range(0.0, 20.0, 0.1) var gravity: float = 2.0
@export var gravity_direction: Vector3 = Vector3.DOWN
@export_range(0.0, 0.12, 0.001) var inertia_strength: float = 0.02
@export_range(0.0, 0.9, 0.01) var angular_inertia_strength: float = 0.0
@export_range(0.0, 1.0, 0.01) var segment_falloff: float = 0.35
@export_range(0.0, 3.0, 0.01) var lateral_response: float = 1.0
@export_range(0.0, 3.0, 0.01) var vertical_response: float = 1.0
@export_range(0.0, 3.0, 0.01) var depth_response: float = 1.0
@export_range(0.0, 3.14159, 0.01) var max_angle_radians: float = 0.6
@export_range(0.0, 0.2, 0.001) var max_translation_meters: float = 0.0
@export_range(0.0, 1.0, 0.01) var amplitude: float = 1.0


func is_valid() -> bool:
	return not chain_id.is_empty() and not root_bone.is_empty() and not end_bone.is_empty()


static func make(id: StringName, chain_kind: ChainKind, root: StringName, tip: StringName) -> PFMotionProfile:
	var p := PFMotionProfile.new()
	p.chain_id = id
	p.kind = chain_kind
	p.root_bone = root
	p.end_bone = tip
	match chain_kind:
		ChainKind.JIGGLE:
			# Simple tissue spring — ferraTechLab cartoon breast defaults, scaled down.
			p.stiffness = 0.45
			p.drag = 0.30
			p.gravity = 0.06
			p.frequency_scale = 8.0
			p.damping_scale = 0.45
			p.inertia_strength = 0.10
			p.angular_inertia_strength = 0.60
			p.amplitude = 1.0
			p.max_angle_radians = 1.0
			p.max_translation_meters = 0.04
			p.segment_falloff = 0.4
		ChainKind.HAIR:
			p.stiffness = 0.18
			p.drag = 0.38
			p.gravity = 16.0
			p.frequency_scale = 2.2
			p.damping_scale = 0.85
			p.inertia_strength = 0.04
			p.angular_inertia_strength = 0.40
			p.max_angle_radians = 1.55
			p.segment_falloff = 0.45
		ChainKind.CLOTH:
			# World-space Verlet: gravity hangs, low follow so hips/arms actually swing it.
			p.stiffness = 0.10
			p.drag = 0.34
			p.gravity = 20.0
			p.frequency_scale = 1.7
			p.damping_scale = 0.85
			p.inertia_strength = 0.16
			p.angular_inertia_strength = 0.55
			p.max_angle_radians = 1.7
			p.segment_falloff = 0.22
	return p
