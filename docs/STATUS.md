# Where this is up to

Resume point for GUB. Read this first, then `docs/PLAN.md` (the full task list,
with checkboxes) and `docs/DECISIONS.md` (why things are the way they are).

Last updated: 2026-09-05, just after the two parallel branches were merged.

---

## Read this before anything else

**`feat/island` and `feat/ui` are merged into `main`.** Everything
now lives on `main`, which is where it was always meant to live; those branches
only ever existed so two agents could work without fighting over one Godot
import cache.

Both merges were clean. The `docs/DECISIONS.md` conflict the previous hand-off
predicted never happened — neither branch had touched that file, so the entries
are still D-001 … D-016 and nothing needed renumbering.

The game can now be played end to end for the first time: `SceneFlow` points at
`main_menu.tscn`, `lobby.tscn` and `arena.tscn`, and all three exist.

### What was checked after the merge

`bash tools/smoke_test.sh` passes 7 checks. Six of them predate both branches and
touch none of their scenes, so each merged screen was also rendered directly:

| checked | how |
|---|---|
| main menu, lobby (empty and 8/8) | `tools/ui_range.tscn`, modes `menu`, `lobby_full` |
| HUD, kill feed, scoreboard, pause, results | `tools/hud_range.tscn`, modes as named |
| the island, lit, with its props and torches | `tools/preview_island.tscn` |

The arena builds in ~2.1 s: 1399 props (~716k triangles), 8 spawns, 15 torches.

**None of it was a substitute for playing it**, and the two bugs below are the
proof: every screen in that table rendered perfectly while the game itself was
unplayable. Each was rendered in isolation, on a testbed that stands the arena
up directly, and both bugs lived in the wiring between them — which is the one
thing rendering a screen cannot check.

A human still has not played it end to end. `tools/cursor_flow.tscn` now walks
menu → match automatically, but nothing has gone through a lobby with two
clients and out to the results screen.

### Two things the merge left broken, and the fixes

**The arena never instanced the HUD.** `arena.tscn` was a one-node scene and
nothing anywhere added `hud.tscn` to it, so a real match had no crosshair, no
clock, no kill feed, no scoreboard, no pause menu and no results screen — all of
which existed, all of which had been looked at in `tools/hud_range.tscn`, and
none of which a player could reach. `hud.gd`'s own header had documented the
line that was missing since the day it was written. The arena instances it now.

**Entering a match did not capture the mouse.** The menu and the lobby each take
a named cursor hold in `_ready` and neither has anywhere to give it back;
`SceneFlow` only resumed capture when the set of holds emptied, so they piled up
and the match ran with a free cursor. Mouse-look and throwing are both gated on
`SceneFlow.cursor_is_free()`, so this was not a cosmetic bug — the game was
unplayable. A hold is now dropped with the scene that took it.

Neither is a merge conflict. Both are the same shape: two halves that compile,
that were each verified on their own, and that no one had ever asked to work
together. `tools/cursor_flow.tscn` now covers the second one, and it is the only
check in the suite that walks the path a player walks.

### The ambient loops, which had the same shape

The two branches disagreed about where the ambient loops live. `Ambience.LOOPS`
named `res://assets/audio/ambience/forest_night.ogg` and `wind_high.ogg` — files
the island agent expected someone to make — while the audio work on `main` made
them as `res://audio/ambience/ambient_forest.wav` and `ambient_wind.wav`.

`_build_audio` skips a loop it cannot resolve *silently*, by design, so the
island would have shipped with fireflies and torches and no sound at all, and
nothing would have said so. `LOOPS` now names the real files. This is the shape
of bug to look for after a parallel merge: not a conflict, but two halves that
compile fine and quietly agree on nothing.

### What is left

1. **Play it.** Menu → lobby → match → results, with two clients. Nothing has.
2. **6.5, the spectator camera** — the largest single gap. On elimination the
   HUD says so and goes inert; there is no camera to fly.
3. **4.10** — one of the eight spawns lands on the shrine's slope, and no
   traversal pass has been done.
4. **1.8** — `Net` handles host-leaves, client-drops and mid-match join; what
   the UI does in response to each has never been exercised.
5. **6.4** — keybinds have no rebinding UI. Everything else in settings is in.

---

## The state of the game

`main` is green: `bash tools/smoke_test.sh` passes 7 checks.

Phases 0 through 5 are complete, bar one spawn point (4.10) and the UI half of
disconnect handling (1.8). Phase 6 is complete except the spectator camera (6.5)
and keybind rebinding (6.4). Phase 7 needs the export templates and a tag.

### Known issue — the ragdoll can still stretch a limb

The corpse no longer explodes (D-013) and now carries the spear's momentum, but
**at higher impact energies a limb can still stretch into a spike briefly during
the tumble** before the body settles. It always settles: the stability guard
requires a compact, still corpse by tick 150 and that passes.

It is the same mechanism as D-013 — a joint being driven past its limit by a
hard contact — just no longer bad enough to run away. If you pick this up:

- The lever that worked before was **widening the spans** in
  `RagdollBuilder.SEGMENTS`, not tightening them. See the lesson at the end of
  D-013.
- `GubRagdoll.IMPACT_TRANSFER` (0.15) is the other dial. Above ~0.2 the corpse
  arrives at the ground fast enough that contact starts amplifying and it gets
  punted skyward; that was measured, not guessed.
- Reproduce with: `combat_range` in `hit` mode around tick 100, at 1600x900.

---

## Environment

Godot is not on `PATH`, and **the `.exe` in the download path is a directory**,
not the binary — which catches everyone once.

`tools/smoke_test.sh` finds the binary itself — it searches `$GODOT`, then
`PATH`, then Downloads under `$HOME`, `$USERPROFILE` and every Windows user
profile it can see, because `$HOME` is not the Windows profile under every bash
on Windows. It also runs under WSL, where it translates the project path with
`wslpath` first: Git Bash converts POSIX paths on the way into a native binary
and WSL does not, so an untranslated `/mnt/c/...` reaches Godot as a path it
cannot read. For the other commands here, set it yourself:

```bash
GODOT="$HOME/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
```

Use the `_console` binary for anything you want output from; the plain one
detaches from the terminal and prints nowhere.

```bash
# Reimport after adding or changing any asset. A new `class_name` script also
# needs this before anything else can refer to it by name.
"$GODOT" --headless --path . --import

# Everything checkable without a person watching. ~1 minute. Run before committing.
bash tools/smoke_test.sh

# Render any scene to a PNG and quit. The number is PHYSICS TICKS (D-012).
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png 70 hit

# Rebuild generated art / audio. Both outputs are committed, so this is only
# needed when a source changes. Safe to re-run; sources are never modified.
python tools/decimate_assets.py     # numpy, scipy, pillow, fast_simplification
python tools/make_sfx.py            # numpy
```

Python is 3.9 via the Windows Store shim. `fast_simplification` needed a
one-line local patch (`from __future__ import annotations` at the top of its
`simplify.py`) to import on 3.9 — expect to redo that on a fresh machine.

### Two traps that have each cost an hour

- **A `--script` main loop is compiled before the autoloads are registered**, so
  it cannot so much as name `MatchState` or `Net` without failing to parse — and
  any script it statically references inherits that failure, silently loading
  the scene *without its script attached*. That is why `match_rules` and
  `invite_codes` are scenes. See D-015.
- **Godot's user data is keyed on project name, not path**, so every checkout of
  this project on one machine shares `settings.cfg`. A name typed into the menu
  in one worktree changed what another worktree's testbed printed, and broke a
  smoke-test grep.

### Dev tools in `tools/` (none of these ship)

| file | what it does |
|---|---|
| `smoke_test.sh` | **the gate** — import, two harnesses, three combat modes |
| `snapshot.gd` | render a scene to PNG and quit — the main visual loop |
| `combat_range.tscn` | **the combat testbed**: a real match, one player, dummies |
| `match_rules.tscn` | 60 assertions across 9 scoring scenarios, headless |
| `invite_codes.tscn` | 2619 assertions over 1296 endpoints, headless |
| `ragdoll_stability.tscn` | throws a corpse with a real spear, requires it to settle |
| `cursor_flow.tscn` | menu → match through the real `SceneFlow`; asserts the mouse is captured |
| `sandbox.tscn` | playable flat testbed for movement |
| `inspect_scene.gd` | dump a scene's node tree, animations, bones, tri counts |
| `preview_assets/anim/grip/ragdoll/sky` | look at one thing in isolation |
| `decimate_assets.py`, `make_sfx.py`, `gltf_io.py`, `rig_math.py` | offline pipelines |

### The combat range

Runs the **real match path** — an offline session on `Net`, a roster,
`MatchState.register_arena`, kills through `MatchState.report_kill`. It reaches
past no private API, so a throw that works there works in a match (D-011).

```bash
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png <ticks> <mode> [trace|pov]
```

| mode | ticks | shows |
|---|---|---|
| `flight` | 33 | the spear in mid-air with its trail |
| `hit` | 70 | the corpse, thrown, spear still through it |
| `arc` | 55 | a long throw, to judge drop |
| `miss` | 60 | a spear stuck in the dirt |
| `mushroom` | 40 | one planted, to check size and placement |
| `lure` | 132 | a lure lobbed at a dummy, held through the pull |
| `lure_self` | 62 | a lure at your own feet — the only way to *see* the pull |
| `free` | — | play it yourself |

**The `lure` mode reports dummies as caught and they will not move.** That is
correct: the pull is applied on each victim's own client because movement is
client-authoritative, and the dummies are fake roster entries with no client
behind them. `lure_self` is the mode that shows the pull working.

---

## What is done

### Phase 0 — foundation ✅
Repo, `project.godot`, asset pipeline. Four ~500k-triangle sources become 37k
triangles total, 90 MB → 7 MB, committed so a fresh clone runs without Python.
**D-008** is still the most important entry in the decisions log.

### Phase 1 — networking ✅ *backend only*
`Net` and `InviteCode` are complete, and `InviteCode` is thoroughly tested.
**No menu, lobby or scene flow yet** — that is `feat/ui`.

### Phase 2 — the Gub ✅
Movement, camera, animation blending, nameplate, network sync, ragdoll.
Movement speeds are the clips' own authored speeds × `Gub.SPEED_SCALE` (1.35),
with the locomotion clips played back at that same factor — that is what keeps
the feet planted. **Do not change one without the other.**

The Gub mesh was replaced this session and it is a clean swap: same 29 joints in
the same order, byte-identical inverse bind matrices, the same eight clips at
the same durations. Re-running the pipeline reproduced every number the old
source produced, so the tuning above still holds. Verified on screen: mesh,
clips, ragdoll, and the spear grip.

### Phase 3 — combat ✅ *except the kill feed*
Throw, arcing flight, trail, hit resolution, the kill, spear regeneration, the
mushroom and the lure — all written, run and looked at. A spear stays in the
body it killed and rides the corpse, and the corpse is thrown by the momentum of
the blow. Sounds, hitmarker and camera shake are in. The kill feed is 6.3 and
belongs to `feat/ui`.

### Phase 4.6 / 4.7 — sky and environment ✅
Handoff notes for the island are in **D-009** and they matter — particularly
that the sky **assumes a `DirectionalLight3D` exists** and draws the moon at its
direction.

### Phase 5 — match rules ✅ *rules only*
Proven by `tools/match_rules.tscn`: kill limit, teams, friendly fire both ways,
team totals, lives and elimination, the clock, void deaths with lure credit,
spawn protection, and `MatchConfig.apply_dict` against hostile input. **5.5's
results screen is UI** and belongs to `feat/ui`.

### Phase 7 — ship ⚠️
Export preset, smoke test and README done. **The export needs the 4.7.2 export
templates installed** (a one-time ~1 GB download via *Editor → Manage Export
Templates*), which this machine does not have — **no binary has ever been
produced**. 7.4 is a final pass and a tag, after the merges.

---

## What is left, in order

1. **Land the two branches** (see the top of this file).
2. **Play it end to end.** Menu → lobby → arena → results has never once been
   done, because until the merges neither end of it exists.
3. **A second machine.** Everything networked has only ever run through
   `Net.start_offline()` (D-011), which is a real session with no socket. The
   RPC paths are *code*-tested and have never sent a packet. Two clients on one
   LAN is the first real test of invite codes, roster sync, disconnect handling,
   and the client-authoritative lure pull.
4. **Install export templates and produce a build.**
5. The ragdoll limb-stretch above, if it bothers you in motion.
6. Phase 4.9 ambient audio — the *assets* exist (`AudioDirector.AMBIENT_WIND`,
   `AMBIENT_FOREST`, seamless loops) but may still need wiring in the arena.

---

## Things worth knowing that are not obvious from the code

- **Invite codes encode the host's IP and port** (`XXXXX-XXXXX`, Crockford
  base32). Works on a LAN, over a VPN, or over the internet with one forwarded
  port (**UDP 27015**), with no backend at all. **This is a product decision the
  user should confirm** — see D-005.
- **When in doubt, open a ragdoll joint up.** A cone-twist driven past its limit
  adds energy rather than clamping. Too floppy looks rubbery; too tight
  explodes. See D-013.
- `LURE_GRAVITY` in `gub_combat.gd` must equal `Lure.GRAVITY`. The arc is solved
  in one file and flown in the other; if they disagree the lure misses where it
  was aimed. See D-014.
- The character scale (0.35) is baked at **import time**, not applied to the
  model node. A scaled `Skeleton3D` gives Godot scaled rigid bodies and the
  ragdoll capsules stop matching the mesh.
- The Gub mesh is authored facing **+Z**; `gub.tscn` turns the model 180° so
  `body_yaw` means "the way the Gub is looking" in Godot's -Z-forward convention.
- Ragdolls are local and cosmetic and deliberately **not replicated** (D-010).
- `GubCamera.look_at_point` solves from the *camera's* position, not the rig's,
  because the camera sits a shoulder-width off the rig axis.
- Sound placement encodes a rule: **3D means an event in the world that gives
  your position away; 2D means feedback only you could have.** See D-016.
- `assets/` holds the raw art and is `.gdignore`d under `assets/source/`; Godot
  only imports the MegaKit glTF and `art/generated/`.

---

## Git

`main` is pushed to **https://github.com/CarlMenke/Gubs_Game** (public) and is
the only branch that matters — `feat/island` and `feat/ui` have both been merged
into it. Delete them, and their worktrees, once you are satisfied with the
merge; nothing on `main` needs them.

The repo belongs to CarlMenke; JulianC775 is a collaborator with push rights, so
plain `git push` works from this machine. If it ever 403s, check that first:

```bash
gh api repos/CarlMenke/Gubs_Game --jq '.permissions'
```

`gh` is installed at `/c/Program Files/GitHub CLI/gh`, authenticated as
JulianC775 with `repo`, `read:org` and `gist` scopes.
