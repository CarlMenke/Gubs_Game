# GUB

A match-based third-person multiplayer game in Godot 4.7.2. You are a Gub — a
small yellow alien — fighting on a floating enchanted-forest island with thrown
spears that kill in one hit.

Spears are the whole fight. One lands, you die, and the thrower's hand is empty
until it grows back, so an empty hand is the most useful thing on screen: it
tells everyone in sight that the Gub holding it is harmless for the next few
seconds. Two abilities exist to bend that around: a **mushroom** planted as cover
you cannot be hit through, and a **lure** lobbed past it that drags everyone
nearby out into the open for about a second.

---

## Running it

You need [Godot 4.7.2 stable](https://godotengine.org/download) — the standard
build, not .NET. Nothing else: the decimated meshes and the sound effects are
committed, so a fresh clone runs without Python.

```bash
git clone https://github.com/CarlMenke/Gubs_Game
cd Gubs_Game
godot --path .            # or open project.godot in the editor
```

On this machine Godot is not on `PATH`, and **the `.exe` in the download path is
a directory**, which catches everyone once:

```bash
GODOT="$HOME/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
```

Use the `_console` binary for anything you want output from — the plain one
detaches from the terminal and prints nowhere.

### Controls

| | |
|---|---|
| move / sprint / crouch | `WASD`, `Shift`, `Ctrl` or `C` |
| jump, slide | `Space`, crouch while sprinting |
| throw spear | left mouse |
| aim (zooms in) | right mouse |
| mushroom, lure | `Q`, `E` |
| scoreboard, pause, chat | `Tab`, `Esc`, `T` |

---

## Playing together

The host clicks **Host** and gets a ten-character **invite code** like
`K3M9P-2XQ7R`. Anyone else picks **Join**, types it in, and is in the lobby.

That code *is* the host's address — the IP and port, Crockford base32, no
backend anywhere. This is what makes it work on a LAN, over a VPN, or across the
internet with a single forwarded port (**UDP 27015**), with nothing to run and
no account to make. It is also the trade-off: a purely random key would hide the
host's IP, but would need a relay server to turn keys back into addresses. See
**D-005** — this is a product decision worth revisiting, not a settled one.

One player hosts and plays at the same time, and the host is authoritative: it
owns every kill, score and respawn. Movement is client-authoritative so your own
Gub never feels laggy. Up to 8 players.

---

## Building a release

```bash
"$GODOT" --headless --path . --export-release "Windows Desktop" build/windows/GUB.exe
```

The preset is committed as `export_presets.cfg` (deliberately — it holds no
credentials, and it is the only record of what a shipped build leaves out).

You need the **4.7.2 export templates** installed first, which is a one-time
~1 GB download: in the editor, *Editor → Manage Export Templates → Download*.
Without them the export fails with `No export template found at the expected
path`, which is the only thing standing between this command and a binary.

---

## Working on it

Read these in order:

| | |
|---|---|
| `docs/STATUS.md` | **start here** — where things are and what to do next |
| `docs/PLAN.md` | the full scope, tracked to completion |
| `docs/DECISIONS.md` | why anything non-obvious is the way it is |

### Checking your work

```bash
bash tools/smoke_test.sh
```

Everything that can be checked without a person watching: the headless import,
the match rules, a ragdoll that has to survive hitting the ground, and the three
combat modes that report what they did. Run it before committing anything that
touches gameplay.

It fails on any `SCRIPT ERROR` as well as on a bad exit code, because Godot
prints one and carries straight on — a clean exit proves nothing by itself.

What it **cannot** do is tell you whether anything looks right. That needs eyes,
and `tools/` is full of scenes for it:

```bash
# Render any scene to a PNG and quit. The number is PHYSICS TICKS (D-012).
"$GODOT" --path . --resolution 1280x720 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn out.png 62 hit
```

| tool | what it is for |
|---|---|
| `combat_range.tscn` | **the combat testbed** — a real match, one player, dummies |
| `sandbox.tscn` | flat playground for movement |
| `preview_assets`, `preview_anim`, `preview_grip` | the art, the clips, the spear in the hand |
| `preview_ragdoll`, `ragdoll_stability` | how a corpse falls, and whether it survives |
| `preview_sky` | the sky and environment |
| `match_rules.tscn` | 42 assertions across 8 scoring scenarios, headless |
| `inspect_scene.gd` | dump a scene's tree, clips, bones and triangle counts |

`combat_range` runs the **real match path** — an offline session on `Net`, a
roster, `MatchState.register_arena`, kills through `MatchState.report_kill` — so
a throw that works there works in a match. Pass a mode as the fourth argument
(`flight`, `hit`, `arc`, `miss`, `mushroom`, `lure`, `lure_self`, `free`) and
`trace` as a fifth to print the whole flight, which is the only way to tell a
miss from a hit whose kill was dropped.

### Regenerating the art and audio

Both are committed, so you only need this if you change a source file:

```bash
python tools/decimate_assets.py     # needs numpy, scipy, pillow, fast_simplification
python tools/make_sfx.py            # needs numpy
```

The meshes arrive at ~500k triangles each and leave at 37k total, 90 MB → 7 MB,
with UVs and skin weights transferred back seam-aware. Sources in `assets/` are
never modified; re-running either script is always safe.

---

## Layout

```
art/generated/   game-ready meshes and textures — committed, no Python needed
assets/          raw source art (.gdignore'd; only the MegaKit is imported)
audio/sfx/       synthesised sound effects — committed, see tools/make_sfx.py
docs/            STATUS, PLAN, DECISIONS
resources/       shaders, environment, bus layout
scenes/          player, items, ui, world
scripts/         game, items, net, player, ui, util, world
tools/           dev tools and testbeds — none of this ships
```

Autoloads: `Settings`, `Net`, `MatchState`, `SceneFlow`, `AudioDirector`.

---

## Credits and licence

Environment art is the **Stylized Nature MegaKit** (CC0). The Gub, spear, lure
and mushroom are project assets. Sound effects are synthesised from scratch by
`tools/make_sfx.py`.
