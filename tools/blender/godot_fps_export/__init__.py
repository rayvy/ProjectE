"""Godot FPS Player Export.

One base arms skeleton, one proxy rig per weapon or prop, and three small
files per asset instead of one big one:

    <id>.glb        mesh + its own skeleton + sockets, rest pose
    <id>.anim.glb   skeletons and clips, no meshes
    <id>.json       events, sound cues and magnets - what glTF cannot carry

Three rules hold the whole thing together, and nothing else is special:

    SK.<id>       a bone or Empty with this prefix is a socket. Godot can hang
                  anything off it by name, and inventing a new one needs no
                  code on either side.
    use_deform    decides what is exported. Control bones stay in Blender.
    pf_asset      a string on the object or bone saying which asset owns it.

Behaviour is never encoded in a name. ``SK.muzzle`` is a point called muzzle;
that Godot raycasts from it is Godot's business.

Panel: 3D Viewport > Sidebar (N) > Godot FPS.
"""

bl_info = {
    "name": "Godot FPS Player Export",
    "author": "Project E",
    "version": (1, 0, 0),
    "blender": (4, 4, 0),
    "location": "3D Viewport > Sidebar (N) > Godot FPS",
    "description": "Base rig plus proxy assets, animation stubs, sockets, events, sound and "
                   "a Godot-side manifest",
    "category": "Pipeline",
}

import importlib
import sys

from . import (
    attach, audio, clip_presets, clips, contract, exporter, ikfk,
    props, registry, rigsplit, sockets, ui, validate, workspace,
)

# Reload-friendly: re-running the add-on from the text editor picks up edits
# instead of silently keeping the first import.
_MODULES = (contract, clip_presets, props, registry, sockets, clips, attach,
            audio, rigsplit, ikfk, validate, workspace, exporter, ui)

if "bpy" in locals():
    for _module in _MODULES:
        importlib.reload(_module)

import bpy  # noqa: E402

# props must come first: everything else reads Scene.pf_fps and Action.pf.
_REGISTRARS = (props, registry, sockets, clips, attach, audio, rigsplit,
               ikfk, validate, workspace, exporter, ui)


def register():
    for module in _REGISTRARS:
        module.register()


def unregister():
    for module in reversed(_REGISTRARS):
        try:
            module.unregister()
        except Exception:
            # One module failing must not strand the rest half-registered.
            import traceback
            traceback.print_exc()


if __name__ == "__main__":
    register()
