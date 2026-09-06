"""The asset registry: who owns which object and which bone.

Membership is a single string key on the data-block (``pf_asset``). That is
deliberate - it survives append/link, it is visible in the Custom Properties
panel when something looks wrong, and it means one .blend can hold a hundred
assets while an export still only touches one of them.
"""

from __future__ import annotations

import bpy

from . import contract

TAG = contract.ASSET_KEY

# Bone name tokens that are never an asset of their own: they are the arms rig.
RIG_TOKENS = {
    "upperarm", "forearm", "hand", "palm", "finger", "root", "chest",
    "spine", "neck", "head", "clavicle", "shoulder", "thumb", "wrist",
}


# --- reading --------------------------------------------------------------

def tag_of(datablock) -> str:
    return str(datablock.get(TAG, "") or "")


def set_tag(datablock, asset_id: str):
    if asset_id:
        datablock[TAG] = asset_id
    elif TAG in datablock:
        del datablock[TAG]


def find(scene, asset_id: str):
    for a in scene.pf_fps.assets:
        if a.id == asset_id:
            return a
    return None


def active_asset(scene):
    props = scene.pf_fps
    if 0 <= props.assets_index < len(props.assets):
        return props.assets[props.assets_index]
    return None


def objects_of(asset_id: str):
    return [o for o in bpy.data.objects if tag_of(o) == asset_id]


def meshes_of(asset_id: str):
    return [o for o in objects_of(asset_id) if o.type == "MESH"]


def armatures():
    return [o for o in bpy.data.objects if o.type == "ARMATURE"]


def bones_of(asset_id: str):
    """[(armature_object, [bone_name, ...]), ...] for every armature that has some."""
    out = []
    for arm in armatures():
        names = [b.name for b in arm.data.bones if tag_of(b) == asset_id]
        if names:
            out.append((arm, names))
    return out


def owning_armature(asset_id: str):
    """The one armature holding this asset's bones, or None for a rigid asset."""
    found = bones_of(asset_id)
    return found[0][0] if found else None


def sockets_on_armature(arm, asset_id=None):
    """{socket_id: bone_name} for socket bones, optionally filtered to one asset."""
    out = {}
    for bone in arm.data.bones:
        sid = contract.socket_id(bone.name)
        if sid is None:
            continue
        if asset_id is not None and tag_of(bone) != asset_id:
            continue
        out[sid] = bone.name
    return out


def sockets_on_objects(asset_id: str):
    """{socket_id: object_name} for Empties named SK.* belonging to this asset."""
    out = {}
    for obj in objects_of(asset_id):
        sid = contract.socket_id(obj.name)
        if sid is not None:
            out[sid] = obj.name
    return out


def ancestors(arm, names):
    """Bone names plus every parent needed to keep the hierarchy intact.

    A trimmed skeleton that drops a parent silently changes every child's rest
    transform, because pose channels are parent-relative. Keeping the chain is
    cheaper than re-deriving the maths.
    """
    keep = set(names)
    for name in list(names):
        bone = arm.data.bones.get(name)
        while bone is not None and bone.parent is not None:
            keep.add(bone.parent.name)
            bone = bone.parent
    return keep


def untagged_report():
    """What would silently not export. The validator turns this into warnings."""
    objs = [o.name for o in bpy.data.objects
            if o.type in {"MESH", "EMPTY"} and not tag_of(o)]
    bones = []
    for arm in armatures():
        for b in arm.data.bones:
            if (b.use_deform or contract.socket_id(b.name)) and not tag_of(b):
                bones.append(arm.name + "/" + b.name)
    return objs, bones


# --- operators ------------------------------------------------------------

class PF_OT_asset_add(bpy.types.Operator):
    bl_idname = "pf_fps.asset_add"
    bl_label = "Add Asset"
    bl_description = "Add an empty row to the asset registry"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        props = context.scene.pf_fps
        taken = {a.id for a in props.assets}
        name, n = "new_asset", 0
        while name in taken:
            n += 1
            name = "new_asset_%d" % n
        item = props.assets.add()
        item.id = name
        props.assets_index = len(props.assets) - 1
        return {"FINISHED"}


class PF_OT_asset_remove(bpy.types.Operator):
    bl_idname = "pf_fps.asset_remove"
    bl_label = "Remove Asset"
    bl_description = "Drop the registry row. Tags on objects and bones are left alone"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        props = context.scene.pf_fps
        if not props.assets:
            return {"CANCELLED"}
        props.assets.remove(props.assets_index)
        props.assets_index = max(0, props.assets_index - 1)
        return {"FINISHED"}


class PF_OT_asset_rename(bpy.types.Operator):
    bl_idname = "pf_fps.asset_rename"
    bl_label = "Rename Asset"
    bl_description = "Rename the active asset and re-tag every object, bone and clip pointing at it"
    bl_options = {"REGISTER", "UNDO"}

    new_id: bpy.props.StringProperty(name="New id", default="")

    def invoke(self, context, event):
        asset = active_asset(context.scene)
        if asset is None:
            self.report({"ERROR"}, "No active asset")
            return {"CANCELLED"}
        self.new_id = asset.id
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        asset = active_asset(context.scene)
        if asset is None:
            return {"CANCELLED"}
        old = asset.id
        new = contract.slug(self.new_id)
        if not new or new == old:
            return {"CANCELLED"}
        moved = 0
        for obj in bpy.data.objects:
            if tag_of(obj) == old:
                set_tag(obj, new)
                moved += 1
            if obj.type == "ARMATURE":
                for bone in obj.data.bones:
                    if tag_of(bone) == old:
                        set_tag(bone, new)
                        moved += 1
        for action in bpy.data.actions:
            if action.pf.asset == old:
                action.pf.asset = new
                moved += 1
        if context.scene.pf_fps.rig_id == old:
            context.scene.pf_fps.rig_id = new
        asset.id = new
        self.report({"INFO"}, "%s -> %s, re-tagged %d" % (old, new, moved))
        return {"FINISHED"}


class PF_OT_asset_assign(bpy.types.Operator):
    bl_idname = "pf_fps.asset_assign"
    bl_label = "Assign Selected"
    bl_description = ("Tag the selection with the active asset. In Pose mode this takes the "
                      "selected bones, in Object mode the selected objects")
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        asset = active_asset(context.scene)
        if asset is None or not asset.id:
            self.report({"ERROR"}, "No active asset")
            return {"CANCELLED"}
        n = 0
        obj = context.object
        if obj is not None and obj.mode == "POSE" and context.selected_pose_bones:
            for pb in context.selected_pose_bones:
                set_tag(obj.data.bones[pb.name], asset.id)
                n += 1
        else:
            for o in context.selected_objects:
                set_tag(o, asset.id)
                n += 1
        self.report({"INFO"}, "Tagged %d -> %s" % (n, asset.id))
        return {"FINISHED"}


class PF_OT_asset_select(bpy.types.Operator):
    bl_idname = "pf_fps.asset_select"
    bl_label = "Select Members"
    bl_description = "Select everything tagged with the active asset"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        asset = active_asset(context.scene)
        if asset is None:
            return {"CANCELLED"}
        obj = context.object
        if obj is not None and obj.mode == "POSE":
            for pb in obj.pose.bones:
                bone = obj.data.bones[pb.name]
                bone.select = tag_of(bone) == asset.id
        else:
            for o in list(context.selected_objects):
                o.select_set(False)
            for o in objects_of(asset.id):
                try:
                    o.select_set(True)
                except RuntimeError:
                    pass
        return {"FINISHED"}


class PF_OT_asset_autodetect(bpy.types.Operator):
    bl_idname = "pf_fps.asset_autodetect"
    bl_label = "Suggest From Scene"
    bl_description = ("Seed the registry by grouping bones on their leading token and meshes on "
                      "their name stem. A first pass to correct, not an oracle")
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        scene = context.scene
        props = scene.pf_fps
        rig_id = props.rig_id or "arms_base"

        groups = {}
        for arm in armatures():
            for bone in arm.data.bones:
                if not bone.use_deform and contract.socket_id(bone.name) is None:
                    continue
                if tag_of(bone):
                    continue
                token = bone.name.split("_")[0].lower()
                groups.setdefault(token, []).append((arm, bone))

        made = set()
        for token, members in groups.items():
            # A lone bone is not evidence of an asset; it belongs to the rig
            # until the artist says otherwise.
            if token in RIG_TOKENS or len(members) < 2:
                target = rig_id
            else:
                target = token
            for arm, bone in members:
                set_tag(bone, target)
            made.add(target)

        for obj in bpy.data.objects:
            if obj.type not in {"MESH", "EMPTY"} or tag_of(obj):
                continue
            stem = contract.slug(obj.name.split(".")[0])
            target = rig_id if stem in {"arms", "hands"} else stem
            set_tag(obj, target)
            made.add(target)
        for arm in armatures():
            if not tag_of(arm):
                set_tag(arm, rig_id)
        made.add(rig_id)

        existing = {a.id for a in props.assets}
        for asset_id in sorted(made):
            if asset_id in existing or not asset_id:
                continue
            row = props.assets.add()
            row.id = asset_id
            row.kind = "RIG" if asset_id == rig_id else "PROP"
        self.report({"INFO"},
                    "Registry now holds %d assets - review the kinds" % len(props.assets))
        return {"FINISHED"}


_CLASSES = (
    PF_OT_asset_add, PF_OT_asset_remove, PF_OT_asset_rename,
    PF_OT_asset_assign, PF_OT_asset_select, PF_OT_asset_autodetect,
)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
