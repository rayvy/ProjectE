"""Sound, and how it stays in sync.

The sequencer is the *scrub surface*, not the storage. Cues live on the Action
next to the events, because a clip that gets retimed has to retime its audio
with it, and a sequencer strip has no idea which clip it belonged to.

The round trip:

    Push    clip cues  ->  VSE sound strips     hear it, drag it, trim it
    Capture VSE strips ->  clip cues            keep what you dragged

Frames are stored in the clip's own frame space - the same numbers you see in
the dope sheet - so export is a subtraction and a divide by 60, and nothing
drifts when the clip moves on the timeline.
"""

from __future__ import annotations

import os

import bpy

from . import clips

STRIP_TAG = "PF|"
PF_CHANNEL = 1


def ensure_editor(scene):
    if scene.sequence_editor is None:
        scene.sequence_editor_create()
    return scene.sequence_editor


def pf_strips(scene):
    ed = scene.sequence_editor
    if ed is None:
        return []
    return [s for s in ed.strips_all if s.type == "SOUND" and s.name.startswith(STRIP_TAG)]


def sound_strips(scene):
    ed = scene.sequence_editor
    if ed is None:
        return []
    return [s for s in ed.strips_all if s.type == "SOUND"]


def clear_pf_strips(scene):
    ed = scene.sequence_editor
    if ed is None:
        return 0
    doomed = pf_strips(scene)
    for strip in doomed:
        ed.strips.remove(strip)
    return len(doomed)


class PF_OT_audio_push(bpy.types.Operator):
    bl_idname = "pf_fps.audio_push"
    bl_label = "Push Cues To Timeline"
    bl_description = ("Lay this clip's sound cues out as sequencer strips so they can be heard "
                      "while scrubbing. Replaces the strips this tool put there before")
    bl_options = {"REGISTER", "UNDO"}

    action_name: bpy.props.StringProperty()

    def execute(self, context):
        scene = context.scene
        action = bpy.data.actions.get(self.action_name) or clips.active_action(context)
        if action is None:
            self.report({"ERROR"}, "No active clip")
            return {"CANCELLED"}
        ed = ensure_editor(scene)
        clear_pf_strips(scene)
        made = 0
        for i, cue in enumerate(action.pf.sounds):
            path = bpy.path.abspath(cue.path)
            if not path or not os.path.exists(path):
                self.report({"WARNING"}, "missing: %s" % cue.path)
                continue
            name = "%s%s|%s" % (STRIP_TAG, clips.clip_id_of(action), cue.name or str(i))
            strip = ed.strips.new_sound(name=name, filepath=path,
                                        channel=PF_CHANNEL + (i % 4), frame_start=int(cue.frame))
            strip.volume = cue.volume
            strip.show_waveform = True
            made += 1
        scene.use_audio_scrub = True
        self.report({"INFO"}, "%d strips on the timeline" % made)
        return {"FINISHED"}


class PF_OT_audio_capture(bpy.types.Operator):
    bl_idname = "pf_fps.audio_capture"
    bl_label = "Capture Timeline Into Clip"
    bl_description = ("Read every sound strip on the timeline back into this clip's cue list, "
                      "keeping wherever they were dragged to")
    bl_options = {"REGISTER", "UNDO"}

    action_name: bpy.props.StringProperty()
    replace: bpy.props.BoolProperty(
        name="Replace list", default=True,
        description="Off appends instead, for building a cue list from several passes")

    def execute(self, context):
        action = bpy.data.actions.get(self.action_name) or clips.active_action(context)
        if action is None:
            self.report({"ERROR"}, "No active clip")
            return {"CANCELLED"}
        strips = sorted(sound_strips(context.scene), key=lambda s: s.frame_final_start)
        if not strips:
            self.report({"WARNING"}, "No sound strips on the timeline")
            return {"CANCELLED"}
        if self.replace:
            action.pf.sounds.clear()
        for strip in strips:
            cue = action.pf.sounds.add()
            label = strip.name
            if label.startswith(STRIP_TAG):
                label = label.rsplit("|", 1)[-1]
            cue.name = label
            cue.path = strip.sound.filepath if strip.sound else ""
            cue.frame = int(strip.frame_final_start)
            cue.volume = float(strip.volume)
        action.pf.sounds_index = 0
        self.report({"INFO"}, "%d cues on %s" % (len(strips), action.name))
        return {"FINISHED"}


class PF_OT_audio_add_cue(bpy.types.Operator):
    bl_idname = "pf_fps.audio_add_cue"
    bl_label = "Add Sound Cue"
    bl_description = "Pick an audio file and pin it to the current frame of this clip"
    bl_options = {"REGISTER", "UNDO"}

    filepath: bpy.props.StringProperty(subtype="FILE_PATH")
    filter_glob: bpy.props.StringProperty(default="*.ogg;*.wav;*.mp3;*.flac", options={"HIDDEN"})
    action_name: bpy.props.StringProperty()

    def invoke(self, context, event):
        context.window_manager.fileselect_add(self)
        return {"RUNNING_MODAL"}

    def execute(self, context):
        action = bpy.data.actions.get(self.action_name) or clips.active_action(context)
        if action is None:
            self.report({"ERROR"}, "No active clip")
            return {"CANCELLED"}
        cue = action.pf.sounds.add()
        cue.path = self.filepath
        cue.name = os.path.splitext(os.path.basename(self.filepath))[0]
        cue.frame = context.scene.frame_current
        action.pf.sounds_index = len(action.pf.sounds) - 1
        self.report({"INFO"}, "%s at frame %d" % (cue.name, cue.frame))
        return {"FINISHED"}


class PF_OT_audio_clear_strips(bpy.types.Operator):
    bl_idname = "pf_fps.audio_clear_strips"
    bl_label = "Clear Pushed Strips"
    bl_description = "Remove the sequencer strips this tool created. Hand-placed strips stay"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        n = clear_pf_strips(context.scene)
        self.report({"INFO"}, "Removed %d strips" % n)
        return {"FINISHED"}


_CLASSES = (PF_OT_audio_push, PF_OT_audio_capture,
            PF_OT_audio_add_cue, PF_OT_audio_clear_strips)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
