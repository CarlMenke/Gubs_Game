# Where this is up to

Resume point for GUB. Read this first, then `docs/PLAN.md` (the full task list,
with checkboxes) and `docs/DECISIONS.md` (why things are the way they are).

Last updated: 2026-09-04.

---

## The one-line version

Phases 0 and 2 are **done and visually verified**. Phase 3 (combat) is **written
and compiling but has never been run** — that is the next thing to do. Phases 1,
4 (except sky), 5, 6 and 7 have not been started.

---

## Environment

Godot is not on `PATH`, and note that the `.exe` in this path is a **directory**:

```bash
GODOT="$HOME/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
```

Common commands:

```bash
# Reimport after adding or changing any asset or .import file
"$GODOT" --headless --path . --import

# Play the movement/combat testbed by hand
"$GODOT" --path . tools/sandbox.tscn

# Render any scene to a PNG and quit (needs a real window; one will flash).
# This is how all the visual work so far was checked — use it.
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/sandbox.tscn out.png 90 run

# Rebuild the game-ready meshes from the raw art (safe to re-run; sources are
# never modified). Requires: numpy, scipy, pillow, fast_simplification.
python tools/decimate_assets.py
```

Python is 3.9 via the Windows Store shim. `fast_simplification` needed a
one-line local patch (`from __future__ import annotations` at the top of its
`simplify.py`) to import on 3.9 — if the pipeline is ever run on a fresh
machine, expect to redo that.

### Dev tools in `tools/` (none of these ship)

| file | what it does |
|---|---|
| `snapshot.gd` | render a scene to PNG and quit — the main verification loop |
| `inspect_scene.gd` | dump a scene's node tree, animations, bone list, tri counts |
| `sandbox.tscn` | playable flat testbed; can drive itself (`run`, `crouch`, `throw`, `jump`, `ragdoll`) |
| `preview_assets.tscn` | the four decimated meshes side by side |
| `preview_anim.tscn` | contact sheet of one animation clip |
| `preview_grip.tscn` | close-up of the spear in the hand; grip is tunable from the CLI |
| `preview_ragdoll.tscn` | fixed-camera death, for judging the tumble |
| `preview_sky.tscn` | the sky and environment, horizon and up views |
| `decimate_assets.py`, `gltf_io.py`, `rig_math.py` | the offline art pipeline |

---

## Done

### Phase 0 — foundation ✅
Repo, `project.godot` (input map, physics layers, Forward+ settings), and the
**asset pipeline**, which was much more work than expected and is the thing most
worth understanding before touching art:

- All four supplied meshes were ~500k triangles with 2K textures. They are now
  37k triangles total, 90 MB → 7 MB, with no visible loss. Output lands in
  `art/generated/` and **is committed**, so a fresh clone runs without Python.
- Inspecting `Gub.glb` turned up three latent bugs, all fixed in the pipeline
  rather than worked around downstream. See **D-008** — it is the most important
  entry in the decisions log:
  1. every clip shipped twice (a 2-key held pose plus the real animation);
  2. every clip had its travel baked into the root joint (removed — and the
     extracted speeds became the movement tuning constants);
  3. every clip was authored at a *different resting yaw* (Idle was 65.8° off),
     which would have swung the body sideways on every animation blend.

### Phase 2 — the Gub ✅
`scenes/player/gub.tscn` plus `scripts/player/`. Movement, third-person camera
rig, animation blend tree (built in code, not in the scene), nameplate, and
runtime-generated ragdolls. All verified on screen.

Movement speeds are the clips' own authored speeds × `Gub.SPEED_SCALE` (1.35),
with the locomotion clips played back at that same factor — that is what keeps
the feet planted. **Do not change one without the other.**

### Phase 4.6 / 4.7 — sky and environment ✅
`resources/shaders/enchanted_sky.gdshader`, `resources/config/arena_sky.tres`,
`resources/config/arena_env.tres`. Built by a subagent, rendered and checked.
Its handoff notes for whoever builds the island are in **D-009**, and they
matter — particularly:

- The sky **assumes a `DirectionalLight3D` exists** and draws the moon at its
  direction. Aim it from `(-0.42, 0.38, -0.82)`, colour `(0.62, 0.72, 1.0)`,
  `light_energy = 0.30` (fill only — torches are the key light).
- Torch lights want `light_volumetric_fog_energy ≈ 2.0`.
- Fog is tuned for an island 40–60 m across.
- Keep terrain albedo above about `Color(0.15, 0.18, 0.12)` or it crushes to
  black outside torchlight.
- SDFGI is off on purpose; turning it on means dropping `ambient_light_energy`
  from 2.5 back toward 1.0.

---

## In progress — Phase 3, combat

**Everything below is written and compiles. None of it has been executed once.**
Treat it as a first draft that has never met a running game.

| file | state |
|---|---|
| `scripts/items/spear_projectile.gd` | written, untested |
| `scripts/items/shield_mushroom.gd` + `scenes/items/shield_mushroom.tscn` | written, untested |
| `scripts/items/lure.gd` + `scenes/items/lure.tscn` | written, untested |
| `scripts/player/gub_combat.gd` | written, untested; wired into `gub.tscn` as `Combat` |
| `scripts/game/match_state.gd` | rewritten from a stub into the full match backbone; untested |
| `scripts/items/held_spear.gd` | **verified** — the spear is in the hand and follows it |

### The immediate next step

Get a spear to fly and kill something, in the sandbox, single-player. In order:

1. `tools/sandbox.gd` needs a `spawned_items` group node and needs to put the
   Gub in a state where `GubCombat` will act — currently combat bails out
   because `Net.config` is only meaningful inside a session, and `Net.is_host`
   is false in the sandbox. Either start a one-peer host in the sandbox or give
   `GubCombat` an offline path.
2. Add a `throw` snapshot mode that fires a real spear and check the arc.
3. Then the mushroom (check the collision cylinders line up with the mesh — the
   values in `ShieldMushroom` are guesses, never rendered).
4. Then the lure.

### Known loose ends in that code

- `MatchState._apply_death` has a `var rig := ... if ... else null` line using a
  ternary around a `get_node_or_null` — it parses, but read it again; it is ugly
  and probably wrong when the victim node is gone.
- `SpearProjectile._stick` does `global_position -= _velocity.normalized() * -0.12`
  — the double negative is intentional but reads as a typo. Simplify it.
- `MatchState.note_attack` is never called yet. It exists so a Gub lured off the
  edge credits the kill to the lurer; wire it into the lure.
- Nothing calls `MatchState.register_arena` yet — that is the arena's job, and
  the arena does not exist.
- The mushroom/lure `root_scale` values (1.25 / model-side 0.30) were picked by
  arithmetic, not by looking. Render them.

---

## Not started

- **Phase 1 — networking UI**: `Net` and `InviteCode` are written (and
  `InviteCode` is pure logic, easy to unit-test), but there is no main menu, no
  lobby screen, and no scene flow between them. `scenes/ui/main_menu.tscn` is a
  one-line placeholder.
- **Phase 4 — the island** (4.1–4.5, 4.8–4.10). Nothing exists. This is the
  largest remaining chunk. The plan is a seeded generator (**D-007**) rather
  than a hand-placed scene, with landmarks placed explicitly on top.
  `assets/Stylized_Nature_MegaKitStandard/glTF/` has 68 CC0 models (trees,
  bushes, ferns, grasses, rocks, mushrooms, path stones) already importing.
- **Phase 5 — match rules**: mostly written inside `match_state.gd` already, but
  unexercised.
- **Phase 6 — HUD, scoreboard, kill feed, pause menu, spectator.** Nothing.
- **Phase 7 — export preset, README, smoke test.** Nothing.

---

## Things worth knowing that are not obvious from the code

- **Invite codes encode the host's IP and port** (`XXXXX-XXXXX`, Crockford
  base32). This works on a LAN, over a VPN, or over the internet with one
  forwarded port, with no backend at all. A code that was purely a random key
  would need a relay server to map keys to hosts. `Net` dials an abstract
  `MultiplayerPeer`, so a relay can be added later without game code changing.
  **This is a product decision the user should confirm** — see D-005.
- The character scale (0.35) is baked at **import time**, not applied to the
  model node. A scaled `Skeleton3D` gives Godot scaled rigid bodies and the
  ragdoll capsules stop matching the mesh.
- The Gub mesh is authored facing **+Z**; `gub.tscn` turns the model 180° so
  `body_yaw` means "the way the Gub is looking" in Godot's -Z-forward
  convention.
- Ragdolls are local and cosmetic and deliberately **not replicated** (D-010).
  They are also barely damped on purpose — the first version was damped hard
  enough that corpses stayed standing up.
- `assets/` holds the raw art and is `.gdignore`d under `assets/source/`; Godot
  only imports the MegaKit glTF and `art/generated/`.
- The MegaKit's FBX/OBJ/Unity duplicate folders are on disk but untracked, to
  keep the clone around 185 MB.

---

## Git

Local repo, branch `main`, all work committed. **No remote is configured** —
`gh` is not installed on this machine, so the "make it a public repo" part of
the original request is outstanding. To finish it:

```bash
gh repo create Gubs_Game --public --source=. --remote=origin --push
# or, without gh: create the repo on github.com, then
git remote add origin https://github.com/<you>/Gubs_Game.git && git push -u origin main
```
