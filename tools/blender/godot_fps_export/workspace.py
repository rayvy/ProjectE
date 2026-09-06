"""The FPS Anim workspace.

Four surfaces, because animating a first-person clip needs all four at once
and tabbing between them is where the afternoon goes:

    3D Viewport      the pose, camera-locked
    Action Editor    which clip, and its keys
    Graph Editor     the curves, especially constraint influence
    Video Sequencer  the sound cues, with waveforms, scrubbing against the pose

Built rather than shipped as a .blend so it lands in whatever file you are
already working in, without importing anything else along with it.
"""

from __future__ import annotations

import bpy

WORKSPACE = "FPS Anim"


def _split(screen, area, direction, factor):
    """Split *area* and hand back (first, second) in screen order.

    Area references go stale the moment the screen is re-laid-out, and the
    coordinates of everything move, so the only reliable way to find the two
    halves is to diff the area list and sort the pair geometrically.
    """
    before = set(screen.areas)
    with bpy.context.temp_override(window=bpy.context.window, area=area):
        bpy.ops.screen.area_split(direction=direction, factor=factor)
    created = [a for a in screen.areas if a not in before]
    if not created:
        return area, None
    pair = [area, created[0]]
    key = (lambda a: a.y) if direction == "HORIZONTAL" else (lambda a: a.x)
    pair.sort(key=key)
    return pair[0], pair[1]


def _largest(screen, space_type=None):
    areas = [a for a in screen.areas if space_type is None or a.type == space_type]
    return max(areas, key=lambda a: a.width * a.height) if areas else None


def _set(area, ui_type):
    try:
        area.ui_type = ui_type
    except (TypeError, ValueError):
        area.type = ui_type


def build(context):
    existing = bpy.data.workspaces.get(WORKSPACE)
    if existing is not None:
        context.window.workspace = existing
        return existing, "already there - switched to it"

    bpy.ops.workspace.duplicate()
    workspace = context.window.workspace
    workspace.name = WORKSPACE
    screen = workspace.screens[0]

    main = _largest(screen, "VIEW_3D") or _largest(screen)
    if main is None:
        return workspace, "could not find an area to build on"

    # Bottom half becomes the animation surfaces, in two passes so the
    # sequencer ends up as a shallow strip rather than a quarter of the screen.
    lower, upper = _split(screen, main, "HORIZONTAL", 0.38)
    strip, middle = _split(screen, lower, "HORIZONTAL", 0.34)
    left, right = _split(screen, middle, "VERTICAL", 0.55)

    _set(upper, "VIEW_3D")
    _set(strip, "SEQUENCE_EDITOR")
    _set(left, "DOPESHEET")
    if right is not None:
        _set(right, "FCURVES")

    for area in screen.areas:
        for space in area.spaces:
            if space.type == "DOPESHEET_EDITOR":
                try:
                    space.mode = "ACTION"
                    space.show_pose_markers = True
                except (AttributeError, TypeError):
                    pass
            elif space.type == "SEQUENCE_EDITOR":
                space.view_type = "SEQUENCER"
    context.scene.use_audio_scrub = True
    context.scene.sync_mode = "AUDIO_SYNC"
    return workspace, "built"


class PF_OT_workspace_build(bpy.types.Operator):
    bl_idname = "pf_fps.workspace_build"
    bl_label = "Build FPS Anim Workspace"
    bl_description = ("Add a workspace with the viewport, Action Editor, Graph Editor and "
                      "sequencer laid out for first-person animation, and turn on audio scrub")
    bl_options = {"REGISTER"}

    def execute(self, context):
        try:
            workspace, message = build(context)
        except RuntimeError as exc:
            self.report({"ERROR"}, "Layout failed: %s" % exc)
            return {"CANCELLED"}
        self.report({"INFO"}, "%s: %s" % (workspace.name, message))
        return {"FINISHED"}


_CLASSES = (PF_OT_workspace_build,)


def register():
    for cls in _CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
