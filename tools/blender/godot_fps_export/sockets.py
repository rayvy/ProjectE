"""Sockets - the magnet points.

A socket is a bone (or, on a rigid prop, an Empty) named ``SK.<id>``. That is
the whole definition. It exports, it lands in the manifest, and Godot can hang
anything off it by name. Invent ``SK.scope_mount`` in Blender and it is
addressable in GDScript on the next export with no code change.

Socket bones are created with ``use_deform`` on. Not because anything is
skinned to them, but because that is the flag glTF uses to decide a bone is
worth keeping, and a socket that gets trimmed away is a socket that silently
stops existing.
"""

from __future__ import annotations

import bpy
from mathutils import Vector

from . import contract, registry


def _asset_for_new_socket(context, fallback_from=None):
    asset = registry.active_asset(context.scene)
    if asset is not None and asset.id:
        return asset.id
    if fallback_from is not None:
        return registry.tag_of(fallback_from)
    return context.scene.pf_fps.rig_id


class PF_OT_socket_add_bone(bpy.types.Operator):
    bl_idname = "pf_fps.socket_add_bone"
    bl_label = "Add Socket Bone"
    bl_description = ("Create a SK.<id> bone at the 3D cursor, parented to the active bone "
                      "and tagged with the active asset")
    bl_options = {"REGISTER", "UNDO"}

    socket_id: bpy.props.StringProperty(name="Socket id", default="grip")
    length: bpy.props.FloatProperty(name="Length", default=0.03, min=0.001)
    at_cursor: bpy.props.BoolProperty(
        name="At 3D cursor", default=True,
        description="Off places it at the head of the active bone")

    @classmethod
    def poll(cls, context):
        return context.object is not None and context.object.type == "ARMATURE"

    def invoke(self, context, event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        arm = context.object
        sid = contract.slug(self.socket_id)
        name = contract.socket_name(sid)
        if name in arm.data.bones:
            self.report({"ERROR"}, "%s already exists" % name)
            return {"CANCELLED"}

        parent_name = ""
        if arm.mode == "POSE" and context.active_pose_bone is not None:
            parent_name = context.active_pose_bone.name
        elif arm.data.bones.active is not None:
            parent_name = arm.data.bones.active.name

        prev_mode = arm.mode
        head = arm.matrix_world.inverted() @ context.scene.cursor.location
        bpy.ops.object.mode_set(mode="EDIT")
        try:
            eb = arm.data.edit_bones.new(name)
            parent = arm.data.edit_bones.get(parent_name)
            if not self.at_cursor and parent is not None:
                head = parent.head.copy()
            eb.head = head
            eb.tail = head + Vector((0.0, self.length, 0.0))
            if parent is not None:
                eb.parent = parent
                eb.use_connect = False
                eb.roll = parent.roll
            eb.use_deform = True
        finally:
            bpy.ops.object.mode_set(mode=prev_mode if prev_mode != "EDIT" else "OBJECT")

        bone = arm.data.bones.get(name)
        if bone is not None:
            registry.set_tag(bone, _asset_for_new_socket(context, arm))
        self.report({"INFO"}, "%s under %s" % (name, parent_name or "<root>"))
        return {"FINISHED"}


class PF_OT_socket_add_empty(bpy.types.Operator):
    bl_idname = "pf_fps.socket_add_empty"
    bl_label = "Add Socket Empty"
    bl_description = ("Create a SK.<id> Empty at the 3D cursor, parented to the active object. "
                      "For rigid props that carry no armature")
    bl_options = {"REGISTER", "UNDO"}

    socket_id: bpy.props.StringProperty(name="Socket id", default="grip")
    size: bpy.props.FloatProperty(name="Display size", default=0.02, min=0.001)

    def invoke(self, context, event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        sid = contract.slug(self.socket_id)
        name = contract.socket_name(sid)
        if name in bpy.data.objects:
            self.report({"ERROR"}, "%s already exists" % name)
            return {"CANCELLED"}
        parent = context.object
        empty = bpy.data.objects.new(name, None)
        empty.empty_display_type = "ARROWS"
        empty.empty_display_size = self.size
        target_coll = parent.users_collection[0] if parent is not None and parent.users_collection \
            else context.scene.collection
        target_coll.objects.link(empty)
        empty.location = context.scene.cursor.location
        if parent is not None and parent.type != "ARMATURE":
            empty.parent = parent
            empty.matrix_parent_inverse = parent.matrix_world.inverted()
        registry.set_tag(empty, _asset_for_new_socket(context, parent))
        self.report({"INFO"}, "%s under %s" % (name, parent.name if parent else "<scene>"))
        return {"FINISHED"}


class PF_OT_socket_snap_cursor(bpy.types.Operator):
    bl_idname = "pf_fps.socket_snap_cursor"
    bl_label = "Snap Socket To Cursor"
    bl_description = "Move the active socket bone or Empty to the 3D cursor, keeping its rotation"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        obj = context.object
        cursor = context.scene.cursor.location
        if obj is not None and obj.type == "ARMATURE" and obj.mode == "EDIT":
            eb = obj.data.edit_bones.active
            if eb is None or contract.socket_id(eb.name) is None:
                self.report({"ERROR"}, "Active bone is not a SK.* socket")
                return {"CANCELLED"}
            offset = eb.tail - eb.head
            eb.head = obj.matrix_world.inverted() @ cursor
            eb.tail = eb.head + offset
            return {"FINISHED"}
        if obj is not None and contract.socket_id(obj.name) is not None:
            obj.matrix_world.translation = cursor
            return {"FINISHED"}
        self.report({"ERROR"}, "Select a SK.* socket bone (Edit mode) or Empty")
        return {"CANCELLED"}


class PF_OT_socket_list(bpy.types.Operator):
    bl_idname = "pf_fps.socket_list"
    bl_label = "Report Sockets"
    bl_description = "Print every socket in the file to the Info log, grouped by asset"
    bl_options = {"REGISTER"}

    def execute(self, context):
        lines = []
        for arm in registry.armatures():
            for sid, bone_name in sorted(registry.sockets_on_armature(arm).items()):
                owner = registry.tag_of(arm.data.bones[bone_name]) or "<untagged>"
                lines.append("bone   %-20s %-24s %s" % (sid, owner, arm.name))
        for obj in bpy.data.objects:
            sid = contract.socket_id(obj.name)
            if sid is not None and obj.type != "ARMATURE":
                lines.append("empty  %-20s %-24s %s" % (sid, registry.tag_of(obj) or "<untagged>", obj.name))
        if not lines:
            self.report({"WARNING"}, "No SK.* sockets in this file yet")
            return {"FINISHED"}
        for line in lines:
            print("[pf_fps] " + line)
        self.report({"INFO"}, "%d sockets - see the System Console" % len(lines))
        return {"FINISHED"}


_CLASSES = (
    PF_OT_socket_add_bone, PF_OT_socket_add_empty,
    PF_OT_socket_snap_cursor, PF_OT_socket_list,
)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
