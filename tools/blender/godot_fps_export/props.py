"""Property groups. Everything the artist sets in the N-panel lives here.

The pattern throughout: settings live on the data-block they describe, not in
a side table. A clip's loop mode is on the Action, an asset membership is on
the Object/Bone. Copy an Action to another .blend and its Godot metadata,
its events and its sound cues travel with it.
"""

from __future__ import annotations

import bpy
from bpy.props import (
    BoolProperty, CollectionProperty, EnumProperty, FloatProperty,
    IntProperty, PointerProperty, StringProperty,
)
from bpy.types import PropertyGroup

from . import contract


class PFEvent(PropertyGroup):
    """A named instant inside a clip. Godot emits it as a signal."""

    name: StringProperty(
        name="Name", default="event",
        description="Signal name Godot emits, e.g. 'shell_eject', 'footstep', 'tear_start'")
    frame: IntProperty(
        name="Frame", default=1,
        description="Scene frame. Converted to seconds on export using the scene FPS")
    args: StringProperty(
        name="Args", default="",
        description="Free-form payload as comma-separated key=value pairs. "
                    "Reaches Godot as a Dictionary")


class PFSound(PropertyGroup):
    """A sound cue pinned to a frame of a clip.

    Kept on the Action rather than in the sequencer so that re-timing a clip
    and re-timing its audio are the same edit. The VSE is the scrub surface -
    push cues out to it to hear them, capture them back when they land right.
    """

    name: StringProperty(name="Label", default="")
    path: StringProperty(
        name="File", subtype="FILE_PATH", default="",
        description="Audio file. Copied next to the manifest on export")
    frame: IntProperty(
        name="Frame", default=1,
        description="Frame the sound starts on. Negative frames pre-roll before the clip")
    volume: FloatProperty(name="Volume", default=1.0, min=0.0, max=4.0)
    pitch: FloatProperty(name="Pitch", default=1.0, min=0.01, max=4.0)
    bus: StringProperty(
        name="Bus", default="SFX",
        description="Godot audio bus name. Must exist in the project, or Godot falls back to Master")
    socket: StringProperty(
        name="At socket", default="",
        description="Socket id to play from, e.g. 'muzzle'. Empty plays at the viewmodel root")
    interruptible: BoolProperty(
        name="Interruptible", default=True,
        description="Off keeps the sound playing when the clip is cut short")


class PFAttachRule(PropertyGroup):
    """One magnet: a part that changes what it hangs off during a clip.

    Timing is read from the rig, not typed here - the influence curve of the
    named CHILD_OF constraint is the source of truth, so re-timing the reload
    in the dope sheet re-times the magnet with it.
    """

    part: StringProperty(
        name="Part", default="",
        description="What moves in the game: an asset id, or a socket id on this asset")
    owner_object: StringProperty(name="Owner Object", default="")
    owner_bone: StringProperty(
        name="Owner Bone", default="",
        description="Pose bone carrying the CHILD_OF constraint")
    constraint: StringProperty(
        name="Constraint", default="",
        description="Name of the CHILD_OF constraint whose influence curve drives the swap")
    socket: StringProperty(
        name="Socket", default="",
        description="Socket id the part hangs off while this constraint is at full influence")
    invert: BoolProperty(
        name="Reversed in rig", default=False,
        description="Tick when the rig constrains the hand to the part, but in game the part "
                    "must follow the hand. The reference AK rig is built the reversed way")


class PFClipProps(PropertyGroup):
    """Godot metadata for one Action."""

    export: BoolProperty(
        name="Export", default=True,
        description="Untick to keep the Action in the file but out of the anim set")
    clip_id: StringProperty(
        name="Clip", default="",
        description="Name Godot plays it by. Empty falls back to the Action name before the '@'")
    asset: StringProperty(
        name="Asset", default="",
        description="Asset id this clip belongs to")
    category: EnumProperty(name="Category", items=contract.CATEGORIES, default="WEAPON")
    loop: EnumProperty(name="Loop", items=contract.LOOP_MODES, default="NONE")
    blend_in: FloatProperty(
        name="Blend In", default=0.08, min=0.0, max=2.0,
        description="Seconds of cross-fade when this clip starts")
    blend_out: FloatProperty(name="Blend Out", default=0.10, min=0.0, max=2.0)
    next_clip: StringProperty(
        name="Next", default="",
        description="Clip to fall through to when this one ends, e.g. reload -> idle")
    stub: BoolProperty(
        name="Stub", default=False,
        description="Placeholder with no keys yet. Export skips it and the report lists it")
    notes: StringProperty(name="Notes", default="")

    events: CollectionProperty(type=PFEvent)
    events_index: IntProperty(default=0)
    sounds: CollectionProperty(type=PFSound)
    sounds_index: IntProperty(default=0)
    attach: CollectionProperty(type=PFAttachRule)
    attach_index: IntProperty(default=0)


class PFAsset(PropertyGroup):
    """One exportable thing. The registry row.

    A RIG asset owns the base skeleton. Everything else is a proxy: its own
    small armature, its own actions, exported and swapped on its own.
    """

    id: StringProperty(
        name="Id", default="",
        description="Folder and scene name in Godot. Convention: <thing>_type_<n>, so a second "
                    "winchester with a different bolt is winchester_type_1")
    kind: EnumProperty(name="Kind", items=contract.KINDS, default="WEAPON")
    mount_socket: StringProperty(
        name="Mount", default="hand.R",
        description="Base-rig socket this proxy hangs off by default. Its own SK.attach socket "
                    "is what lands on it")
    export_mesh: BoolProperty(
        name="Mesh", default=True,
        description="Write the model .glb. Untick for an animation-only asset")
    export_anim: BoolProperty(
        name="Anim", default=True,
        description="Write the animation set .glb: skeletons and clips, no meshes")
    notes: StringProperty(name="Notes", default="")


class PFSceneProps(PropertyGroup):
    godot_project: StringProperty(
        name="Godot project", subtype="DIR_PATH", default="",
        description="Folder holding project.godot. Exports land under <project>/content/")
    content_dir: StringProperty(
        name="Content folder", default="content",
        description="Relative to the Godot project root")
    rig_id: StringProperty(
        name="Rig id", default="arms_base",
        description="The base skeleton every proxy and every animation set is measured against")
    copy_audio: BoolProperty(
        name="Copy audio", default=True,
        description="Copy every referenced sound file into <content>/audio/ on export")

    assets: CollectionProperty(type=PFAsset)
    assets_index: IntProperty(default=0)

    last_report: StringProperty(default="")


_CLASSES = (PFEvent, PFSound, PFAttachRule, PFClipProps, PFAsset, PFSceneProps)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)
    bpy.types.Scene.pf_fps = PointerProperty(type=PFSceneProps)
    bpy.types.Action.pf = PointerProperty(type=PFClipProps)


def unregister():
    del bpy.types.Action.pf
    del bpy.types.Scene.pf_fps
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
