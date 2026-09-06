"""Clips: the Actions, their Godot metadata, their events and their sounds.

An Action named ``reload_empty@aks74u_type_0`` is one clip of one asset. The
``@`` is a convention the tools read and write, so a dope sheet full of
actions sorts by clip first and by owner second, and nothing has to be typed
twice.

Stubs are real Actions with no keys. They exist so that the roster, the
manifest, the Godot lab list and this contract all agree on what the game
expects *before* anybody animates. Export skips them and the report names
them, so an unfinished set is loud rather than silent.
"""

from __future__ import annotations

import bpy

from . import clip_presets, contract, registry


def clip_id_of(action) -> str:
    return action.pf.clip_id or action.name.split("@")[0]


def action_name(clip_id: str, asset_id: str) -> str:
    return "%s@%s" % (clip_id, asset_id) if asset_id else clip_id


def channelbag(action, obj=None, create=False):
    if action.layers:
        strip = action.layers[0].strips[0]
        slot = action.slots[0] if action.slots else None
        if slot is None:
            if not (create and obj):
                return None
            slot = action.slots.new(obj.id_type, obj.name)
        return strip.channelbag(slot, ensure=create)
    if not (create and obj):
        return None
    slot = action.slots.new(obj.id_type, obj.name)
    strip = action.layers.new("Layer").strips.new(type="KEYFRAME")
    return strip.channelbag(slot, ensure=True)


def has_keys(action) -> bool:
    bag = channelbag(action)
    return bool(bag and len(bag.fcurves))


def clips_of(asset_id: str):
    return [a for a in bpy.data.actions if a.pf.asset == asset_id]


def frame_span(action):
    if action.use_frame_range:
        return float(action.frame_start), float(action.frame_end)
    lo, hi = action.curve_frame_range
    return (float(lo), float(hi)) if hi > lo else (1.0, 2.0)


def active_action(context):
    """The Action currently on the active object, if any."""
    obj = context.object
    adt = getattr(obj, "animation_data", None) if obj else None
    return adt.action if adt else None


def driven_bones(action):
    """Bone names this clip actually keys, read off the curve paths."""
    bag = channelbag(action)
    if bag is None:
        return set()
    out = set()
    for fcurve in bag.fcurves:
        if fcurve.data_path.startswith('pose.bones["'):
            out.add(fcurve.data_path.split('"')[1])
    return out


def armature_for_clip(action):
    """The armature this clip drives.

    Decided by the bones it keys, not by its asset tag. One animation set holds
    the arms half and the proxy half of the same clip, and both are tagged with
    the same asset - only the curves say which skeleton each one moves.
    """
    wanted = driven_bones(action)
    if wanted:
        best, score = None, 0
        for obj in registry.armatures():
            hits = sum(1 for name in wanted if name in obj.data.bones)
            if hits > score:
                best, score = obj, hits
        if best is not None:
            return best
    for asset_id in (action.pf.asset, bpy.context.scene.pf_fps.rig_id):
        arm = registry.owning_armature(asset_id)
        if arm is not None:
            return arm
        for obj in registry.armatures():
            if registry.tag_of(obj) == asset_id:
                return obj
    return None


def ensure_stub(asset_id, clip_id, category, loop, frames, next_clip, notes, arm, suffix=""):
    """One empty Action, ready to animate.

    A weapon clip needs two: the arms half on the base rig and the ``.prx``
    half on the proxy. They carry the same clip id, go on one NLA track, and
    reach Godot as a single animation driving both skeletons.
    """
    name = action_name(clip_id, asset_id) + suffix
    action = bpy.data.actions.get(name)
    created = action is None
    if created:
        action = bpy.data.actions.new(name)
    action.use_fake_user = True
    if arm is not None:
        channelbag(action, arm, create=True)
    if created or not has_keys(action):
        action.use_frame_range = True
        action.frame_start, action.frame_end = 1.0, float(max(2, frames))
        action.pf.stub = True
    action.pf.clip_id = clip_id
    action.pf.asset = asset_id
    action.pf.category = category
    action.pf.loop = loop
    action.pf.next_clip = next_clip
    if notes and not action.pf.notes:
        action.pf.notes = notes
    action.use_cyclic = loop != "NONE"
    return action, created


def seed_events(action, overwrite=False):
    """Give a clip the events its kind always has, placed proportionally."""
    spec = clip_presets.DEFAULT_EVENTS.get(clip_id_of(action))
    if not spec:
        return 0
    if len(action.pf.events) and not overwrite:
        return 0
    if overwrite:
        action.pf.events.clear()
    start, end = frame_span(action)
    span = max(1.0, end - start)
    for name, frac in spec:
        ev = action.pf.events.add()
        ev.name = name
        ev.frame = int(round(start + span * frac))
    return len(spec)


# --- operators ------------------------------------------------------------

class PF_OT_clip_make_stubs(bpy.types.Operator):
    bl_idname = "pf_fps.clip_make_stubs"
    bl_label = "Create Animation Stubs"
    bl_description = ("Create the empty Actions this asset kind is expected to have, with their "
                      "categories, loop modes, chaining and default events already set")
    bl_options = {"REGISTER", "UNDO"}

    seed: bpy.props.BoolProperty(
        name="Seed default events", default=True,
        description="Place the events that clip always has - shell_eject, mag_out, hit_open")

    def execute(self, context):
        asset = registry.active_asset(context.scene)
        if asset is None or not asset.id:
            self.report({"ERROR"}, "No active asset")
            return {"CANCELLED"}
        rows = clip_presets.GROUPS.get(asset.kind)
        if not rows:
            self.report({"ERROR"}, "No preset roster for kind %s" % asset.kind)
            return {"CANCELLED"}
        rig_id = context.scene.pf_fps.rig_id
        rig_arm = next((o for o in registry.armatures()
                        if registry.tag_of(o) == rig_id), None)
        proxy = next((o for o in registry.armatures()
                      if registry.tag_of(o) == asset.id and o is not rig_arm), None)
        # The arms half drives the base rig even for a weapon clip; only the
        # moving parts of the weapon live on the proxy.
        primary = rig_arm if asset.kind != "RIG" else rig_arm
        made = 0
        for clip_id, category, loop, frames, next_clip, notes in rows:
            action, created = ensure_stub(asset.id, clip_id, category, loop,
                                          frames, next_clip, notes, primary)
            made += int(created)
            if self.seed:
                seed_events(action)
            if proxy is not None:
                _, spawned = ensure_stub(asset.id, clip_id, category, loop,
                                         frames, next_clip, "", proxy, suffix=".prx")
                made += int(spawned)
        self.report({"INFO"}, "%s: %d new stubs, %d clips total"
                    % (asset.id, made, len(clips_of(asset.id))))
        return {"FINISHED"}


class PF_OT_clip_open(bpy.types.Operator):
    bl_idname = "pf_fps.clip_open"
    bl_label = "Open Clip"
    bl_description = "Assign this clip to its armature and set the scene range to its frames"
    bl_options = {"REGISTER", "UNDO"}

    action_name: bpy.props.StringProperty()

    def execute(self, context):
        action = bpy.data.actions.get(self.action_name)
        if action is None:
            return {"CANCELLED"}
        arm = armature_for_clip(action)
        if arm is None:
            self.report({"ERROR"}, "No armature owns asset '%s'" % action.pf.asset)
            return {"CANCELLED"}
        adt = arm.animation_data or arm.animation_data_create()
        adt.action = action
        bag = channelbag(action, arm, create=True)
        if action.slots:
            adt.action_slot = action.slots[0]
        start, end = frame_span(action)
        context.scene.frame_start = int(start)
        context.scene.frame_end = int(end)
        context.scene.frame_current = int(start)
        context.view_layer.objects.active = arm
        self.report({"INFO"}, "%s on %s [%d-%d]" % (action.name, arm.name, start, end))
        return {"FINISHED"}


class PF_OT_clip_sync_names(bpy.types.Operator):
    bl_idname = "pf_fps.clip_sync_names"
    bl_label = "Sync Clip Names"
    bl_description = ("Read clip id and asset out of every Action name shaped 'clip@asset', and "
                      "rename Actions whose metadata and name disagree")
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        known = {a.id for a in context.scene.pf_fps.assets}
        touched = 0
        for action in bpy.data.actions:
            if "@" in action.name:
                clip, _, asset = action.name.partition("@")
                if not action.pf.clip_id:
                    action.pf.clip_id = clip
                if not action.pf.asset and asset in known:
                    action.pf.asset = asset
            elif action.pf.clip_id and action.pf.asset:
                action.name = action_name(action.pf.clip_id, action.pf.asset)
                touched += 1
            action.pf.stub = not has_keys(action)
        self.report({"INFO"}, "Renamed %d actions" % touched)
        return {"FINISHED"}


class PF_OT_clip_seed_events(bpy.types.Operator):
    bl_idname = "pf_fps.clip_seed_events"
    bl_label = "Seed Default Events"
    bl_description = "Place this clip's usual events proportionally along its current length"
    bl_options = {"REGISTER", "UNDO"}

    overwrite: bpy.props.BoolProperty(name="Replace existing", default=False)
    action_name: bpy.props.StringProperty()

    def execute(self, context):
        action = bpy.data.actions.get(self.action_name) or active_action(context)
        if action is None:
            self.report({"ERROR"}, "No active action")
            return {"CANCELLED"}
        n = seed_events(action, self.overwrite)
        self.report({"INFO"}, "%d events on %s" % (n, action.name))
        return {"FINISHED"}


class PF_OT_list_item(bpy.types.Operator):
    """Add or remove a row on the active Action's event / sound / attach list."""

    bl_idname = "pf_fps.list_item"
    bl_label = "Edit List"
    bl_options = {"REGISTER", "UNDO"}

    which: bpy.props.EnumProperty(items=[("events", "events", ""), ("sounds", "sounds", ""),
                                         ("attach", "attach", "")])
    action_name: bpy.props.StringProperty()
    add: bpy.props.BoolProperty(default=True)

    def execute(self, context):
        action = bpy.data.actions.get(self.action_name)
        if action is None:
            return {"CANCELLED"}
        coll = getattr(action.pf, self.which)
        idx_name = self.which + "_index"
        if self.add:
            item = coll.add()
            item.frame = context.scene.frame_current
            setattr(action.pf, idx_name, len(coll) - 1)
        else:
            idx = getattr(action.pf, idx_name)
            if 0 <= idx < len(coll):
                coll.remove(idx)
                setattr(action.pf, idx_name, max(0, idx - 1))
        return {"FINISHED"}


_CLASSES = (PF_OT_clip_make_stubs, PF_OT_clip_open, PF_OT_clip_sync_names,
            PF_OT_clip_seed_events, PF_OT_list_item)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
