# Where this is up to

Resume point for GUB. Read this first, then `docs/PLAN.md` (the full task list,
with checkboxes) and `docs/DECISIONS.md` (why things are the way they are).

Last updated: 2026-09-04.

---

## The one-line version

**A spear now flies, hits and kills, in a running game.** That was the whole job
for this session and it is done and on screen. Getting there turned up three
bugs that had been sitting in already-"finished" code, one of which — the
ragdoll — means Phase 2 is no longer complete. **Read "Ragdolls are broken"
below before anything else.**

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

# Play the combat testbed by hand
"$GODOT" --path . tools/combat_range.tscn

# Render any scene to a PNG and quit (needs a real window; one will flash).
# The number is now PHYSICS TICKS, not draw calls — see D-012.
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png 62 hit

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
| `combat_range.tscn` | **the combat testbed**: a real match, one player, dummies |
| `sandbox.tscn` | playable flat testbed for movement (`run`, `crouch`, `jump`, …) |
| `inspect_scene.gd` | dump a scene's node tree, animations, bone list, tri counts |
| `preview_assets.tscn` | the four decimated meshes side by side |
| `preview_anim.tscn` | contact sheet of one animation clip |
| `preview_grip.tscn` | close-up of the spear in the hand; grip is tunable from the CLI |
| `preview_ragdoll.tscn` | fixed-camera death, for judging the tumble |
| `preview_sky.tscn` | the sky and environment, horizon and up views |
| `decimate_assets.py`, `gltf_io.py`, `rig_math.py` | the offline art pipeline |

### The combat range

`tools/combat_range.tscn` runs the **real match path** — an offline session on
`Net`, a roster, `MatchState.register_arena`, Gubs spawned by `MatchState`, kills
through `MatchState.report_kill`. It reaches past no private API, so a throw that
works there works in a match. See **D-011**.

```bash
# mode is the 4th argument; a 5th of `trace` prints the flight, `pov` uses the
# thrower's own camera instead of the touchline one.
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png <ticks> <mode> [trace|pov]
```

| mode | ticks | what it shows |
|---|---|---|
| `flight` | 33 | the spear in mid-air, side-on |
| `hit` | 62 | the corpse, just after the kill |
| `arc` | 55 | a long throw, to judge drop |
| `miss` | 60 | a spear stuck in the dirt |
| `mushroom` | — | **not yet run** |
| `lure` | — | **not yet run** |
| `free` | — | play it yourself |

The scripted modes throw on physics tick 20 and the spear reaches the first
dummy on tick 40. `trace` prints the whole parabola plus what it struck, which is
the only way to tell "it missed" from "it hit and the kill was dropped".

---

## Ragdolls are broken — read this first

`preview_ragdoll.tscn` at 26 ticks looks right. At 34 an arm has stretched into a
spike. By 60 the corpse is a scribble of metre-long sticks. This is not new
breakage: it has always been there, and it was certified as working because the
old snapshot tool counted draw calls instead of physics ticks and was sampling
about 0.2 s after death (D-012). Every corpse in the game does this half a second
in.

What has been ruled out or fixed so far:

- **Fixed, but not the cause.** `RagdollBuilder._basis_along` built a
  *left-handed* basis (`up.cross(right)` where it wanted `right.cross(up)`), so
  every body transform and every joint frame was a reflection. Genuinely wrong,
  now correct, and the explosion still happens.
- The impulse is not absurd: ~3.2 m/s on every body, ~8.8 on the struck one.
- Nothing re-drives the bodies per frame; `GubRagdoll._process` only fades.

The next thing to try, in order:

1. Determine whether the **rigid bodies** are separating or only the **skin** is
   — i.e. is this a joint failing, or is `body_offset` wrong so that the
   recovered bone poses are garbage? Print the world distance between the `spine`
   and `forearm.R` bodies, and the distance between the same two *bones*
   (`Skeleton3D.get_bone_global_pose`), every 10 ticks. If the bodies stay
   together and the bones fly apart, it is the `body_offset` maths in
   `RagdollBuilder._make_bone`, not the physics.
2. If it is the joints: the cone-twist's twist axis is the joint frame's local
   **X**, but `joint_offset` is left with an identity basis while the bones run
   along the body's local **+Y**. So every joint's cone opens perpendicular to
   the limb it is meant to constrain, and starts 90° outside its own limit. Try
   `joint_offset.basis = Basis(Vector3(0, 0, 1), PI / 2)` (maps local X onto
   local Y) and see whether the explosion stops.
3. If it is neither, back off the slack joints — `softness 0.92`,
   `relaxation 0.6` — which were tuned for floppiness (D-010) and are the other
   candidate for a solver that never converges.

---

## Done and verified on screen

### Phase 0 — foundation ✅
Repo, `project.godot`, and the **asset pipeline**. All four supplied meshes were
~500k triangles with 2K textures; they are now 37k triangles total, 90 MB → 7 MB.
Output lands in `art/generated/` and **is committed**, so a fresh clone runs
without Python. Inspecting `Gub.glb` turned up three latent bugs, all fixed in
the pipeline rather than worked around downstream — see **D-008**, still the most
important entry in the decisions log.

### Phase 2 — the Gub ✅ *except 2.7*
Movement, camera rig, animation blending, nameplate. Movement speeds are the
clips' own authored speeds × `Gub.SPEED_SCALE` (1.35), with the locomotion clips
played back at that same factor — that is what keeps the feet planted. **Do not
change one without the other.** Ragdolls (2.7) are unticked; see above.

### Phase 3 — combat, the spear half ✅
Throw, flight, hit resolution and the kill are **written, run and looked at**.
`tools/combat_range.tscn` in `hit` mode prints
`combat_range: Gub killed Dummy 1 (cause 0) at frame 40` and the corpse appears.
Spear regeneration works: the hand empties on release and refills on the
cooldown, which is the read other players have on whether you are dangerous.

Still open in Phase 3: the trail (3.2a); the spear should **stick in the corpse**
rather than being freed on a body hit (3.3a); and the mushroom and lure below.

### Phase 4.6 / 4.7 — sky and environment ✅
`resources/shaders/enchanted_sky.gdshader`, `arena_sky.tres`, `arena_env.tres`.
Handoff notes for whoever builds the island are in **D-009**, and they matter —
particularly that the sky **assumes a `DirectionalLight3D` exists** and draws the
moon at its direction: aim it from `(-0.42, 0.38, -0.82)`, colour
`(0.62, 0.72, 1.0)`, `light_energy = 0.30` (fill only — torches are the key
light). Torch lights want `light_volumetric_fog_energy ≈ 2.0`. Fog is tuned for
an island 40–60 m across. Keep terrain albedo above about
`Color(0.15, 0.18, 0.12)`. SDFGI is off on purpose.

---

## Bugs this session found in code that was already "done"

Worth reading, because all three were invisible until something actually ran:

1. **Every client would have played out of the wrong Gub's eyes.**
   `MatchState._create_gub` set multiplayer authority *after* `add_child`, so
   during each Gub's `_ready` every Gub believed it was local — and each remote
   Gub's `GubCamera` made its own camera current. The last one spawned won the
   viewport. Authority is now set before the node enters the tree.
2. **Remote Gubs were permanently airborne.** `GubAnimator` read
   `is_on_floor()`, which is meaningless on a body whose `move_and_slide` never
   runs, so every other player's Gub played the Jump clip forever. `sync_grounded`
   and `sync_sliding` existed for exactly this and were not being read; `Gub` now
   has `is_grounded()`, and `is_sliding()` falls back to the replicated flag.
3. **Every spawn slid in from the arena origin.** `_create_gub` assigned the
   transform without seeding the replicated fields, so on every other peer a new
   Gub started at `sync_position == (0,0,0)`. It now calls `revive_at`, which
   publishes.

Plus the ragdoll basis handedness above, and the snapshot clock (D-012) that had
been quietly certifying things too early.

---

## In progress — Phase 3, the mushroom and the lure

Both are **written, compiling, and still never executed**. `combat_range` has
`mushroom` and `lure` modes wired and framed, but neither has been run once. That
is the next job and it should be quick:

```bash
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png 40 mushroom
```

Known loose ends in that code:

- The mushroom's collision cylinders (`STEM_RADIUS` 0.22, `CAP_RADIUS` 0.82,
  `CAP_CENTRE_Y` 1.72) and the mushroom/lure scales (1.25 / model-side 0.30) were
  picked by arithmetic and have never been rendered. They are probably wrong.
- `MatchState.note_attack` is still never called. It exists so a Gub lured off
  the edge credits the kill to the lurer — wire it into `Lure._catch`, which is
  already host-only and already has the victim and the thrower to hand.
- `MatchConfig.lure_fuse` defaults to 0.35 but its `@export_range` starts at 0.5,
  so `_clamp_all` silently raises it. Pick one.

---

## Not started

- **Phase 1 — networking UI**: `Net` and `InviteCode` are written (and
  `InviteCode` is pure logic, easy to unit-test), but there is no main menu, no
  lobby screen, and no scene flow between them. `scenes/ui/main_menu.tscn` is a
  one-line placeholder.
- **Phase 4 — the island** (4.1–4.5, 4.8–4.10). Nothing exists. This is the
  largest remaining chunk. The plan is a seeded generator (**D-007**) rather
  than a hand-placed scene, with landmarks placed explicitly on top.
  `assets/Stylized_Nature_MegaKitStandard/glTF/` has 68 CC0 models already
  importing. When it exists, it is the thing that must call
  `MatchState.register_arena(players_root, spawn_points)` — `combat_range` is
  the only caller today, so that API is at least proven.
- **Phase 5 — match rules**: the backbone in `match_state.gd` now runs (phases,
  spawns, kills, scores), but only in free-for-all with one live player. Teams,
  lives, the clock and the results screen are unexercised.
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
- `GubCamera.look_at_point` solves from the *camera's* position, not the rig's,
  because the camera sits a shoulder-width off the rig axis. Aiming the rig at a
  target misses it by that offset at every distance.
- `assets/` holds the raw art and is `.gdignore`d under `assets/source/`; Godot
  only imports the MegaKit glTF and `art/generated/`.

---

## Git

Branch `main`, pushed to **https://github.com/CarlMenke/Gubs_Game** (public).

The repo belongs to CarlMenke; JulianC775 is a collaborator with push rights, so
plain `git push` works from this machine. If it ever 403s again, that access is
the first thing to check:

```bash
gh api repos/CarlMenke/Gubs_Game --jq '.permissions'
```

`gh` is installed at `/c/Program Files/GitHub CLI/gh`, authenticated as
JulianC775 with `repo`, `read:org` and `gist` scopes. (An earlier version of this
document claimed it was not installed. It is.)
