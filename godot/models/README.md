# Asset slots

Drop processed assets here and they replace the procedural fallbacks automatically
(`scripts/render3d/models.gd`). With these folders empty the game runs 100% on
procedural meshes and CC0 textures at $0.00. `tools/gate_check.py` audits every
GLB found here against this contract (step 2).

| Slot | File | Contract |
|---|---|---|
| Heroes | `heroes/<warden\|spark\|ember\|storm>.glb` | 38.0u tall, feet at Y=0, +X forward, rigged (skin), clips `idle`, `walk`, `run`, `cast` (0.50-1.10 s), `roll` (0.40-0.80 s), `jump` (0.50-1.00 s), `die`; every clip >= 0.40 s |
| Bosses | `bosses/<boss id>.glb` | 88.0u tall, feet at Y=0, +X forward, rigged, clips `idle`, `walk`, `attack`, `slam`, `die` |
| Foes | `foes/<grunt\|runner\|brute\|spitter\|charger>.glb` | 24-42u tall, feet at Y=0, +X forward, identity mesh node, <= 1,800 tris, `<id>_albedo.png` + `<id>_normal.png` + `<id>_orm.png`, `<id>.vat` (SVA3: `walk`, `attack`, `hit`, `death`, `spawn`, vertex column in UV2.x) |
| Props | `props/<kind>.glb` | `tree` 130u, `tree_dead` 125u, `arch` 120u, `pillar` 95u, `wall` 65u, `rock` 38u, `bush` 26u, `bones` 22u; feet at Y=0, identity mesh node, PBR `<kind>_albedo/_normal/_orm.png` |

Texture budgets (`tools/texture_budget.py`): 2048 px for hero/boss/landmark/foe
albedo, 1024 px for prop/foe normal + ORM and clutter albedo, all VRAM-compressed
(`compress/mode=2`). Normal/ORM maps must have per-channel R/G std >= 3.0.

SVA3 layout (little endian): `"SVA3"`, u32 version, u32 vertex count, u32 clip
count, then per clip `char[16] name, u32 start_frame, u32 frames, f32 fps`, then
`f32 xyz` offsets for `[total_frames][vertex]`.
