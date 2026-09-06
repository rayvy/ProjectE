"""Magnets: parts that change what they hang off, mid-clip.

The reference AK rig already works this way. ``CTL.hand_ik.R`` carries four
CHILD_OF constraints - rifle, magazine, magazine_2, bolt - and the reload
action keyframes their *influence* rather than hand-animating the hand onto
the magazine. Whichever constraint reads 1.0 is what the hand is welded to at
that instant.

So the timing is already in the file, drawn as a curve in the dope sheet. This
module reads that curve instead of asking the artist to type frame numbers a
second time and keep the two in agreement forever. Re-time the reload, and the
magnet re-times with it.

Baked bone animation makes most of this unnecessary: a magazine that is a bone
of the weapon proxy simply plays back. Magnets matter when a part must become
a *separate* thing in Godot - a grenade that leaves the hand, a magazine that
drops to the floor as a rigid body, a bottle picked up off a shelf.
"""

from __future__ import annotations

import bpy

from . import clips

THRESHOLD = 0.5


def influence_path(bone: str, constraint: str) -> str:
    return 'pose.bones["%s"].constraints["%s"].influence' % (bone, constraint)


def _find_fcurve(action, data_path):
    bag = clips.channelbag(action)
    if bag is None:
        return None
    for fcurve in bag.fcurves:
        if fcurve.data_path == data_path:
            return fcurve
    return None


def _crossings(fcurve):
    """[(frame, rising)] where the curve passes through the halfway mark.

    Read off the keyframes rather than by sampling: an influence curve is a
    handful of keys, and sampling would put the switch on a frame boundary
    that the artist did not choose.
    """
    points = sorted(fcurve.keyframe_points, key=lambda k: k.co.x)
    out = []
    for previous, current in zip(points, points[1:]):
        was, now = previous.co.y >= THRESHOLD, current.co.y >= THRESHOLD
        if was == now:
            continue
        if previous.interpolation == "CONSTANT":
            frame = current.co.x
        else:
            span = current.co.x - previous.co.x
            gap = current.co.y - previous.co.y
            frame = current.co.x if abs(gap) < 1e-9 else \
                previous.co.x + span * (THRESHOLD - previous.co.y) / gap
        out.append((frame, now))
    if points and points[0].co.y >= THRESHOLD:
        out.insert(0, (points[0].co.x, True))
    return out


def timeline(action, arm, clip_start, fps):
    """Attach and detach moments for one action, in clip-relative seconds."""
    events = []
    for rule in action.pf.attach:
        if not rule.constraint or not rule.owner_bone:
            continue
        path = influence_path(rule.owner_bone, rule.constraint)
        fcurve = _find_fcurve(action, path)
        record = {"part": rule.part or rule.constraint, "socket": rule.socket,
                  "invert": bool(rule.invert), "constraint": rule.constraint}
        if fcurve is None:
            pose_bone = arm.pose.bones.get(rule.owner_bone) if arm else None
            constraint = pose_bone.constraints.get(rule.constraint) if pose_bone else None
            if constraint is None or constraint.influence < THRESHOLD:
                continue
            events.append(dict(record, t=0.0, state="attach", static=True))
            continue
        for frame, rising in _crossings(fcurve):
            events.append(dict(record, t=round((frame - clip_start) / fps, 5),
                               state="attach" if rising else "detach", static=False))
    return events


class PF_OT_attach_discover(bpy.types.Operator):
    bl_idname = "pf_fps.attach_discover"
    bl_label = "Find Magnets"
    bl_description = ("Scan the active armature for CHILD_OF constraints whose influence is "
                      "keyed in this clip, and add a magnet rule for each")
    bl_options = {"REGISTER", "UNDO"}

    action_name: bpy.props.StringProperty()

    def execute(self, context):
        action = bpy.data.actions.get(self.action_name) or clips.active_action(context)
        arm = context.object
        if action is None or arm is None or arm.type != "ARMATURE":
            self.report({"ERROR"}, "Need an armature with an active clip")
            return {"CANCELLED"}
        bag = clips.channelbag(action)
        if bag is None:
            self.report({"WARNING"}, "Clip has no curves yet")
            return {"CANCELLED"}
        known = {(r.owner_bone, r.constraint) for r in action.pf.attach}
        added = 0
        for pose_bone in arm.pose.bones:
            for constraint in pose_bone.constraints:
                if constraint.type != "CHILD_OF":
                    continue
                key = (pose_bone.name, constraint.name)
                if key in known:
                    continue
                if _find_fcurve(action, influence_path(*key)) is None:
                    continue
                rule = action.pf.attach.add()
                rule.owner_object = arm.name
                rule.owner_bone = pose_bone.name
                rule.constraint = constraint.name
                rule.part = constraint.name
                rule.socket = constraint.subtarget or ""
                rule.invert = True  # the reference rig constrains the hand to the part
                added += 1
        self.report({"INFO"}, "%d magnet rules added - set each part and socket" % added)
        return {"FINISHED"}


_CLASSES = (PF_OT_attach_discover,)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
