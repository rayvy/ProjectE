"""IK/FK for the arms, and the snapping the reference rig never had.

The rig itself is sound: two shadow chains, ``CTL.*_ik.*`` and ``CTL.*_fk.*``,
copied onto the deform bones by paired COPY_TRANSFORMS whose influences are
driven from one custom property per arm. 1.0 is IK, 0.0 is FK.

What was missing is the half that makes it usable: flipping the property
teleports the arm, because nothing moves the controls to where the other chain
was. That is what this module does.

FK from IK is exact - copy three visual matrices. IK from FK is not, because a
pole target has one degree of freedom the FK chain does not constrain. The
elbow is placed analytically and then corrected by two evaluate-and-rotate
passes, which lands well inside a pixel and costs nothing an artist notices.
"""

from __future__ import annotations

import math

import bpy
from mathutils import Matrix, Vector

SIDES = (("R", "Right", ""), ("L", "Left", ""), ("BOTH", "Both", ""))

POLE_DISTANCE = 0.35   # metres out from the elbow, in rig units
REFINE_PASSES = 3


def names(side):
    return {
        "prop_bone": "CTL.hand_ik." + side,
        "prop": "FK/IK Hand." + side,
        "ik_upper": "CTL.arm_upper_ik." + side,
        "ik_lower": "CTL.arm_lower_ik." + side,
        "ik_hand": "CTL.hand_ik." + side,
        "ik_pole": "CTL.hand_pole." + side,
        "fk_upper": "CTL.arm_upper_fk." + side,
        "fk_lower": "CTL.arm_lower_fk." + side,
        "fk_hand": "CTL.hand_fk." + side,
    }


def _missing(arm, table):
    return [v for k, v in table.items() if k != "prop" and v not in arm.pose.bones]


def _set_matrix(pb, matrix):
    """Write a pose-space matrix onto a bone and make it stick.

    Assigning ``pose_bone.matrix`` is only honoured after a depsgraph pass, and
    assigning several bones of one chain in a row without updating in between
    silently uses stale parent matrices.
    """
    pb.matrix = matrix
    bpy.context.view_layer.update()


def snap_fk_to_ik(arm, side, keyframe=False):
    table = names(side)
    missing = _missing(arm, table)
    if missing:
        return "missing bones: " + ", ".join(missing)
    pose = arm.pose.bones
    for ik_key, fk_key in (("ik_upper", "fk_upper"), ("ik_lower", "fk_lower"),
                           ("ik_hand", "fk_hand")):
        _set_matrix(pose[table[fk_key]], pose[table[ik_key]].matrix.copy())
    if keyframe:
        for key in ("fk_upper", "fk_lower", "fk_hand"):
            _key_bone(pose[table[key]])
    return ""


def _elbow_target(shoulder, elbow, wrist):
    """Where a pole must sit for the elbow to point the way FK has it."""
    axis = wrist - shoulder
    if axis.length < 1e-6:
        return elbow + Vector((0.0, -POLE_DISTANCE, 0.0))
    axis.normalize()
    out = (elbow - shoulder) - axis * (elbow - shoulder).dot(axis)
    if out.length < 1e-6:
        out = axis.orthogonal()
    return elbow + out.normalized() * POLE_DISTANCE


def snap_ik_to_fk(arm, side, keyframe=False):
    table = names(side)
    missing = _missing(arm, table)
    if missing:
        return "missing bones: " + ", ".join(missing)
    pose = arm.pose.bones

    fk_upper, fk_lower, fk_hand = (pose[table["fk_upper"]], pose[table["fk_lower"]],
                                   pose[table["fk_hand"]])
    shoulder = fk_upper.matrix.translation.copy()
    elbow = fk_lower.matrix.translation.copy()
    wrist = fk_hand.matrix.translation.copy()

    _set_matrix(pose[table["ik_hand"]], fk_hand.matrix.copy())

    pole = pose[table["ik_pole"]]
    target = _elbow_target(shoulder, elbow, wrist)
    mat = pole.matrix.copy()
    mat.translation = target
    _set_matrix(pole, mat)

    # The analytic placement ignores the constraint's pole angle. Rotating the
    # pole about the shoulder-wrist axis by the residual error converges in a
    # couple of passes and needs no knowledge of how the rig was set up.
    axis = (wrist - shoulder)
    if axis.length > 1e-6:
        axis.normalize()
        ik_lower = pose[table["ik_lower"]]
        for _ in range(REFINE_PASSES):
            have = ik_lower.matrix.translation - shoulder
            want = elbow - shoulder
            have_p = (have - axis * have.dot(axis))
            want_p = (want - axis * want.dot(axis))
            if have_p.length < 1e-6 or want_p.length < 1e-6:
                break
            have_p.normalize()
            want_p.normalize()
            angle = math.atan2(have_p.cross(want_p).dot(axis), have_p.dot(want_p))
            if abs(angle) < 1e-4:
                break
            rot = Matrix.Rotation(angle, 4, axis)
            mat = pole.matrix.copy()
            mat.translation = shoulder + rot @ (mat.translation - shoulder)
            _set_matrix(pole, mat)

    if keyframe:
        _key_bone(pose[table["ik_hand"]])
        _key_bone(pole)
    return ""


def _key_bone(pb):
    pb.keyframe_insert("location", group=pb.name)
    if pb.rotation_mode == "QUATERNION":
        pb.keyframe_insert("rotation_quaternion", group=pb.name)
    else:
        pb.keyframe_insert("rotation_euler", group=pb.name)
    pb.keyframe_insert("scale", group=pb.name)


def _sides(choice):
    return ("R", "L") if choice == "BOTH" else (choice,)


class PF_OT_ikfk_snap(bpy.types.Operator):
    bl_idname = "pf_fps.ikfk_snap"
    bl_label = "Snap IK/FK"
    bl_description = "Move one chain onto the other without moving the arm"
    bl_options = {"REGISTER", "UNDO"}

    direction: bpy.props.EnumProperty(
        name="Direction",
        items=[("FK_TO_IK", "FK to IK", "Put the FK controls where the IK arm is"),
               ("IK_TO_FK", "IK to FK", "Put the IK target and pole where the FK arm is")],
        default="FK_TO_IK")
    side: bpy.props.EnumProperty(name="Side", items=SIDES, default="BOTH")
    keyframe: bpy.props.BoolProperty(
        name="Key", default=False,
        description="Key the controls that moved, on the current frame")

    @classmethod
    def poll(cls, context):
        return context.object is not None and context.object.type == "ARMATURE"

    def execute(self, context):
        arm = context.object
        problems = []
        for side in _sides(self.side):
            fn = snap_fk_to_ik if self.direction == "FK_TO_IK" else snap_ik_to_fk
            message = fn(arm, side, self.keyframe)
            if message:
                problems.append("%s: %s" % (side, message))
        if problems:
            self.report({"ERROR"}, "; ".join(problems))
            return {"CANCELLED"}
        return {"FINISHED"}


class PF_OT_ikfk_switch(bpy.types.Operator):
    bl_idname = "pf_fps.ikfk_switch"
    bl_label = "Switch IK/FK"
    bl_description = ("Flip the arm between IK and FK, snapping first so the pose does not move. "
                      "This is the operation the reference rig was missing")
    bl_options = {"REGISTER", "UNDO"}

    side: bpy.props.EnumProperty(name="Side", items=SIDES, default="R")
    keyframe: bpy.props.BoolProperty(
        name="Key", default=True,
        description="Key the switch and the controls, so the change survives playback")

    @classmethod
    def poll(cls, context):
        return context.object is not None and context.object.type == "ARMATURE"

    def execute(self, context):
        arm = context.object
        for side in _sides(self.side):
            table = names(side)
            holder = arm.pose.bones.get(table["prop_bone"])
            if holder is None or table["prop"] not in holder.keys():
                self.report({"ERROR"}, "No '%s' on %s" % (table["prop"], table["prop_bone"]))
                return {"CANCELLED"}
            was_ik = holder[table["prop"]] > 0.5
            message = snap_fk_to_ik(arm, side, self.keyframe) if was_ik \
                else snap_ik_to_fk(arm, side, self.keyframe)
            if message:
                self.report({"ERROR"}, message)
                return {"CANCELLED"}
            holder[table["prop"]] = 0.0 if was_ik else 1.0
            if self.keyframe:
                holder.keyframe_insert('["%s"]' % table["prop"], group=holder.name)
            context.view_layer.update()
        return {"FINISHED"}


_CLASSES = (PF_OT_ikfk_snap, PF_OT_ikfk_switch)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
