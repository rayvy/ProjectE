# Project F Core

Portable Godot 4.x addon. Copy `addons/project_f_core/` into any project.

Bone-name contract (parsed, nothing hardcoded per character):

| Prefix | Solver | Notes |
|---|---|---|
| `TypeJiggle.` | Simple spring (ferraTechLab bounded inertial) | Soft tissue. Chain = parent→child of the same prefix. |
| `TypeHair.` | World-space Verlet + body capsules | Hanging strands that lag with head motion. |
| `TypeCloth.` | World-space Verlet + body capsules | Fabric panels; collide with legs/arms/torso. |
| `TypeNone.` | **Not simulated in Godot** | Artistic “physics” authored in Blender as drivers/constraints. |

## Materials come from Blender node groups

A material reaches Godot **only if** the Blender material contains a
`PF_Mat.<Family>` node group. No group, no sidecar entry, and `PFMaterialApplier`
leaves the imported material alone.

Everything else is mechanical. Each group input socket becomes a shader
parameter named after the socket, slugified: `Wrinkle Height` → `pf_wrinkle_height`.

| In Blender | In `character.materials.json` | In Godot |
|---|---|---|
| image plugged into a socket | `maps.<uniform>.godot_path` | `set_shader_parameter(uniform, texture)` |
| `PF_UNIFORM_*` value node | `channels.<uniform>.bound` | driven per frame by `PFMeshDriver` |
| nothing plugged in | `params.<uniform>` | `set_shader_parameter(uniform, value)` |

**Nothing is hardcoded per family.** Adding a socket in Blender is the whole
job — the uniform appears here on its own, and a shader that does not declare
it ignores the write. `PFMaterialRules.UNIFORM_ALIASES` exists only to keep a
handful of pre-contract uniform names (`base_texture`, `normal_texture`, …)
working; the applier writes both spellings.

Textures are copied next to the GLB by the Blender exporter, not left to glTF.
glTF only carries maps it recognises on a Principled BSDF, and a height map
plugged into a node group is not one of them.

## Dynamic wrinkles (`PFMeshDriver`)

A wrinkle is a **height field**. One channel instead of three, layers sum
without renormalisation, and the same texture drives Blender's Bump node — so
the viewport preview and the game agree by construction.

The shader takes three taps of `pf_wrinkle_height`, turns the gradient into a
tangent-space slope, and **adds** it to the base normal's slope rather than
lerping the vectors (two lerped normals cancel into a flatter surface; two
summed slopes read as both details).

```gdscript
$MeshDriver.ArmPitRaisedL              # current value
$MeshDriver.ArmPitRaisedL = 1.0        # manual override, holds
$MeshDriver.release("ArmPitRaisedL")   # back to the armature
$MeshDriver.get_channel("Whatever")    # channels beyond the four defaults
```

Shader contract in `skin_endfield_reference.gdshader`:

```glsl
uniform vec4      pf_ch;                // one channel per component, 0..1
uniform vec4      pf_zone_0..3;         // xyz = centre in model space, w = radius
uniform sampler2D pf_wrinkle_height;    // from the PF_Mat socket
uniform float     pf_wrinkle_strength;  // from the PF_Mat socket
uniform float     pf_zone_debug;        // magenta tint, for placing zones
```

Zone centres are pushed **every frame** in model space, so the mask rides the
pose. Each channel is masked by its own zone, which is how the left and right
armpit crease independently from one shared height map.

Channel values come from a `ROTATION_DIFF` between two bones, folded into
`[0, π]` so both sides of the body agree with Blender. `_bone_quat` reads the
*global* bone pose for the same reason — Blender compares pose bones in
armature space, and parent-local rotations would disagree on every bone that
has a parent.

Lab switches: `godot --path . -- --pf-debug` (tint the zones), `--pf-force`
(all channels at 1), `--pf-shot=<abs.png>` (grab a frame, quit).
In-game: **K** toggles the zone tint, **J** forces all channels.

Going multi-character: swap `set_shader_parameter` in `_push_material` for
`instance uniform` + `set_instance_shader_parameter`.

## Usage

```
var physics := PFBonePhysics.new()
character.add_child(physics)
physics.setup(skeleton)   # auto-discovers Type* chains
# after AnimationMixer:
physics.step(delta)
```

Or add a `PFBonePhysics` node in the editor, assign `skeleton`, leave `auto_setup` on.

`TypeNone.Sleeves.*` slide along `forearm_stretch.*` is a Blender Toolkit operator (Rig tab), not this addon.
