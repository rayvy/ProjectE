"""The contract. Everything the exporter and Godot agree on lives here.

Three rules, and nothing else is special:

1.  A bone or empty named ``SK.<socket_id>`` is a **socket** - a magnet point.
    It is exported, it lands in the manifest, Godot can attach to it. The
    ``<socket_id>`` half is free-form: invent ``SK.scope_mount`` today and it
    shows up in Godot tonight without touching a line of GDScript.

2.  Everything else follows ``use_deform``. Deform bones are exported, control
    bones (IK targets, poles, FK chains, rig proxies) are not. That is already
    true of the reference rig, so no bone gets renamed to adopt this.

3.  Membership is a string. ``bone["pf_asset"]`` / ``object["pf_asset"]`` names
    the asset the thing belongs to. One .blend holds a hundred assets; export
    reads this one key to decide what leaves the file.

Names never encode behaviour. ``SK.muzzle`` is not "the muzzle" to the
exporter - it is a point called ``muzzle`` that Godot happens to raycast from.
"""

from __future__ import annotations

# --- keys -----------------------------------------------------------------

ASSET_KEY = "pf_asset"          # str, on Object and Bone
SOCKET_PREFIX = "SK."           # bone / empty name prefix
CLIP_KEY = "pf_clip"            # dict, on Action

# --- asset kinds ----------------------------------------------------------
# The kind picks the output folder and the generated .tscn root type. Adding a
# kind here is the whole job of adding a kind.

KINDS = (
    ("RIG",      "Rig",       "Arms / viewmodel skeleton. There is normally one"),
    ("WEAPON",   "Weapon",    "Firearm: has moving parts, muzzle, magazine"),
    ("MELEE",    "Melee",     "Sword, dagger, axe. Usually one rigid piece"),
    ("PROP",     "Prop",      "Bottle, grenade, key, lever. Grabbable"),
    ("MAGIC",    "Magic",     "Spell focus, rune, conjured object"),
)

KIND_DIR = {
    "RIG":    "rig",
    "WEAPON": "assets",
    "MELEE":  "assets",
    "PROP":   "assets",
    "MAGIC":  "assets",
}

# --- clip categories ------------------------------------------------------
# Category is a hint for the Godot AnimationTree builder, not a behaviour.

CATEGORIES = (
    ("POSE",     "Pose",       "Held indefinitely: idle, ads_idle, low_ready"),
    ("LOCO",     "Locomotion", "Cycles that follow movement speed"),
    ("WEAPON",   "Weapon",     "fire, reload, draw, holster, inspect, jam"),
    ("CONTEXT",  "Context",    "Interaction with the world: door, ladder, pickup, finisher"),
    ("MAGIC",    "Magic",      "Cast, channel, dismiss"),
    ("ADDITIVE", "Additive",   "Layered on top of everything: recoil, sway, breath"),
)

LOOP_MODES = (
    ("NONE",     "None",      "Plays once and stops on the last frame"),
    ("LINEAR",   "Loop",      "Wraps back to the first frame"),
    ("PINGPONG", "Ping-Pong", "Plays forward then backward"),
)

# The socket ids the generated scenes and the demo lab look for by name. They
# are *conventions*, not requirements - an asset without them still exports.
SUGGESTED_RIG_SOCKETS = ("hand.R", "hand.L", "cam", "chest")
SUGGESTED_ASSET_SOCKETS = ("grip", "foregrip", "muzzle", "eject", "sight", "mag_well", "attach")

MANIFEST_VERSION = 1


def socket_id(name: str) -> str | None:
    """``SK.muzzle`` -> ``muzzle``. Anything else -> None."""
    if name.startswith(SOCKET_PREFIX) and len(name) > len(SOCKET_PREFIX):
        return name[len(SOCKET_PREFIX):]
    return None


def socket_name(sid: str) -> str:
    return SOCKET_PREFIX + sid


def slug(text: str) -> str:
    """Lower-case, underscore-joined, safe as a folder and a Godot node name."""
    out = []
    for ch in text.strip().lower():
        out.append(ch if (ch.isalnum() or ch == "_") else "_")
    s = "".join(out)
    while "__" in s:
        s = s.replace("__", "_")
    return s.strip("_") or "unnamed"
