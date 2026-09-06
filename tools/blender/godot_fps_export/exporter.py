"""Export: three small files instead of one big one.

    model   <id>.glb        mesh + its own skeleton + sockets, rest pose
    anim    <id>.anim.glb   skeletons and clips, no meshes
    sidecar <id>.json       what glTF cannot carry: events, sound cues, magnets

Each is written on its own button. A .blend holding forty assets never
re-exports thirty-nine of them because one bolt moved, which is the whole
reason the registry exists.

Two decisions worth knowing about.

*Clips go out as NLA tracks, not as actions.* ``ACTIONS`` mode sweeps
``bpy.data.actions`` and would drag every other weapon's reload into this
weapon's file. Staging one NLA track per clip exports exactly the clips asked
for - and because the exporter merges by track name, the arms track ``reload``
and the proxy track ``reload`` land in Godot as **one** animation driving both
skeletons. No runtime phase-locking of two players.

*The anim file carries a skin anchor.* An armature with no skinned mesh
exports as plain glTF nodes and Godot builds no Skeleton3D, so the clips would
have nothing to drive. One triangle weighted across every bone costs a few
hundred bytes and makes the skeleton real.
"""

from __future__ import annotations

import json
import os
import shutil
import time

import bpy

from . import attach, clips, contract, registry

ANCHOR_NAME = "__pf_skin_anchor"

# Every export names its armature object this, so a Godot scene path is the
# same shape for the rig and for every proxy: Model/Rig/Skeleton3D.
RIG_NODE = "Rig"


class _renamed:
    """Rename data-blocks for the length of an export, then put them back.

    glTF node names come from Blender object names, and those become Godot
    node names. Shipping ``armature`` and ``PROXY.aks74u_type_0`` as scene
    roots would make every runtime path a special case.
    """

    def __init__(self, pairs):
        self.pairs = [(db, name) for db, name in pairs if db is not None]
        self.previous = []

    def __enter__(self):
        for db, name in self.pairs:
            self.previous.append((db, db.name))
            db.name = name
        return self

    def __exit__(self, *exc):
        for db, name in reversed(self.previous):
            try:
                db.name = name
            except (ReferenceError, AttributeError):
                pass
        return False


# --- paths ----------------------------------------------------------------

def project_dir(scene) -> str:
    raw = scene.pf_fps.godot_project
    return bpy.path.abspath(raw) if raw else ""


def content_dir(scene) -> str:
    return os.path.join(project_dir(scene), scene.pf_fps.content_dir)


def asset_dir(scene, asset) -> str:
    return os.path.join(content_dir(scene), contract.KIND_DIR[asset.kind], asset.id)


def res_path(scene, absolute: str) -> str:
    root = project_dir(scene)
    rel = os.path.relpath(absolute, root).replace("\\", "/")
    return "res://" + rel


def fps_of(scene) -> float:
    return float(scene.render.fps) / float(scene.render.fps_base or 1.0)


# --- selection helpers ----------------------------------------------------

def _to_object_mode():
    obj = bpy.context.view_layer.objects.active
    if obj is not None and obj.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")


def _select_only(objects):
    _to_object_mode()
    for obj in bpy.context.view_layer.objects:
        obj.select_set(False)
    live = []
    for obj in objects:
        if obj is None or obj.name not in bpy.context.view_layer.objects:
            continue
        obj.hide_set(False)
        obj.hide_viewport = False
        obj.select_set(True)
        live.append(obj)
    if live:
        bpy.context.view_layer.objects.active = live[0]
    return live


def _gltf(**kw):
    """Call the glTF exporter with whatever flags this Blender build knows."""
    valid = {p.identifier for p in bpy.ops.export_scene.gltf.get_rna_type().properties}
    bpy.ops.export_scene.gltf(**{k: v for k, v in kw.items() if k in valid or k == "filepath"})


COMMON = dict(
    export_format="GLB",
    use_selection=True,
    export_yup=True,
    export_apply=True,
    export_texcoords=True,
    export_normals=True,
    export_tangents=True,
    export_vertex_color="ACTIVE",
    export_materials="EXPORT",
    export_cameras=False,
    export_lights=False,
    export_extras=True,
    export_skins=True,
    export_influence_nb=4,
    export_def_bones=False,
    export_leaf_bone=False,
    export_armature_object_remove=False,
)


# --- skin anchor ----------------------------------------------------------

def _make_anchor(arm):
    """A one-triangle mesh weighted across every bone, so glTF emits a skin."""
    mesh = bpy.data.meshes.new(ANCHOR_NAME)
    mesh.from_pydata([(0.0, 0.0, 0.0), (0.001, 0.0, 0.0), (0.0, 0.001, 0.0)], [], [(0, 1, 2)])
    mesh.update()
    obj = bpy.data.objects.new(ANCHOR_NAME + "." + arm.name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = arm
    obj.matrix_world = arm.matrix_world.copy()
    for bone in arm.data.bones:
        group = obj.vertex_groups.new(name=bone.name)
        group.add([0], 1.0, "REPLACE")
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    return obj


# --- NLA staging ----------------------------------------------------------

_STRIP_FIELDS = ("blend_type", "extrapolation", "influence", "use_auto_blend", "use_animated_influence",
                 "use_reverse", "repeat", "scale", "mute", "action_frame_start", "action_frame_end")


def _snapshot_tracks(adt):
    """Everything needed to put the artist's own NLA back, exactly.

    Muting is not enough: the glTF exporter mutes every track itself and then
    unmutes them one at a time, so a stashed action would come out as an extra
    animation no matter what state it was left in. Tracks have to be gone.
    """
    shot = []
    for track in adt.nla_tracks:
        strips = []
        for strip in track.strips:
            record = {"name": strip.name, "action": strip.action,
                      "slot": getattr(strip, "action_slot", None),
                      "start": strip.frame_start, "end": strip.frame_end}
            for field in _STRIP_FIELDS:
                if hasattr(strip, field):
                    record[field] = getattr(strip, field)
            strips.append(record)
        shot.append({"name": track.name, "mute": track.mute, "lock": track.lock,
                     "solo": track.is_solo, "strips": strips})
    for track in list(adt.nla_tracks):
        adt.nla_tracks.remove(track)
    return shot


def _restore_tracks(adt, shot):
    for entry in shot:
        track = adt.nla_tracks.new()
        track.name = entry["name"]
        for record in entry["strips"]:
            if record["action"] is None:
                continue
            strip = track.strips.new(record["name"], int(record["start"]), record["action"])
            if record.get("slot") is not None:
                try:
                    strip.action_slot = record["slot"]
                except (AttributeError, TypeError):
                    pass
            for field in _STRIP_FIELDS:
                if field in record:
                    try:
                        setattr(strip, field, record[field])
                    except (AttributeError, TypeError, ValueError):
                        pass
            try:
                strip.frame_end = record["end"]
            except (AttributeError, TypeError, ValueError):
                pass
        track.lock = entry["lock"]
        track.mute = entry["mute"]
        track.is_solo = entry["solo"]


def _stage_nla(arm, clip_actions):
    """One NLA track per clip, named after the clip so the exporter merges by it."""
    adt = arm.animation_data or arm.animation_data_create()
    saved = {
        "action": adt.action,
        "slot": getattr(adt, "action_slot", None),
        "tracks": _snapshot_tracks(adt),
        "made": [],
    }
    adt.action = None
    for clip_id, action in clip_actions:
        track = adt.nla_tracks.new()
        track.name = clip_id
        start = int(clips.frame_span(action)[0])
        strip = track.strips.new(clip_id, start, action)
        strip.name = clip_id
        if action.slots:
            try:
                strip.action_slot = action.slots[0]
            except (AttributeError, TypeError):
                pass
        track.mute = False
        saved["made"].append(track)
    return adt, saved


def _unstage_nla(adt, saved):
    for track in list(adt.nla_tracks):
        try:
            adt.nla_tracks.remove(track)
        except (RuntimeError, ReferenceError):
            pass
    _restore_tracks(adt, saved["tracks"])
    adt.action = saved["action"]
    if saved["slot"] is not None and saved["action"] is not None:
        try:
            adt.action_slot = saved["slot"]
        except (AttributeError, TypeError):
            pass


# --- manifest -------------------------------------------------------------

def _parse_args(text):
    out = {}
    for chunk in text.split(","):
        if "=" in chunk:
            key, _, value = chunk.partition("=")
            out[key.strip()] = value.strip()
        elif chunk.strip():
            out[chunk.strip()] = True
    return out


def _socket_records(scene, asset):
    out = {}
    rig_arm = None
    for obj in registry.armatures():
        if registry.tag_of(obj) == scene.pf_fps.rig_id:
            rig_arm = obj
            break
    if rig_arm is not None:
        for sid, bone in registry.sockets_on_armature(rig_arm).items():
            out[sid] = {"space": "bone", "bone": bone, "owner": "rig"}
    proxy = registry.owning_armature(asset.id)
    if proxy is None:
        for obj in registry.armatures():
            if registry.tag_of(obj) == asset.id:
                proxy = obj
                break
    if proxy is not None and proxy is not rig_arm:
        for sid, bone in registry.sockets_on_armature(proxy).items():
            out[sid] = {"space": "bone", "bone": bone, "owner": "asset"}
    for sid, node in registry.sockets_on_objects(asset.id).items():
        out[sid] = {"space": "node", "node": node, "owner": "asset"}
    return out


def _audio_target(scene, cue, copied):
    src = bpy.path.abspath(cue.path)
    if not src or not os.path.exists(src):
        return "", "missing audio: %s" % cue.path
    if not scene.pf_fps.copy_audio:
        return src.replace("\\", "/"), ""
    dest_dir = os.path.join(content_dir(scene), "audio")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(src))
    if src not in copied:
        try:
            shutil.copyfile(src, dest)
        except OSError as exc:
            return "", "audio copy failed: %s" % exc
        copied.add(src)
    return res_path(scene, dest), ""


def build_clip_records(scene, asset, grouped, warnings):
    fps = fps_of(scene)
    copied = set()
    out = {}
    for clip_id, per_arm in sorted(grouped.items()):
        primary = per_arm[0][1]
        start, end = clips.frame_span(primary)
        for _, action in per_arm[1:]:
            other = clips.frame_span(action)
            start, end = min(start, other[0]), max(end, other[1])
        meta = primary.pf

        events = []
        sounds = []
        attach_events = []
        for arm, action in per_arm:
            for ev in action.pf.events:
                events.append({"t": round((ev.frame - start) / fps, 5),
                               "name": ev.name, "args": _parse_args(ev.args)})
            for cue in action.pf.sounds:
                path, problem = _audio_target(scene, cue, copied)
                if problem:
                    warnings.append("%s: %s" % (clip_id, problem))
                    continue
                sounds.append({
                    "t": round((cue.frame - start) / fps, 5),
                    "file": path, "volume": round(cue.volume, 4), "pitch": round(cue.pitch, 4),
                    "bus": cue.bus, "socket": cue.socket,
                    "interruptible": bool(cue.interruptible),
                    "name": cue.name,
                })
            attach_events.extend(attach.timeline(action, arm, start, fps))

        events.sort(key=lambda e: e["t"])
        sounds.sort(key=lambda s: s["t"])
        attach_events.sort(key=lambda a: a["t"])
        stub = not any(clips.has_keys(a) for _, a in per_arm)
        out[clip_id] = {
            "animation": clip_id,
            "actions": {("asset" if registry.tag_of(arm) == asset.id and
                         registry.tag_of(arm) != scene.pf_fps.rig_id else "rig"): action.name
                        for arm, action in per_arm},
            "frames": [int(start), int(end)],
            "length": round((end - start) / fps, 5),
            "loop": meta.loop,
            "category": meta.category,
            "blend_in": round(meta.blend_in, 4),
            "blend_out": round(meta.blend_out, 4),
            "next": meta.next_clip,
            "stub": stub,
            "notes": meta.notes,
            "events": events,
            "sounds": sounds,
            "attach": attach_events,
        }
        if stub:
            warnings.append("stub, not animated yet: " + clip_id)
    return out


def group_clips(scene, asset):
    """{clip_id: [(armature, action), ...]} for one animation set."""
    grouped = {}
    for action in bpy.data.actions:
        if action.pf.asset != asset.id or not action.pf.export:
            continue
        arm = clips.armature_for_clip(action)
        if arm is None:
            continue
        grouped.setdefault(clips.clip_id_of(action), []).append((arm, action))
    return grouped


def skeleton_records(scene, asset):
    out = {}
    for obj in registry.armatures():
        tag = registry.tag_of(obj)
        role = "rig" if tag == scene.pf_fps.rig_id else ("asset" if tag == asset.id else None)
        if role is None:
            continue
        out[role] = {
            "object": obj.name,
            "bones": [b.name for b in obj.data.bones],
            "deform": [b.name for b in obj.data.bones if b.use_deform],
        }
    return out


# --- the three exports ----------------------------------------------------

def export_model(context, asset):
    scene = context.scene
    out_dir = asset_dir(scene, asset)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, asset.id + ".glb")

    meshes = registry.meshes_of(asset.id)
    empties = [o for o in registry.objects_of(asset.id) if o.type == "EMPTY"]
    arm = registry.owning_armature(asset.id)
    if arm is None:
        for obj in registry.armatures():
            if registry.tag_of(obj) == asset.id:
                arm = obj
                break
    if not meshes and arm is None:
        return None, "nothing tagged '%s' to export" % asset.id

    restore = None
    if arm is not None:
        restore = (arm, arm.data.pose_position)
        arm.data.pose_position = "REST"
    renames = [(arm, RIG_NODE)] + [(m.data, asset.id if i == 0 else "%s_%d" % (asset.id, i))
                                   for i, m in enumerate(meshes)]
    _select_only(meshes + empties + ([arm] if arm else []))
    try:
        with _renamed(renames):
            _select_only(meshes + empties + ([arm] if arm else []))
            _gltf(filepath=path, export_animations=False,
                  export_rest_position_armature=True, **COMMON)
    finally:
        if restore:
            restore[0].data.pose_position = restore[1]
    return path, ""


def export_anim(context, asset, warnings):
    scene = context.scene
    grouped = group_clips(scene, asset)
    real = {cid: rows for cid, rows in grouped.items()
            if any(clips.has_keys(a) for _, a in rows)}
    if not real:
        return None, grouped, "no animated clips for '%s' yet - stubs only" % asset.id

    out_dir = asset_dir(scene, asset)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, asset.id + ".anim.glb")

    per_arm = {}
    for clip_id, rows in real.items():
        for arm, action in rows:
            per_arm.setdefault(arm, []).append((clip_id, action))

    rig_id = scene.pf_fps.rig_id
    renames = [(arm, RIG_NODE if registry.tag_of(arm) == rig_id else "Proxy")
               for arm in per_arm]

    staged, anchors = [], []
    try:
        for arm, clip_actions in per_arm.items():
            staged.append(_stage_nla(arm, clip_actions))
            anchors.append(_make_anchor(arm))
        with _renamed(renames):
            _select_only(list(per_arm.keys()) + anchors)
            _gltf(filepath=path,
                  export_animations=True,
                  export_animation_mode="NLA_TRACKS",
                  export_merge_animation="NLA_TRACK",
                  export_force_sampling=True,
                  export_bake_animation=True,
                  export_anim_slide_to_zero=True,
                  export_negative_frame="SLIDE",
                  export_optimize_animation_size=False,
                  export_reset_pose_bones=False,
                  export_rest_position_armature=False,
                  export_frame_step=1,
                  **COMMON)
    finally:
        for adt, saved in staged:
            _unstage_nla(adt, saved)
        for anchor in anchors:
            mesh = anchor.data
            bpy.data.objects.remove(anchor, do_unlink=True)
            bpy.data.meshes.remove(mesh, do_unlink=True)
    return path, grouped, ""


def export_asset(context, asset):
    """Model, animation set and sidecar for one registry row."""
    scene = context.scene
    if not project_dir(scene):
        return {"ok": False, "message": "Set the Godot project folder first"}
    warnings = []
    result = {"asset": asset.id, "kind": asset.kind}

    model_path = None
    if asset.export_mesh:
        model_path, problem = export_model(context, asset)
        if problem:
            warnings.append(problem)

    anim_path, grouped = None, group_clips(scene, asset)
    if asset.export_anim:
        anim_path, grouped, problem = export_anim(context, asset, warnings)
        if problem:
            warnings.append(problem)

    manifest = {
        "version": contract.MANIFEST_VERSION,
        "id": asset.id,
        "kind": asset.kind,
        "rig": scene.pf_fps.rig_id,
        "mount_socket": asset.mount_socket,
        "fps": fps_of(scene),
        "source_blend": bpy.data.filepath.replace("\\", "/"),
        "exported_unix": int(time.time()),
        "model": res_path(scene, model_path) if model_path else "",
        "anim": res_path(scene, anim_path) if anim_path else "",
        "skeletons": skeleton_records(scene, asset),
        "sockets": _socket_records(scene, asset),
        "clips": build_clip_records(scene, asset, grouped, warnings),
        "notes": asset.notes,
        "warnings": warnings,
    }
    out_dir = asset_dir(scene, asset)
    os.makedirs(out_dir, exist_ok=True)
    json_path = os.path.join(out_dir, asset.id + ".json")
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)

    write_wrapper(scene, asset, manifest, out_dir)
    result.update(ok=True, model=model_path, anim=anim_path, json=json_path,
                  clips=len(manifest["clips"]), warnings=warnings)
    return result


def write_wrapper(scene, asset, manifest, out_dir):
    """A .tscn that is already the right node, pointed at the right files."""
    tscn = os.path.join(out_dir, asset.id + ".tscn")
    model = manifest["model"]
    steps = 2 + (1 if model else 0)
    lines = ['[gd_scene load_steps=%d format=3]' % steps, ""]
    lines.append('[ext_resource type="Script" '
                 'path="res://addons/pf_viewmodel/pf_asset.gd" id="1_script"]')
    if model:
        lines.append('[ext_resource type="PackedScene" path="%s" id="2_model"]' % model)
    lines += ["", '[node name="%s" type="Node3D"]' % asset.id,
              'script = ExtResource("1_script")',
              'manifest_path = "%s"' % res_path(scene, os.path.join(out_dir, asset.id + ".json"))]
    if model:
        lines += ["", '[node name="Model" parent="." instance=ExtResource("2_model")]']
    with open(tscn, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return tscn


def write_contract(context):
    """One index at the content root: what exists, and the rules it obeys."""
    scene = context.scene
    root = content_dir(scene)
    os.makedirs(root, exist_ok=True)
    payload = {
        "version": contract.MANIFEST_VERSION,
        "rig": scene.pf_fps.rig_id,
        "fps": fps_of(scene),
        "socket_prefix": contract.SOCKET_PREFIX,
        "categories": [c[0] for c in contract.CATEGORIES],
        "loop_modes": [l[0] for l in contract.LOOP_MODES],
        "assets": [
            {"id": a.id, "kind": a.kind, "mount_socket": a.mount_socket,
             "dir": "res://%s/%s/%s" % (scene.pf_fps.content_dir,
                                        contract.KIND_DIR[a.kind], a.id),
             "manifest": "res://%s/%s/%s/%s.json" % (scene.pf_fps.content_dir,
                                                     contract.KIND_DIR[a.kind], a.id, a.id),
             "notes": a.notes}
            for a in scene.pf_fps.assets if a.id
        ],
        "source_blend": bpy.data.filepath.replace("\\", "/"),
        "exported_unix": int(time.time()),
    }
    path = os.path.join(root, "fps_contract.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
    return path


# --- operators ------------------------------------------------------------

class PF_OT_export_asset(bpy.types.Operator):
    bl_idname = "pf_fps.export_asset"
    bl_label = "Export Active Asset"
    bl_description = "Write the model, the animation set and the sidecar for the active asset"
    bl_options = {"REGISTER"}

    def execute(self, context):
        asset = registry.active_asset(context.scene)
        if asset is None or not asset.id:
            self.report({"ERROR"}, "No active asset")
            return {"CANCELLED"}
        report = export_asset(context, asset)
        if not report.get("ok"):
            self.report({"ERROR"}, report.get("message", "export failed"))
            return {"CANCELLED"}
        write_contract(context)
        for warning in report["warnings"]:
            print("[pf_fps] WARNING " + warning)
        context.scene.pf_fps.last_report = "%s: %d clips, %d warnings" % (
            asset.id, report["clips"], len(report["warnings"]))
        self.report({"INFO"}, context.scene.pf_fps.last_report)
        return {"FINISHED"}


class PF_OT_export_all(bpy.types.Operator):
    bl_idname = "pf_fps.export_all"
    bl_label = "Export Everything"
    bl_description = "Every registry row, then the content index. Slow on purpose - use it before a build"
    bl_options = {"REGISTER"}

    def execute(self, context):
        done, warnings = 0, 0
        for asset in context.scene.pf_fps.assets:
            if not asset.id:
                continue
            report = export_asset(context, asset)
            if report.get("ok"):
                done += 1
                warnings += len(report["warnings"])
                for warning in report["warnings"]:
                    print("[pf_fps] WARNING %s: %s" % (asset.id, warning))
        write_contract(context)
        context.scene.pf_fps.last_report = "%d assets, %d warnings" % (done, warnings)
        self.report({"INFO"}, context.scene.pf_fps.last_report)
        return {"FINISHED"}


class PF_OT_export_contract(bpy.types.Operator):
    bl_idname = "pf_fps.export_contract"
    bl_label = "Write Content Index"
    bl_description = "Refresh fps_contract.json without touching any .glb"
    bl_options = {"REGISTER"}

    def execute(self, context):
        if not project_dir(context.scene):
            self.report({"ERROR"}, "Set the Godot project folder first")
            return {"CANCELLED"}
        path = write_contract(context)
        self.report({"INFO"}, os.path.basename(path))
        return {"FINISHED"}


_CLASSES = (PF_OT_export_asset, PF_OT_export_all, PF_OT_export_contract)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
