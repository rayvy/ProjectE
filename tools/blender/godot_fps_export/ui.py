"""The N-panel. One tab, five sections, in the order the work happens."""

from __future__ import annotations

import bpy

from . import clips, contract, ikfk, registry, rigsplit

TAB = "Godot FPS"


class PF_UL_assets(bpy.types.UIList):
    def draw_item(self, context, layout, data, item, icon, active_data, active_prop, index):
        icons = {"RIG": "ARMATURE_DATA", "WEAPON": "MOD_SIMPLIFY", "MELEE": "MOD_EDGESPLIT",
                 "PROP": "MESH_CYLINDER", "MAGIC": "SHADERFX"}
        row = layout.row(align=True)
        row.label(text="", icon=icons.get(item.kind, "DOT"))
        row.prop(item, "id", text="", emboss=False)
        n = len([a for a in bpy.data.actions if a.pf.asset == item.id])
        row.label(text=str(n) if n else "-")


class PF_UL_events(bpy.types.UIList):
    def draw_item(self, context, layout, data, item, icon, active_data, active_prop, index):
        row = layout.row(align=True)
        row.prop(item, "frame", text="")
        row.prop(item, "name", text="")
        row.prop(item, "args", text="")


class PF_UL_sounds(bpy.types.UIList):
    def draw_item(self, context, layout, data, item, icon, active_data, active_prop, index):
        row = layout.row(align=True)
        row.prop(item, "frame", text="")
        row.prop(item, "name", text="")
        row.prop(item, "volume", text="", slider=True)


class PF_UL_attach(bpy.types.UIList):
    def draw_item(self, context, layout, data, item, icon, active_data, active_prop, index):
        row = layout.row(align=True)
        row.prop(item, "part", text="")
        row.label(text="", icon="FORWARD")
        row.prop(item, "socket", text="")
        row.prop(item, "invert", text="", icon="ARROW_LEFTRIGHT")


class _Base:
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = TAB


class PF_PT_project(_Base, bpy.types.Panel):
    bl_label = "Project"
    bl_idname = "PF_PT_fps_project"

    def draw(self, context):
        props = context.scene.pf_fps
        layout = self.layout
        layout.prop(props, "godot_project")
        row = layout.row(align=True)
        row.prop(props, "content_dir")
        row.prop(props, "rig_id")

        fps = context.scene.render.fps / (context.scene.render.fps_base or 1.0)
        info = layout.row()
        info.alert = abs(fps - 60.0) > 0.01
        info.label(text="%g fps  |  first-person is authored at 60" % fps,
                   icon="TIME" if not info.alert else "ERROR")

        layout.prop(props, "copy_audio")
        col = layout.column(align=True)
        col.operator("pf_fps.validate", icon="CHECKMARK")
        col.operator("pf_fps.export_all", icon="EXPORT")
        col.operator("pf_fps.export_contract", icon="FILE_REFRESH")
        layout.operator("pf_fps.workspace_build", icon="WORKSPACE")
        if props.last_report:
            layout.label(text=props.last_report, icon="INFO")


class PF_PT_assets(_Base, bpy.types.Panel):
    bl_label = "Assets"
    bl_idname = "PF_PT_fps_assets"

    def draw(self, context):
        props = context.scene.pf_fps
        layout = self.layout
        row = layout.row()
        row.template_list("PF_UL_assets", "", props, "assets", props, "assets_index", rows=5)
        side = row.column(align=True)
        side.operator("pf_fps.asset_add", icon="ADD", text="")
        side.operator("pf_fps.asset_remove", icon="REMOVE", text="")
        side.separator()
        side.operator("pf_fps.asset_rename", icon="GREASEPENCIL", text="")
        side.operator("pf_fps.asset_autodetect", icon="ZOOM_SELECTED", text="")

        asset = registry.active_asset(context.scene)
        if asset is None:
            layout.label(text="No asset selected", icon="INFO")
            return
        box = layout.box()
        box.prop(asset, "kind")
        if asset.kind != "RIG":
            box.prop(asset, "mount_socket")
        line = box.row(align=True)
        line.prop(asset, "export_mesh", toggle=True)
        line.prop(asset, "export_anim", toggle=True)
        box.prop(asset, "notes")

        counts = box.row()
        counts.label(text="%d meshes" % len(registry.meshes_of(asset.id)), icon="MESH_DATA")
        bones = registry.bones_of(asset.id)
        counts.label(text="%d bones" % sum(len(n) for _, n in bones), icon="BONE_DATA")

        row = layout.row(align=True)
        row.operator("pf_fps.asset_assign", icon="CHECKMARK")
        row.operator("pf_fps.asset_select", icon="RESTRICT_SELECT_OFF")
        layout.operator("pf_fps.export_asset", icon="EXPORT")


class PF_PT_rig(_Base, bpy.types.Panel):
    bl_label = "Rig"
    bl_idname = "PF_PT_fps_rig"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        layout = self.layout
        obj = context.object

        col = layout.column(align=True)
        col.label(text="Structure")
        col.operator("pf_fps.rig_rename", icon="SORTALPHA")
        col.operator("pf_fps.rig_extract_proxy", icon="UNLINKED")
        col.operator("pf_fps.rig_rename_proxy_bones", icon="GREASEPENCIL")

        col = layout.column(align=True)
        col.label(text="Sockets")
        col.operator("pf_fps.socket_add_bone", icon="BONE_DATA")
        col.operator("pf_fps.socket_add_empty", icon="EMPTY_ARROWS")
        col.operator("pf_fps.socket_snap_cursor", icon="PIVOT_CURSOR")
        col.operator("pf_fps.socket_list", icon="PRESET")

        if obj is not None and obj.type == "ARMATURE":
            found = sorted(registry.sockets_on_armature(obj))
            if found:
                layout.label(text=", ".join(found), icon="EMPTY_AXIS")


class PF_PT_ikfk(_Base, bpy.types.Panel):
    bl_label = "IK / FK"
    bl_idname = "PF_PT_fps_ikfk"
    bl_parent_id = "PF_PT_fps_rig"

    def draw(self, context):
        layout = self.layout
        obj = context.object
        if obj is None or obj.type != "ARMATURE":
            layout.label(text="Select an armature", icon="INFO")
            return
        for side in ("R", "L"):
            table = ikfk.names(side)
            holder = obj.pose.bones.get(table["prop_bone"])
            row = layout.row(align=True)
            if holder is not None and table["prop"] in holder.keys():
                row.prop(holder, '["%s"]' % table["prop"], text="IK " + side, slider=True)
                flip = row.operator("pf_fps.ikfk_switch", text="", icon="ARROW_LEFTRIGHT")
                flip.side = side
            else:
                row.label(text="%s: no switch property" % side, icon="ERROR")

        col = layout.column(align=True)
        snap = col.operator("pf_fps.ikfk_snap", text="Snap FK to IK", icon="SNAP_ON")
        snap.direction, snap.side = "FK_TO_IK", "BOTH"
        snap = col.operator("pf_fps.ikfk_snap", text="Snap IK to FK", icon="SNAP_ON")
        snap.direction, snap.side = "IK_TO_FK", "BOTH"


class PF_PT_clips(_Base, bpy.types.Panel):
    bl_label = "Clips"
    bl_idname = "PF_PT_fps_clips"

    def draw(self, context):
        layout = self.layout
        asset = registry.active_asset(context.scene)
        row = layout.row(align=True)
        row.operator("pf_fps.clip_make_stubs", icon="ADD")
        row.operator("pf_fps.clip_sync_names", icon="FILE_REFRESH", text="")
        if asset is None:
            return

        # The .prx halves ride along with their arms clip; listing both would
        # double the roster without saying anything new.
        group = sorted((a for a in clips.clips_of(asset.id) if not a.name.endswith(".prx")),
                       key=lambda a: (a.pf.category, a.name))
        if not group:
            layout.label(text="No clips yet for " + asset.id, icon="INFO")
            return

        current = clips.active_action(context)
        category = None
        column = layout.column(align=True)
        for action in group:
            if action.pf.category != category:
                category = action.pf.category
                column.separator()
                column.label(text=category.title())
            row = column.row(align=True)
            empty = not clips.has_keys(action)
            row.alert = empty
            op = row.operator("pf_fps.clip_open", text=clips.clip_id_of(action),
                              icon="RADIOBUT_ON" if action is current else
                              ("KEYFRAME" if empty else "KEYFRAME_HLT"))
            op.action_name = action.name
            row.label(text="", icon="LOOP_BACK" if action.pf.loop != "NONE" else "BLANK1")
            row.prop(action.pf, "export", text="")


class PF_PT_clip_detail(_Base, bpy.types.Panel):
    bl_label = "Active Clip"
    bl_idname = "PF_PT_fps_clip_detail"

    def draw(self, context):
        layout = self.layout
        action = clips.active_action(context)
        if action is None:
            layout.label(text="No action on the active object", icon="INFO")
            return
        meta = action.pf
        layout.label(text=action.name, icon="ACTION")
        col = layout.column(align=True)
        col.prop(meta, "clip_id")
        col.prop(meta, "asset")
        col.prop(meta, "category")
        col.prop(meta, "loop")
        row = col.row(align=True)
        row.prop(meta, "blend_in")
        row.prop(meta, "blend_out")
        col.prop(meta, "next_clip")
        col.prop(meta, "notes")

        start, end = clips.frame_span(action)
        fps = context.scene.render.fps / (context.scene.render.fps_base or 1.0)
        layout.label(text="%d-%d  |  %.3f s  |  %s"
                     % (start, end, (end - start) / fps,
                        "animated" if clips.has_keys(action) else "STUB"),
                     icon="TIME")

        # events
        box = layout.box()
        box.label(text="Events", icon="MARKER_HLT")
        row = box.row()
        row.template_list("PF_UL_events", "", meta, "events", meta, "events_index", rows=3)
        side = row.column(align=True)
        add = side.operator("pf_fps.list_item", icon="ADD", text="")
        add.which, add.action_name, add.add = "events", action.name, True
        rem = side.operator("pf_fps.list_item", icon="REMOVE", text="")
        rem.which, rem.action_name, rem.add = "events", action.name, False
        seed = box.operator("pf_fps.clip_seed_events", icon="PRESET")
        seed.action_name = action.name

        # sounds
        box = layout.box()
        box.label(text="Sound", icon="SPEAKER")
        row = box.row()
        row.template_list("PF_UL_sounds", "", meta, "sounds", meta, "sounds_index", rows=3)
        side = row.column(align=True)
        add = side.operator("pf_fps.list_item", icon="ADD", text="")
        add.which, add.action_name, add.add = "sounds", action.name, True
        rem = side.operator("pf_fps.list_item", icon="REMOVE", text="")
        rem.which, rem.action_name, rem.add = "sounds", action.name, False
        if 0 <= meta.sounds_index < len(meta.sounds):
            cue = meta.sounds[meta.sounds_index]
            sub = box.column(align=True)
            sub.prop(cue, "path")
            line = sub.row(align=True)
            line.prop(cue, "bus")
            line.prop(cue, "socket")
            line = sub.row(align=True)
            line.prop(cue, "pitch")
            line.prop(cue, "interruptible", toggle=True)
        line = box.row(align=True)
        line.operator("pf_fps.audio_add_cue", icon="FILE_SOUND", text="Add File").action_name = action.name
        line.operator("pf_fps.audio_push", icon="SEQ_SEQUENCER", text="Push").action_name = action.name
        line.operator("pf_fps.audio_capture", icon="IMPORT", text="Capture").action_name = action.name
        box.operator("pf_fps.audio_clear_strips", icon="TRASH", text="Clear Strips")

        # magnets
        box = layout.box()
        box.label(text="Magnets", icon="CON_CHILDOF")
        row = box.row()
        row.template_list("PF_UL_attach", "", meta, "attach", meta, "attach_index", rows=2)
        side = row.column(align=True)
        add = side.operator("pf_fps.list_item", icon="ADD", text="")
        add.which, add.action_name, add.add = "attach", action.name, True
        rem = side.operator("pf_fps.list_item", icon="REMOVE", text="")
        rem.which, rem.action_name, rem.add = "attach", action.name, False
        if 0 <= meta.attach_index < len(meta.attach):
            rule = meta.attach[meta.attach_index]
            sub = box.column(align=True)
            sub.prop(rule, "owner_bone")
            sub.prop(rule, "constraint")
        box.operator("pf_fps.attach_discover", icon="VIEWZOOM").action_name = action.name


_CLASSES = (
    PF_UL_assets, PF_UL_events, PF_UL_sounds, PF_UL_attach,
    PF_PT_project, PF_PT_assets, PF_PT_rig, PF_PT_ikfk, PF_PT_clips, PF_PT_clip_detail,
)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
