"""One base skeleton, many proxies.

The base rig is the arms and nothing else. Every weapon, blade, focus and
bottle is a *proxy*: its own small Armature object, its own Actions, exported
and swapped on its own. A health flask needs two bones - body and cap - and
paying for eighty is the reason one-armature rigs rot.

Blender happily poses several armatures at once (select both, Ctrl-Tab), so
animating arms-plus-weapon is unchanged. What does change is that the arms
keys and the weapon keys land in *different Actions*, which is exactly the
split the exporter needs and the reason this is not merely tidiness.

Naming, once, so nothing downstream has to guess:

    deform      root, chest, arm_upper.R, arm_twist_2.R, hand.R, index_1.R
    control     CTL.hand_ik.R, CTL.hand_pole.R, CTL.arm_lower_fk.L, CTL.cam
    socket      SK.hand.R, SK.muzzle, SK.mag_well

``.L`` / ``.R`` is not cosmetic: it is what turns on X-Mirror, Flip Pose and
Symmetrize. The old ``_r`` / ``_l`` suffix turns all three off.
"""

from __future__ import annotations

import bpy

from . import contract, registry

PROXY_PREFIX = "PROXY."
CTL_PREFIX = "CTL."

# --- the rename map -------------------------------------------------------

FINGER_NAMES = {"1": "thumb", "2": "index", "3": "middle", "4": "ring", "5": "pinky"}


def base_rename_map(arm):
    """old -> new for every bone of the reference FPS arms rig.

    Built by rule rather than typed out, so a rig with an extra twist bone or
    a sixth finger renames just as cleanly.
    """
    out = {}
    for bone in arm.data.bones:
        name = bone.name
        low = name.lower()
        if contract.socket_id(name) or name.startswith(CTL_PREFIX):
            continue  # already on contract

        side = ""
        stem = low
        for suffix, tag in (("_r", ".R"), ("_l", ".L")):
            if low.endswith(suffix):
                side, stem = tag, low[: -len(suffix)]
                break

        new = None
        if stem in {"root", "chest"} and not side:
            continue
        elif stem == "upperarm":
            new = "arm_upper"
        elif stem == "forearm":
            new = "arm_lower"
        elif stem == "hand":
            new = "hand"
        elif stem.startswith("forearm_twist_"):
            new = "arm_twist_" + stem.rsplit("_", 1)[-1]
        elif stem.startswith("palm_"):
            digit = stem.rsplit("_", 1)[-1]
            new = "palm_" + FINGER_NAMES.get(digit, digit)
        elif stem.startswith("finger_"):
            digits = stem.rsplit("_", 1)[-1]
            if len(digits) == 2 and digits.isdigit():
                new = FINGER_NAMES.get(digits[0], digits[0]) + "_" + digits[1]
        elif stem in {"upperarm_ik", "forearm_ik", "upperarm_fk", "forearm_fk", "hand_fk"}:
            part, mode = stem.rsplit("_", 1)
            part = {"upperarm": "arm_upper", "forearm": "arm_lower", "hand": "hand"}[part]
            new = CTL_PREFIX + part + "_" + mode
        elif stem == "hand_ik":
            new = CTL_PREFIX + "hand_ik"
        elif stem == "hand_ik_pole":
            new = CTL_PREFIX + "hand_pole"

        if new:
            out[name] = new + side
    return out


# --- bone collections -----------------------------------------------------

BASE_COLLECTIONS = ("Deform", "Ctrl.Root", "Ctrl.IK", "Ctrl.FK",
                    "Ctrl.Fingers.L", "Ctrl.Fingers.R", "Sockets")

FINGER_STEMS = ("thumb", "index", "middle", "ring", "pinky", "palm")


def collection_for(bone) -> str:
    name = bone.name
    if contract.socket_id(name):
        return "Sockets"
    if name.startswith(CTL_PREFIX):
        rest = name[len(CTL_PREFIX):]
        if "_ik" in rest or "_pole" in rest:
            return "Ctrl.IK"
        if "_fk" in rest:
            return "Ctrl.FK"
        return "Ctrl.Root"
    stem = name.split(".")[0]
    if any(stem.startswith(f) for f in FINGER_STEMS):
        return "Ctrl.Fingers.R" if name.endswith(".R") else "Ctrl.Fingers.L"
    if name in {"root", "chest"}:
        return "Ctrl.Root"
    return "Deform"


def rebuild_collections(arm):
    data = arm.data
    for existing in list(data.collections_all):
        try:
            data.collections.remove(existing)
        except (RuntimeError, ReferenceError):
            pass
    made = {}
    for name in BASE_COLLECTIONS:
        made[name] = data.collections.new(name)
    for bone in data.bones:
        made[collection_for(bone)].assign(bone)
    # Deform bones are noise while animating; the artist unhides them to check
    # skinning and hides them again.
    made["Deform"].is_visible = False
    return made


# --- fcurve plumbing ------------------------------------------------------

def _channelbag(action, obj, create=True):
    """The one channelbag of a single-slot Action, made if missing."""
    if action.layers:
        strip = action.layers[0].strips[0]
        slot = action.slots[0] if action.slots else None
        if slot is None and create:
            slot = action.slots.new(obj.id_type, obj.name)
        return strip.channelbag(slot, ensure=create) if slot else None
    if not create:
        return None
    slot = action.slots.new(obj.id_type, obj.name)
    strip = action.layers.new("Layer").strips.new(type="KEYFRAME")
    return strip.channelbag(slot, ensure=True)


def _copy_fcurve(src, bag):
    dst = bag.fcurves.new(data_path=src.data_path, index=src.array_index)
    dst.extrapolation = src.extrapolation
    dst.keyframe_points.add(len(src.keyframe_points))
    for a, b in zip(src.keyframe_points, dst.keyframe_points):
        b.co = a.co
        b.handle_left = a.handle_left
        b.handle_right = a.handle_right
        b.handle_left_type = a.handle_left_type
        b.handle_right_type = a.handle_right_type
        b.interpolation = a.interpolation
        b.easing = a.easing
        b.type = a.type
    dst.update()
    return dst


def _bone_of_path(data_path):
    prefix = 'pose.bones["'
    if not data_path.startswith(prefix):
        return None
    rest = data_path[len(prefix):]
    end = rest.find('"]')
    return rest[:end] if end > 0 else None


def split_action(action, base_obj, proxy_obj, moved_bones, proxy_asset_id):
    """Move every fcurve that drives a relocated bone into a new Action.

    Returns the new Action, or None when the source touched no moved bone.
    The naming is ``<clip>@<asset>`` so a dope-sheet full of actions sorts by
    clip first and by owner second.
    """
    bag = _channelbag(action, base_obj, create=False)
    if bag is None:
        return None
    doomed = [fc for fc in bag.fcurves if _bone_of_path(fc.data_path) in moved_bones]
    if not doomed:
        return None

    # ``<clip>@<set>`` is the arms half, ``<clip>@<set>.prx`` the proxy half.
    # Same clip, same set, two skeletons - the exporter puts both on one NLA
    # track and Godot receives them as a single animation.
    clip = action.pf.clip_id or action.name.split("@")[0]
    new = bpy.data.actions.new("%s@%s.prx" % (clip, proxy_asset_id))
    new.use_fake_user = True
    new_bag = _channelbag(new, proxy_obj, create=True)
    for fc in doomed:
        _copy_fcurve(fc, new_bag)
    for fc in doomed:
        bag.fcurves.remove(fc)

    new.pf.clip_id = clip
    new.pf.asset = proxy_asset_id
    new.pf.category = action.pf.category
    new.pf.loop = action.pf.loop
    new.use_frame_range = True
    new.frame_start, new.frame_end = action.frame_range
    if not action.name.endswith("@" + action.pf.asset) and action.pf.asset:
        action.name = "%s@%s" % (clip, action.pf.asset)
    action.pf.clip_id = clip
    return new


# --- proxy extraction -----------------------------------------------------

def _copy_constraint(src, dst_pb, remap_obj, moved):
    con = dst_pb.constraints.new(src.type)
    for prop in src.bl_rna.properties:
        pid = prop.identifier
        if prop.is_readonly or pid in {"rna_type", "type", "is_valid", "error_location",
                                       "error_rotation", "is_override_data"}:
            continue
        try:
            setattr(con, pid, getattr(src, pid))
        except (AttributeError, TypeError, ValueError):
            pass
    con.name = src.name
    sub = getattr(con, "subtarget", None)
    if sub and sub in moved:
        con.target = remap_obj
    return con


def extract_proxy(context, asset_id):
    """Lift every bone tagged *asset_id* out of the base rig into PROXY.<id>."""
    scene = context.scene
    base = registry.owning_armature(asset_id)
    if base is None:
        return None, "No bones tagged '%s'" % asset_id
    if registry.tag_of(base) == asset_id:
        return None, "'%s' already owns its own armature" % asset_id

    moved = {b.name for b in base.data.bones if registry.tag_of(b) == asset_id}
    if not moved:
        return None, "No bones tagged '%s'" % asset_id

    if context.object is not None and context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    proxy_name = PROXY_PREFIX + asset_id
    arm_data = bpy.data.armatures.new(proxy_name)
    proxy = bpy.data.objects.new(proxy_name, arm_data)
    proxy.matrix_world = base.matrix_world.copy()
    (base.users_collection[0] if base.users_collection else scene.collection).objects.link(proxy)
    registry.set_tag(proxy, asset_id)

    # 1. rest geometry
    rest = {}
    view = context.view_layer
    view.objects.active = base
    bpy.ops.object.mode_set(mode="EDIT")
    for name in moved:
        eb = base.data.edit_bones[name]
        rest[name] = {
            "head": eb.head.copy(), "tail": eb.tail.copy(), "roll": eb.roll,
            "parent": eb.parent.name if eb.parent else None,
            "connect": eb.use_connect, "deform": eb.use_deform,
            "envelope": eb.envelope_distance, "radius_head": eb.head_radius,
            "radius_tail": eb.tail_radius,
        }
    bpy.ops.object.mode_set(mode="OBJECT")

    view.objects.active = proxy
    bpy.ops.object.mode_set(mode="EDIT")
    for name, r in rest.items():
        eb = arm_data.edit_bones.new(name)
        eb.head, eb.tail, eb.roll = r["head"], r["tail"], r["roll"]
        eb.use_deform = r["deform"]
        eb.head_radius, eb.tail_radius = r["radius_head"], r["radius_tail"]
        eb.envelope_distance = r["envelope"]
    for name, r in rest.items():
        parent = r["parent"]
        if parent in moved:
            arm_data.edit_bones[name].parent = arm_data.edit_bones[parent]
            arm_data.edit_bones[name].use_connect = r["connect"]
    bpy.ops.object.mode_set(mode="OBJECT")

    # 2. pose settings, custom props and constraints
    for name in moved:
        src_pb, dst_pb = base.pose.bones[name], proxy.pose.bones[name]
        dst_pb.rotation_mode = src_pb.rotation_mode
        dst_pb.custom_shape = src_pb.custom_shape
        dst_pb.custom_shape_scale_xyz = src_pb.custom_shape_scale_xyz
        for key in src_pb.keys():
            try:
                dst_pb[key] = src_pb[key]
            except (TypeError, KeyError):
                pass
        for con in src_pb.constraints:
            _copy_constraint(con, dst_pb, proxy, moved)
        registry.set_tag(proxy.data.bones[name], asset_id)

    # 3. constraints left in the base rig that pointed at a moved bone
    for pb in base.pose.bones:
        for con in pb.constraints:
            if getattr(con, "target", None) is base and getattr(con, "subtarget", "") in moved:
                con.target = proxy

    # 4. meshes follow their bones
    for mesh in registry.meshes_of(asset_id):
        for mod in mesh.modifiers:
            if mod.type == "ARMATURE" and mod.object is base:
                mod.object = proxy
        if mesh.parent is base:
            world = mesh.matrix_world.copy()
            mesh.parent = proxy
            mesh.matrix_parent_inverse = proxy.matrix_world.inverted()
            mesh.matrix_world = world

    # 5. actions
    split = []
    for action in list(bpy.data.actions):
        made = split_action(action, base, proxy, moved, asset_id)
        if made is not None:
            split.append(made.name)

    # 6. finally drop the bones from the base rig
    view.objects.active = base
    bpy.ops.object.mode_set(mode="EDIT")
    for name in moved:
        eb = base.data.edit_bones.get(name)
        if eb is not None:
            base.data.edit_bones.remove(eb)
    bpy.ops.object.mode_set(mode="OBJECT")
    view.objects.active = proxy

    return proxy, "moved %d bones, split %d actions (%s)" % (
        len(moved), len(split), ", ".join(split) or "none")


# --- operators ------------------------------------------------------------

class PF_OT_rig_rename(bpy.types.Operator):
    bl_idname = "pf_fps.rig_rename"
    bl_label = "Rename To Contract"
    bl_description = ("Rename the active armature's bones to the dotted .L/.R contract and rebuild "
                      "the bone collections. Constraints, drivers, actions and vertex groups follow")
    bl_options = {"REGISTER", "UNDO"}

    rebuild_layers: bpy.props.BoolProperty(name="Rebuild bone collections", default=True)

    @classmethod
    def poll(cls, context):
        return context.object is not None and context.object.type == "ARMATURE"

    def execute(self, context):
        arm = context.object
        if arm.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        mapping = base_rename_map(arm)
        clash = [n for n in mapping.values() if n in arm.data.bones and n not in mapping]
        if clash:
            self.report({"ERROR"}, "Target names already taken: " + ", ".join(sorted(clash)[:5]))
            return {"CANCELLED"}
        for old, new in mapping.items():
            arm.data.bones[old].name = new
        if self.rebuild_layers:
            rebuild_collections(arm)
        self.report({"INFO"}, "Renamed %d bones on %s" % (len(mapping), arm.name))
        return {"FINISHED"}


class PF_OT_rig_extract_proxy(bpy.types.Operator):
    bl_idname = "pf_fps.rig_extract_proxy"
    bl_label = "Extract Proxy Rig"
    bl_description = ("Move every bone tagged with the active asset into its own PROXY.<id> "
                      "armature, carrying its meshes, constraints and animation with it")
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        asset = registry.active_asset(context.scene)
        if asset is None or not asset.id:
            self.report({"ERROR"}, "No active asset")
            return {"CANCELLED"}
        proxy, message = extract_proxy(context, asset.id)
        if proxy is None:
            self.report({"ERROR"}, message)
            return {"CANCELLED"}
        self.report({"INFO"}, "%s: %s" % (proxy.name, message))
        return {"FINISHED"}


class PF_OT_rig_rename_proxy_bones(bpy.types.Operator):
    bl_idname = "pf_fps.rig_rename_proxy_bones"
    bl_label = "Strip Proxy Prefix"
    bl_description = ("Drop a shared prefix from every bone of the active proxy armature. "
                      "'ak_zatvor' becomes 'zatvor' once the armature itself says which weapon it is")
    bl_options = {"REGISTER", "UNDO"}

    prefix: bpy.props.StringProperty(name="Prefix", default="ak_")

    def invoke(self, context, event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        arm = context.object
        if arm is None or arm.type != "ARMATURE":
            return {"CANCELLED"}
        if arm.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        n = 0
        for bone in list(arm.data.bones):
            if bone.name.startswith(self.prefix) and len(bone.name) > len(self.prefix):
                new = bone.name[len(self.prefix):]
                if new not in arm.data.bones:
                    bone.name = new
                    n += 1
        self.report({"INFO"}, "Stripped '%s' from %d bones" % (self.prefix, n))
        return {"FINISHED"}


_CLASSES = (PF_OT_rig_rename, PF_OT_rig_extract_proxy, PF_OT_rig_rename_proxy_bones)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
