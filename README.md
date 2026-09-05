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

**It has to be 4.7.** Godot 4.6 does not politely refuse this project — it fails
to parse it, with a wall of `Too many arguments for "add_blend_point()"` that
reads exactly like a bug in this repository and is not one. That method gained a
fourth argument in 4.7. The scripts below reject a 4.6 binary rather than running
it, but if you are invoking Godot by hand, check `--version` first.

On Windows, `run.bat` does the same thing without you typing the path to Godot:

```
run.bat
```

`tools/smoke_test.sh` finds the binary itself — it searches `$GODOT`, then
`PATH`, then `/Applications` and Downloads under `$HOME`, `$USERPROFILE` and
every Windows user profile it can see, because `$HOME` is not the Windows
profile under every bash on Windows. It also runs under WSL, where it translates
the project path with `wslpath` first: Git Bash converts POSIX paths on the way
into a native binary and WSL does not, so an untranslated `/mnt/c/...` reaches
Godot as a path it cannot read.

For the other commands here, set it yourself. Godot is on `PATH` on none of the
machines this is developed on, and note that **the `.exe` in the Windows download
path is a directory**, not the binary — which catches everyone once:

```bash
# macOS — note that /Applications/Godot.app may well be an older one
GODOT="$HOME/Downloads/Godot_v4.7.2-stable_macos/Godot.app/Contents/MacOS/Godot"

# Windows — the `.exe` in this path is a DIRECTORY, which catches everyone once
GODOT="$HOME/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
```

On Windows use the `_console` binary for anything you want output from — the
plain one detaches from the terminal and prints nowhere.

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

Both presets are committed. Windows is the one the game is played on; macOS is
universal, so it runs natively on Apple Silicon and on Intel.

```bash
"$GODOT" --headless --path . --export-release "Windows Desktop" "$PWD/build/windows/GUB.exe"
"$GODOT" --headless --path . --export-release "macOS"           "$PWD/build/macos/GUB.app"
```

Pass an **absolute** output path. A relative one is resolved against the project,
not against your shell, which is a confusing way to lose a build.

You need the **4.7.2 export templates** installed first — a one-time ~1 GB
download, either from *Editor → Manage Export Templates → Download* or straight
from the release:

```bash
curl -LO https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
unzip -q Godot_v4.7.2-stable_export_templates.tpz
# macOS
mkdir -p "$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable"
cp templates/* "$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable/"
# Windows: %APPDATA%\Godot\export_templates\4.7.2.stable\
```

Without them the export fails with `No export template found at the expected
path`, which is the only thing standing between these commands and a binary.

The macOS build needs `textures/vram_compression/import_etc2_astc` on, which is
why it is set in `project.godot`. Godot refuses a universal or arm64 build
without it — those targets have no S3TC/BPTC hardware — and the error names the
setting. It costs import time and nothing at runtime on desktop.

The macOS app is signed **ad-hoc**, which is enough to run it yourself and not
enough to hand to a stranger without Gatekeeper objecting. Notarisation needs an
Apple Developer account and is not set up.

Sizes, for reference: `GUB.exe` 109 MB plus a 7.9 MB `.pck`; `GUB.app` 172 MB
universal. Most of that is the engine, not the game.

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
the invite codes, the match rules, **a full playthrough from the main menu to
the results screen**, a ragdoll that has to survive hitting the ground, three
combat modes that report what they did, and three checks that walk the path a
player walks — that holding W moves a Gub, that starting a match takes the
mouse, and that leaving one does not leave Gubs asking a peer that is gone. Ten
in all. Run it before committing anything that touches gameplay.

Most of those exist because of one bug shape, met repeatedly: **a thing wired
into a testbed and into nothing else.** `tools/` scenes stand their subject up
directly and hand it whatever the real scene was meant to hand it, which makes
them very good at proving a feature works and blind to whether anything calls
it. Nothing read the movement keys in a real match; nothing instanced the HUD in
the arena; the ambience pointed at a path that never existed. All three passed
every check that existed at the time.

So: **if you add a harness, ask what it is supplying by hand** — that list is
the list of things nothing else is checking. And `playthrough` is the one that
catches the rest, because it is the only check that walks the joins between the
parts rather than testing inside one.

It fails on any `SCRIPT ERROR` as well as on a bad exit code, because Godot
prints one and carries straight on — a clean exit proves nothing by itself. It
fails the same way on `No multiplayer peer is assigned`, which is always a bug
and never noise, wherever in the suite it turns up.

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
| `preview_island` | **the map** — nine framings, `match` for real Gubs, `hud` to keep the HUD |
| `playthrough.tscn` | the whole flow, menu to results, 39 assertions, headless |
| `match_rules.tscn` | 60 assertions across 9 scoring scenarios, headless |
| `net_loopback.tscn` | two real processes over a real socket. Not in the gate — it binds a port |
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
