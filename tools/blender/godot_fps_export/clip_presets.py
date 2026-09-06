"""The roster of animation slots, as data.

Each row is ``(clip_id, category, loop, frames, next_clip, notes)``. ``frames``
is only a starting length for the stub - retime freely, export reads the real
range off the action.

This file is the one place to add an animation to the pipeline. Add a row,
press *Create Stubs*, and the clip exists in Blender, in the manifest, in the
Godot lab list and in the contract report without touching anything else.
"""

from __future__ import annotations

# --- shared by every weapon-shaped asset ----------------------------------

FIREARM = [
    ("draw",            "WEAPON",   "NONE",     30,  "idle",  "From holstered to ready. Weapon enters frame"),
    ("holster",         "WEAPON",   "NONE",     26,  "",      "Mirror of draw. Ends off-screen"),
    ("idle",            "POSE",     "LINEAR",   120, "",      "Breathing loop, hip position. The rest state"),
    ("idle_ads",        "POSE",     "LINEAR",   120, "",      "Breathing loop with the sight on the camera axis"),
    ("ads_in",          "WEAPON",   "NONE",     12,  "idle_ads", "Hip to sight. Keep it under 0.2 s"),
    ("ads_out",         "WEAPON",   "NONE",     10,  "idle",  "Sight back to hip"),
    ("walk",            "LOCO",     "LINEAR",   40,  "",      "One full stride. Loop point must match frame 1"),
    ("run",             "LOCO",     "LINEAR",   28,  "",      "One full stride, faster and wider"),
    ("sprint_pose",     "POSE",     "LINEAR",   60,  "",      "Weapon lowered across the body, cannot fire"),
    ("fire",            "WEAPON",   "NONE",     14,  "idle",  "Hip fire. Bolt cycles here, shell leaves at the event"),
    ("fire_ads",        "WEAPON",   "NONE",     14,  "idle_ads", "Same timing, less muzzle travel"),
    ("fire_last",       "WEAPON",   "NONE",     20,  "idle",  "Final round. Bolt locks back and stays"),
    ("reload",          "WEAPON",   "NONE",     150, "idle",  "Magazine still has a round: no bolt cycle"),
    ("reload_empty",    "WEAPON",   "NONE",     226, "idle",  "Bolt starts locked back and is released at the end"),
    ("inspect",         "WEAPON",   "NONE",     120, "idle",  "Idle flourish. Triggered by the player, interruptible"),
    ("jam",             "WEAPON",   "NONE",     40,  "idle",  "Weapon stops. Ends in the jammed pose"),
    ("melee_bash",      "WEAPON",   "NONE",     36,  "idle",  "Butt-stroke with the weapon still held"),
    ("add_recoil",      "ADDITIVE", "NONE",     18,  "",      "Additive over any pose. Delta from the rest pose only"),
    ("add_recoil_ads",  "ADDITIVE", "NONE",     18,  "",      "Tighter additive for the sighted pose"),
    ("add_sway",        "ADDITIVE", "LINEAR",   180, "",      "Slow additive drift driven by look input"),
]

MELEE = [
    ("draw",            "WEAPON",   "NONE",     28,  "idle",  ""),
    ("holster",         "WEAPON",   "NONE",     24,  "",      ""),
    ("idle",            "POSE",     "LINEAR",   120, "",      "Guard stance"),
    ("walk",            "LOCO",     "LINEAR",   40,  "",      ""),
    ("run",             "LOCO",     "LINEAR",   28,  "",      ""),
    ("sprint_pose",     "POSE",     "LINEAR",   60,  "",      ""),
    ("attack_light_1",  "WEAPON",   "NONE",     30,  "idle",  "Combo step 1. Leave the last 6 frames cancellable"),
    ("attack_light_2",  "WEAPON",   "NONE",     30,  "idle",  "Combo step 2, entered from step 1"),
    ("attack_light_3",  "WEAPON",   "NONE",     40,  "idle",  "Combo finisher, no cancel window"),
    ("attack_heavy",    "WEAPON",   "NONE",     55,  "idle",  "Wind-up long enough to read as commitment"),
    ("attack_thrust",   "WEAPON",   "NONE",     32,  "idle",  ""),
    ("block_idle",      "POSE",     "LINEAR",   90,  "",      "Held while the block button is down"),
    ("block_hit",       "WEAPON",   "NONE",     22,  "block_idle", "Impact on a held block"),
    ("parry",           "WEAPON",   "NONE",     26,  "idle",  "Timed deflect, opens the enemy"),
    ("add_recoil",      "ADDITIVE", "NONE",     16,  "",      "Impact shake, additive"),
]

MAGIC = [
    ("draw",            "MAGIC",    "NONE",     26,  "idle",  "Hand opens, focus appears"),
    ("holster",         "MAGIC",    "NONE",     22,  "",      ""),
    ("idle",            "POSE",     "LINEAR",   120, "",      ""),
    ("walk",            "LOCO",     "LINEAR",   40,  "",      ""),
    ("cast_start",      "MAGIC",    "NONE",     30,  "cast_loop", "Wind-up. Ends in the charged pose"),
    ("cast_loop",       "MAGIC",    "LINEAR",   60,  "",      "Held while charging. Loops seamlessly"),
    ("cast_release",    "MAGIC",    "NONE",     34,  "idle",  "The spell leaves the hand at the event"),
    ("cast_cancel",     "MAGIC",    "NONE",     20,  "idle",  "Charge dropped, no spell"),
    ("rune_draw",       "MAGIC",    "NONE",     90,  "idle",  "Finger traces a sigil. Trace path as events"),
]

PROP = [
    ("draw",            "WEAPON",   "NONE",     24,  "idle",  ""),
    ("holster",         "WEAPON",   "NONE",     20,  "",      ""),
    ("idle",            "POSE",     "LINEAR",   90,  "",      ""),
    ("use",             "CONTEXT",  "NONE",     90,  "idle",  "Drink, inject, read. Effect fires on the event"),
    ("throw_pull",      "WEAPON",   "NONE",     30,  "throw_hold", "Pin out, spoon still held"),
    ("throw_hold",      "POSE",     "LINEAR",   60,  "",      "Cooking loop. Fuse is already burning"),
    ("throw_release",   "WEAPON",   "NONE",     26,  "idle",  "Object leaves the hand at the event"),
]

# --- the rig itself: weapon-agnostic, empty hands --------------------------

RIG = [
    ("unarmed_idle",      "POSE",    "LINEAR", 120, "",  "Empty hands, relaxed"),
    ("unarmed_walk",      "LOCO",    "LINEAR", 40,  "",  ""),
    ("unarmed_run",       "LOCO",    "LINEAR", 28,  "",  ""),
    ("unarmed_sprint",    "LOCO",    "LINEAR", 24,  "",  "Arms pumping, wide"),
    ("jump_start",        "LOCO",    "NONE",   12,  "jump_loop", ""),
    ("jump_loop",         "LOCO",    "LINEAR", 30,  "",  "Airborne hold"),
    ("land_soft",         "LOCO",    "NONE",   18,  "unarmed_idle", ""),
    ("land_hard",         "LOCO",    "NONE",   34,  "unarmed_idle", "Hands catch the ground"),
    ("ladder_up",         "CONTEXT", "LINEAR", 60,  "",  "One rung per half cycle. Hand contact on the beat"),
    ("ladder_down",       "CONTEXT", "LINEAR", 60,  "",  ""),
    ("ladder_mount",      "CONTEXT", "NONE",   40,  "ladder_up", "Grab the first rung from the ground"),
    ("ladder_dismount",   "CONTEXT", "NONE",   40,  "unarmed_idle", ""),
    ("vault_low",         "CONTEXT", "NONE",   40,  "unarmed_idle", "Hand plants on the obstacle"),
    ("climb_ledge",       "CONTEXT", "NONE",   70,  "unarmed_idle", "Both hands, full pull-up"),
    ("door_push",         "CONTEXT", "NONE",   45,  "unarmed_idle", "Flat palm on the door"),
    ("door_pull",         "CONTEXT", "NONE",   50,  "unarmed_idle", "Grip on the handle, body steps back"),
    ("door_knob",         "CONTEXT", "NONE",   60,  "unarmed_idle", "Turn then push. Two contacts"),
    ("button_press",      "CONTEXT", "NONE",   30,  "unarmed_idle", "Index finger, single contact"),
    ("lever_pull",        "CONTEXT", "NONE",   50,  "unarmed_idle", ""),
    ("pickup_small",      "CONTEXT", "NONE",   40,  "unarmed_idle", "Object attaches to SK.hand_r on the event"),
    ("pickup_large",      "CONTEXT", "NONE",   60,  "unarmed_idle", "Two hands"),
    ("shove",             "CONTEXT", "NONE",   28,  "unarmed_idle", "Both palms forward"),
    ("hurt_light",        "CONTEXT", "NONE",   24,  "unarmed_idle", "Additive-friendly flinch"),
    ("hurt_heavy",        "CONTEXT", "NONE",   45,  "unarmed_idle", ""),
    ("death",             "CONTEXT", "NONE",   70,  "",  "Camera falls with the hands"),
    ("finisher_jaw_rip",  "CONTEXT", "NONE",   150, "unarmed_idle",
     "Two-hand grab on the jaw. Needs SK.hand_r and SK.hand_l contact events for the victim rig"),
    ("finisher_neck_grab", "CONTEXT", "NONE",  120, "unarmed_idle", "One-hand grab and hold"),
    ("finisher_stomp",    "CONTEXT", "NONE",   90,  "unarmed_idle", "Camera only, hands brace"),
]

GROUPS = {
    "RIG": RIG,
    "WEAPON": FIREARM,
    "MELEE": MELEE,
    "MAGIC": MAGIC,
    "PROP": PROP,
}

# Events worth stubbing on the clips that always have them. ``frac`` is a
# fraction of the clip length, so a retimed clip keeps a sane starting point.
DEFAULT_EVENTS = {
    "fire":           [("muzzle_flash", 0.05), ("shell_eject", 0.25), ("recoil", 0.02)],
    "fire_ads":       [("muzzle_flash", 0.05), ("shell_eject", 0.25), ("recoil", 0.02)],
    "fire_last":      [("muzzle_flash", 0.05), ("shell_eject", 0.25), ("bolt_lock", 0.55)],
    "reload":         [("mag_out", 0.25), ("mag_in", 0.65), ("reload_done", 0.95)],
    "reload_empty":   [("mag_out", 0.20), ("mag_in", 0.55), ("bolt_release", 0.80), ("reload_done", 0.95)],
    "draw":           [("weapon_visible", 0.05), ("ready", 0.9)],
    "holster":        [("weapon_hidden", 0.85)],
    "melee_bash":     [("hit", 0.4)],
    "attack_light_1": [("hit_open", 0.30), ("hit_close", 0.45), ("cancel_open", 0.75)],
    "attack_light_2": [("hit_open", 0.30), ("hit_close", 0.45), ("cancel_open", 0.75)],
    "attack_light_3": [("hit_open", 0.35), ("hit_close", 0.55)],
    "attack_heavy":   [("hit_open", 0.55), ("hit_close", 0.70)],
    "attack_thrust":  [("hit_open", 0.40), ("hit_close", 0.55)],
    "parry":          [("parry_open", 0.10), ("parry_close", 0.35)],
    "cast_release":   [("spell_spawn", 0.45)],
    "use":            [("effect", 0.60)],
    "throw_release":  [("object_release", 0.35)],
    "pickup_small":   [("grab", 0.55)],
    "pickup_large":   [("grab", 0.55)],
    "button_press":   [("contact", 0.55)],
    "door_push":      [("contact", 0.35), ("door_moves", 0.45)],
    "door_pull":      [("contact", 0.30), ("door_moves", 0.50)],
    "door_knob":      [("contact", 0.25), ("knob_turned", 0.50), ("door_moves", 0.65)],
    "lever_pull":     [("contact", 0.30), ("lever_moves", 0.50)],
    "ladder_up":      [("hand_r_grab", 0.05), ("hand_l_grab", 0.55)],
    "ladder_down":    [("hand_r_grab", 0.05), ("hand_l_grab", 0.55)],
    "vault_low":      [("hand_plant", 0.35), ("hand_release", 0.65)],
    "climb_ledge":    [("hand_r_grab", 0.20), ("hand_l_grab", 0.30), ("hand_release", 0.85)],
    "land_hard":      [("hand_plant", 0.25)],
    "finisher_jaw_rip": [("grab", 0.25), ("tear_start", 0.55), ("tear_done", 0.75), ("release", 0.9)],
    "finisher_neck_grab": [("grab", 0.30), ("release", 0.85)],
    "finisher_stomp": [("hit", 0.55)],
    "shove":          [("hit", 0.45)],
}
