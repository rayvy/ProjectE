"""Say what will go wrong before it goes wrong.

Every check here exists because the failure it catches is silent on the Godot
side: a scaled armature imports fine and animates at the wrong size, an
untagged bone simply is not in the .glb, a missing socket makes an attachment
land at the origin. None of them raise an error anywhere - they just look
subtly wrong three days later.
"""

from __future__ import annotations

import os

import bpy

from . import clips, contract, registry

ERROR, WARN, INFO = "ERROR", "WARNING", "INFO"


def run(context):
    scene = context.scene
    props = scene.pf_fps
    out = []

    def say(level, text):
        out.append((level, text))

    # --- destination
    root = bpy.path.abspath(props.godot_project) if props.godot_project else ""
    if not root:
        say(ERROR, "Godot project folder is not set")
    elif not os.path.exists(os.path.join(root, "project.godot")):
        say(ERROR, "No project.godot in " + root)

    # --- scene
    fps = float(scene.render.fps) / float(scene.render.fps_base or 1.0)
    if abs(fps - 60.0) > 0.01:
        say(ERROR, "Scene is %g fps. First-person clips are authored at 60" % fps)
    if scene.unit_settings.scale_length != 1.0:
        say(WARN, "Unit scale is %g, not 1.0 - Godot will import at the wrong size"
            % scene.unit_settings.scale_length)

    # --- the rig
    rig_arms = [o for o in registry.armatures() if registry.tag_of(o) == props.rig_id]
    if not rig_arms:
        say(ERROR, "No armature tagged as the rig '%s'" % props.rig_id)
    else:
        rig = rig_arms[0]
        if len(rig_arms) > 1:
            say(ERROR, "%d armatures claim to be the rig: %s"
                % (len(rig_arms), ", ".join(o.name for o in rig_arms)))
        found = set(registry.sockets_on_armature(rig))
        for wanted in contract.SUGGESTED_RIG_SOCKETS:
            if wanted not in found:
                say(WARN, "Rig has no SK.%s socket" % wanted)

    # --- transforms
    for obj in bpy.data.objects:
        if obj.type not in {"MESH", "ARMATURE"} or not registry.tag_of(obj):
            continue
        if any(abs(s - 1.0) > 1e-4 for s in obj.scale):
            say(ERROR, "%s has unapplied scale %s - Ctrl+A > Scale"
                % (obj.name, tuple(round(s, 3) for s in obj.scale)))
        if obj.type == "ARMATURE" and any(abs(r) > 1e-4 for r in obj.rotation_euler):
            say(WARN, "%s has unapplied rotation" % obj.name)

    # --- membership
    # Bone widgets are rig furniture, not content: they are never exported and
    # tagging them would only put them in a manifest nothing reads.
    widgets = {pb.custom_shape.name
               for arm in registry.armatures() for pb in arm.pose.bones
               if pb.custom_shape is not None}
    stray_objects, stray_bones = registry.untagged_report()
    stray_objects = [n for n in stray_objects if n not in widgets]
    if stray_objects:
        say(WARN, "%d objects have no asset tag and will not export: %s"
            % (len(stray_objects), ", ".join(stray_objects[:6])))
    if stray_bones:
        say(WARN, "%d deform or socket bones have no asset tag: %s"
            % (len(stray_bones), ", ".join(stray_bones[:6])))

    known = {a.id for a in props.assets if a.id}
    if not known:
        say(ERROR, "Asset registry is empty - press Suggest From Scene")

    # --- proxies
    for asset in props.assets:
        if not asset.id or asset.kind == "RIG":
            continue
        owner = registry.owning_armature(asset.id)
        own = [o for o in registry.armatures() if registry.tag_of(o) == asset.id]
        if owner is not None and not own:
            say(WARN, "'%s' still lives in the base rig - Extract Proxy Rig" % asset.id)
        if not registry.meshes_of(asset.id) and asset.export_mesh:
            say(WARN, "'%s' has no mesh tagged but Mesh export is on" % asset.id)

    # --- clips
    for action in bpy.data.actions:
        if not action.pf.asset:
            say(INFO, "Action '%s' has no asset - it will not export" % action.name)
        elif action.pf.asset not in known:
            say(WARN, "Action '%s' points at unknown asset '%s'" % (action.name, action.pf.asset))
        for cue in action.pf.sounds:
            path = bpy.path.abspath(cue.path) if cue.path else ""
            if not path or not os.path.exists(path):
                say(ERROR, "Sound missing for '%s': %s" % (action.name, cue.path or "<empty>"))

    for asset in props.assets:
        if not asset.id or not asset.export_anim:
            continue
        group = [a for a in bpy.data.actions if a.pf.asset == asset.id]
        if not group:
            say(WARN, "'%s' has no clips - press Create Animation Stubs" % asset.id)
            continue
        stubs = [a.name for a in group if not clips.has_keys(a)]
        if stubs:
            say(INFO, "'%s': %d of %d clips still empty" % (asset.id, len(stubs), len(group)))

    if not any(level == ERROR for level, _ in out):
        say(INFO, "No blocking problems. Export away")
    return out


class PF_OT_validate(bpy.types.Operator):
    bl_idname = "pf_fps.validate"
    bl_label = "Validate"
    bl_description = "Check the file against the contract and print the findings"
    bl_options = {"REGISTER"}

    def execute(self, context):
        findings = run(context)
        errors = sum(1 for level, _ in findings if level == ERROR)
        warns = sum(1 for level, _ in findings if level == WARN)
        for level, text in findings:
            print("[pf_fps] %-7s %s" % (level, text))
        context.scene.pf_fps.last_report = "%d errors, %d warnings - see the System Console" % (
            errors, warns)
        self.report({"ERROR"} if errors else {"INFO"}, context.scene.pf_fps.last_report)
        return {"FINISHED"}


_CLASSES = (PF_OT_validate,)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
