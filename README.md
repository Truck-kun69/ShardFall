# Shardfall: Rift Survivors

Mobile-first 3D survivor action roguelite. **Godot 4.7.2, Mobile (Vulkan)
renderer, Android arm64-v8a only.** There is no web build and no lite build.

- 4 heroes (Warden, Sparkcaller, Emberwitch, Stormwright), 5 themed acts, each with a boss.
- 60 Hz fixed-step simulation (`godot/scripts/sim/`) with render interpolation, a
  720-slot structure-of-arrays swarm, 5 archetypes plus elites, 5 elements with
  reaction cascades, dodge roll with perfect-dodge riposte, and a vaulting jump.
- Deterministic chunked props with collision. The same layout is used on every quality tier.
- Low / Medium / High quality auto-detected from GPU + RAM, overridable in Options,
  with an OpenGL ES 3 safe mode for unstable Mali Vulkan drivers.
- Runs entirely on procedural meshes, clips, audio and CC0 textures ($0.00). Generated
  assets dropped into `godot/models/` replace them (see `godot/models/README.md`).

## Layout

```
godot/                 Godot project (open this folder in the editor)
  scripts/sim/         fixed step, swarm, spatial grid, terrain, prop layout, bosses, world
  scripts/render3d/    quality tiers, world view, menu stage, FX, models, hero/boss rigs
  scripts/ui/          touch controls, HUD, menus
  scripts/autoload/    save profile, procedural audio
  shaders/3d/          terrain (+ shared height include), water, fog, props, foes, decals
  tests/               gate_chunk.tscn, tests.tscn (unit), render_shot.tscn (GPU smoke)
tools/
  gate_check.py        release gate (must exit 0)
  build_android.sh     the one canonical APK build
  asset_audit.py       GLB / texture / VAT auditor used by the gate
  texture_budget.py    per-category import limits (--apply / --check)
  gen_textures.py      procedural tileable terrain textures
  asset_connectors.py  queued fal.ai pipeline (dry run unless explicitly armed)
  blender/process_assets.py  headless Blender 4.5+ normaliser/baker
```

## Build and verify

Requirements: Godot 4.7.2 with export templates, Android SDK (build-tools +
platform-tools), JDK 17+, Python 3 with numpy and Pillow, and Xvfb (or a display)
with a Vulkan driver for the render smoke test.

```bash
python3 tools/gate_check.py
```

```bash
bash tools/build_android.sh
```

The build creates a release keystore at `~/.shardfall/release.keystore` on first
run (override with `SHARDFALL_KEYSTORE`, `SHARDFALL_KEY_ALIAS` and `SHARDFALL_KEY_PASS`).
Keystores are never written into the repository. Output: `build/ShardFall.apk`.

## Controls

Touch: left-thumb floating (or fixed) joystick; right-thumb ROLL, JUMP, ULT, 1, 2.
Keyboard: WASD/arrows to move, Shift to roll, Space to jump, Q/E for skills, R for
the ultimate, Esc to pause. Gamepads are supported.

## Generated assets (optional, costs money)

```bash
python3 tools/asset_connectors.py --plan --canary
```

This prints the queue and the estimated cost, and spends nothing. A real run needs
`--run-connectors`, `FAL_KEY` set in the environment and a `--cap` in USD. Then
process the results with
`blender -b -P tools/blender/process_assets.py -- --raw tools/asset_raw --out godot/models`
and re-run the gate.
