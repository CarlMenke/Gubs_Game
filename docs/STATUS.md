# Where this is up to

Resume point for GUB. Read this first, then `docs/PLAN.md` (the full task list,
with checkboxes) and `docs/DECISIONS.md` (why things are the way they are).

Last updated: 2026-09-04.

---

## The one-line version

**The ragdoll is fixed, the mushroom and lure have finally been run, and the
match rules are under test.** Phase 2 is complete again, Phase 3 is complete
except for kill-feed UI, and Phase 5's scoring is proven by 60 assertions. Two
branches are in flight building the two things the game still visibly lacks: the
island and the UI.

---

## In flight — do not duplicate this work

| branch | what it is building |
|---|---|
| `feat/island` | Phase 4 — the island, scatter, landmarks, torches, ambience, and **`scenes/world/arena.tscn`** |
| `feat/ui` | Phases 1.3–1.8 and 6 — menu, lobby, HUD, scoreboard, kill feed, pause, results |

Both are pushed. They are the two things `SceneFlow` already points at and that
do not exist on `main`: `SceneFlow.ARENA` is `res://scenes/world/arena.tscn` and
`SceneFlow.LOBBY` is `res://scenes/ui/lobby.tscn`. Until those land, the game
cannot be played end to end from the main menu — use the testbeds below.

Both branches append to `docs/DECISIONS.md`, so expect an append-only conflict
at merge and renumber the `D-0NN` entries rather than dropping any.

---

## Environment

Godot is not on `PATH`, and note that the `.exe` in this path is a **directory**:

```bash
GODOT="$HOME/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
```

Use the `_console` binary for anything you want output from; the plain one
detaches from the terminal and prints nowhere.

```bash
# Reimport after adding or changing any asset. A new `class_name` script also
# needs this before anything can refer to it by name.
"$GODOT" --headless --path . --import

# Everything that can be checked without a person watching. ~1 minute.
bash tools/smoke_test.sh

# Render any scene to a PNG and quit. The number is PHYSICS TICKS (D-012).
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png 62 hit

# Rebuild generated art / audio from source. Both outputs are committed, so this
# is only needed when a source file changes. Safe to re-run; sources are never
# modified.
python tools/decimate_assets.py     # numpy, scipy, pillow, fast_simplification
python tools/make_sfx.py            # numpy
```

Python is 3.9 via the Windows Store shim. `fast_simplification` needed a
one-line local patch (`from __future__ import annotations` at the top of its
`simplify.py`) to import on 3.9 — expect to redo that on a fresh machine.

### A trap worth knowing before writing a dev tool

A `--script` main loop is compiled **before the autoloads are registered**, so it
cannot so much as name `MatchState` or `Net` without failing to parse — and any
script it statically references inherits that failure, silently instantiating
the scene *without its script attached*. That is why `match_rules` and
`invite_codes` are scenes, and why `snapshot.gd` only ever loads scenes by path.
An hour was lost to this diagnosing a "bug" in the lure that was the probe's
fault. See D-015.

### Dev tools in `tools/` (none of these ship)

| file | what it does |
|---|---|
| `smoke_test.sh` | **the gate** — import, both harnesses, three combat modes |
| `snapshot.gd` | render a scene to PNG and quit — the main visual loop |
| `combat_range.tscn` | **the combat testbed**: a real match, one player, dummies |
| `match_rules.tscn` | 60 assertions across 9 scoring scenarios, headless |
| `invite_codes.tscn` | 2619 assertions over 1296 endpoints, headless |
| `ragdoll_stability.tscn` | drops a corpse and asserts it is still a corpse |
| `sandbox.tscn` | playable flat testbed for movement |
| `inspect_scene.gd` | dump a scene's node tree, animations, bones, tri counts |
| `preview_assets/anim/grip/ragdoll/sky` | look at one thing in isolation |
| `decimate_assets.py`, `make_sfx.py`, `gltf_io.py`, `rig_math.py` | the offline pipelines |

### The combat range

`tools/combat_range.tscn` runs the **real match path** — an offline session on
`Net`, a roster, `MatchState.register_arena`, Gubs spawned by `MatchState`, kills
through `MatchState.report_kill`. It reaches past no private API, so a throw that
works there works in a match. See **D-011**.

```bash
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png <ticks> <mode> [trace|pov]
```

| mode | ticks | what it shows |
|---|---|---|
| `flight` | 33 | the spear in mid-air, side-on, with its trail |
| `hit` | 70 | the corpse, spear still through it |
| `arc` | 55 | a long throw, to judge drop |
| `miss` | 60 | a spear stuck in the dirt |
| `mushroom` | 40 | one planted, to check size and placement |
| `lure` | 132 | a lure lobbed at a dummy, held through the pull |
| `lure_self` | 62 | a lure at your own feet — the only way to *see* the pull |
| `free` | — | play it yourself |

`trace` prints the whole parabola plus what it struck, which is the only way to
tell "it missed" from "it hit and the kill was dropped".

**The `lure` mode reports dummies as caught and they will not move.** That is
correct: the pull is applied on each victim's own client because movement is
client-authoritative, and the dummies are fake roster entries with no client
behind them. `lure_self` is the mode that shows the pull actually working.

---

## Done and verified on screen

### Phase 0 — foundation ✅
Repo, `project.godot`, and the **asset pipeline**. Four ~500k-triangle source
meshes become 37k triangles total, 90 MB → 7 MB. Output lands in
`art/generated/` and **is committed**, so a fresh clone runs without Python.
**D-008** is still the most important entry in the decisions log.

### Phase 1 — networking ⚠️ *backend only*
`Net` and `InviteCode` are complete and `InviteCode` is now thoroughly tested
(2619 assertions). **There is still no menu, lobby or scene flow** — that is
`feat/ui`.

### Phase 2 — the Gub ✅
Movement, camera rig, animation blending, nameplate, network sync, **and the
ragdoll (2.7), which is fixed**. Movement speeds are the clips' own authored
speeds × `Gub.SPEED_SCALE` (1.35), with the locomotion clips played back at that
same factor — that is what keeps the feet planted. **Do not change one without
the other.**

The Gub mesh was replaced with a remodelled one and it is a clean swap: same 29
joints in the same order, byte-identical inverse bind matrices, the same eight
clips. Re-running the pipeline reproduced every number the old source produced,
so the movement tuning above still holds.

### Phase 3 — combat ✅ *except the kill feed*
Throw, flight, hit resolution, the kill, the trail, spear regeneration, the
mushroom and the lure are all **written, run and looked at**. A spear now stays
in the body it killed and rides the corpse. 3.8's sounds, hitmarker and camera
shake are in; the kill feed is 6.3 and belongs to `feat/ui`.

### Phase 4.6 / 4.7 — sky and environment ✅
Handoff notes for whoever builds the island are in **D-009** and they matter —
particularly that the sky **assumes a `DirectionalLight3D` exists** and draws the
moon at its direction.

### Phase 5 — match rules ✅ *rules only*
The scoring backbone is proven by `tools/match_rules.tscn`: kill limit, teams,
friendly fire both ways, team totals, lives and elimination, the clock, void
deaths with lure credit, spawn protection, and `MatchConfig.apply_dict` against
hostile input. **5.5's results screen is UI** and belongs to `feat/ui`.

### Phase 7 — ship ⚠️
Export preset, smoke test and README are done. **The export itself needs the
4.7.2 export templates installed** (a one-time ~1 GB download via *Editor →
Manage Export Templates*), which this machine does not have — so no binary has
ever actually been produced. 7.4 is a final pass and a tag, after the merges.

---

## What is left

1. **Merge `feat/island` and `feat/ui`**, resolving the `DECISIONS.md` append
   conflict by renumbering rather than dropping entries.
2. **Play it end to end**: menu → lobby → arena → results. Nothing has ever done
   this, because until the merges neither end of it exists.
3. **A second machine.** Everything networked has been exercised through
   `Net.start_offline()` (D-011), which is a real session with no socket. The
   RPC paths are therefore *code*-tested but never *wire*-tested: nothing has
   ever actually sent a packet. Two clients on one LAN is the first real test of
   invite codes, roster sync, and the client-authoritative pull.
4. **Install export templates and produce a build.**
5. Phase 4.9 ambient audio, if `feat/island` left it as a stub.

---

## Things worth knowing that are not obvious from the code

- **Invite codes encode the host's IP and port** (`XXXXX-XXXXX`, Crockford
  base32). This works on a LAN, over a VPN, or over the internet with one
  forwarded port (**UDP 27015**), with no backend at all. **This is a product
  decision the user should confirm** — see D-005.
- **When in doubt, open a ragdoll joint up.** A cone-twist driven past its limit
  adds energy rather than clamping. Too-floppy looks rubbery; too-tight
  explodes. See D-013.
- `LURE_GRAVITY` in `gub_combat.gd` must equal `Lure.GRAVITY`. The arc is solved
  in one file and flown in the other; if they disagree the lure misses where it
  was aimed. See D-014.
- The character scale (0.35) is baked at **import time**, not applied to the
  model node. A scaled `Skeleton3D` gives Godot scaled rigid bodies and the
  ragdoll capsules stop matching the mesh.
- The Gub mesh is authored facing **+Z**; `gub.tscn` turns the model 180° so
  `body_yaw` means "the way the Gub is looking" in Godot's -Z-forward
  convention.
- Ragdolls are local and cosmetic and deliberately **not replicated** (D-010).
- `GubCamera.look_at_point` solves from the *camera's* position, not the rig's,
  because the camera sits a shoulder-width off the rig axis.
- Sound placement encodes a rule: **3D means an event in the world that gives
  your position away; 2D means feedback only you could have.** See D-016.
- `assets/` holds the raw art and is `.gdignore`d under `assets/source/`; Godot
  only imports the MegaKit glTF and `art/generated/`.

---

## Git

Branch `main`, pushed to **https://github.com/CarlMenke/Gubs_Game** (public),
along with `feat/island` and `feat/ui`.

The repo belongs to CarlMenke; JulianC775 is a collaborator with push rights, so
plain `git push` works from this machine. If it ever 403s, check that first:

```bash
gh api repos/CarlMenke/Gubs_Game --jq '.permissions'
```

`gh` is installed at `/c/Program Files/GitHub CLI/gh`, authenticated as
JulianC775 with `repo`, `read:org` and `gist` scopes.
