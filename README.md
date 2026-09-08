# GUB

A match-based third-person multiplayer game in Godot 4.7.2. You are a Gub — a
small yellow alien — fighting with thrown spears that kill in one hit, on one of
two maps: **Whisperbloom Hollow**, a floating enchanted-forest island grown from
a seed, or **Rust**, a hand-made industrial yard under a hard sun. The host
picks in the lobby.

Spears are the whole fight. One lands, you die, and the thrower's hand is empty
until it grows back, so an empty hand is the most useful thing on screen: it
tells everyone in sight that the Gub holding it is harmless for the next few
seconds. Two abilities exist to bend that around: a **mushroom** planted as cover
you cannot be hit through, and a **lure** lobbed past it that drags everyone
nearby out into the open for about a second.

---

**Just want to play it?** See [`docs/PLAYING.md`](docs/PLAYING.md) — run one
`.exe` and paste an invite code. Only the person hosting has any setup to do,
and it is one playit.gg tunnel. The rest of this file is about building it from
source.

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
| dive | `Space` again in mid-air — once per jump, and you commit to it |
| throw spear | left mouse — winds up, leaves the hand 0.71 s later |
| aim (zooms in) | right mouse |
| mushroom, lure | `Q`, `E` |
| scoreboard, pause, chat | `Tab`, `Esc`, `T` |

---

## Playing together

The host clicks **Host** and gets a ten-character **invite code** like
`K3M9P-2XQ7R`. Anyone else picks **Join**, types it in, and is in the lobby.

That code *is* the host's address — the IP and port, Crockford base32, no
backend anywhere. This is what makes it work on a LAN, over a VPN, or across the
internet, with nothing of ours to run and no account to make with us. It is also
the trade-off: a purely random key would hide the host's IP, but would need a
relay server to turn keys back into addresses. See **D-005** — this is a product
decision worth revisiting, not a settled one.

For play across the internet the host sets a **public address** in Settings —
the `host:port` of a [playit.gg](https://playit.gg) UDP tunnel forwarding to
local **27015** — and the code then carries that endpoint instead of a local
one. Players install nothing; the host runs one agent. Leaving it blank is the
old behaviour, which is a tailnet address if Tailscale is up and a LAN address
otherwise. See **D-028**.

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
| `docs/ARCHITECTURE.md` | how it is put together, and where the seams are |
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
| `preview_island` | **the island** — nine framings, `match` for real Gubs, `hud` to keep the HUD |
| `preview_map` | **Rust** — top-down, side, or eye height on any spawn pad; `probe` prints the floor as ASCII. Checks every pad with the physics, and is in the gate |
| `playthrough.tscn` | the whole flow, menu to results, headless. Add `-- rust` to play it on the static map |
| `match_rules.tscn` | 60 assertions across 9 scoring scenarios, headless |
| `net_loopback.tscn` | two real processes over a real socket. Not in the gate — it binds a port |
| `inspect_scene.gd` | dump a scene's tree, clips, bones and triangle counts |
| `preview_anim`, `preview_grip`, `preview_ragdoll` | contact sheets of a clip, the spear in the fist, a corpse falling |

`combat_range` runs the **real match path** — an offline session on `Net`, a
roster, `MatchState.register_arena`, kills through `MatchState.report_kill` — so
a throw that works there works in a match. Pass a mode as the fourth argument
(`flight`, `hit`, `arc`, `miss`, `mushroom`, `lure`, `lure_self`, `free`) and
`trace` as a fifth to print the whole flight, which is the only way to tell a
miss from a hit whose kill was dropped.

### Regenerating the art and audio

Both are committed, so you only need this if you change a source file:

```bash
bash tools/build_gub.sh             # the Gub: eight Mixamo FBX → one .glb. Needs Blender 5.2
python tools/decimate_assets.py     # spear, lure, mushroom. numpy, scipy, pillow, fast_simplification
python tools/make_sfx.py            # needs numpy
python tools/prepare_map.py         # needs numpy, pillow
python tools/rig_report.py          # checks the Gub's rig; prints, changes nothing
```

The three props arrive at ~500k triangles each and leave at 19k between them,
with UVs transferred back seam-aware. **The Gub has its own pipeline** and does
not go through `decimate_assets` at all: `tools/build_gub.sh` runs
`tools/build_gub.py` in headless Blender, which consolidates the eight FBX files
in `assets/source/GUB_2/` into one 1.5 MB `art/generated/gub.glb` — one armature,
one mesh, nine clips, 10.5k triangles, 1.80 m tall, root motion locked, every
clip's facing aligned — and prints every measurement it takes (**D-029**). Three
runs of it produce a byte-identical file, and it refuses to write one whose jump
clips go through the floor. After a rebuild, run
`"$GODOT" --headless --path . --import` once so Godot re-extracts the texture.

`tools/rig_report.py` is how you tell whether a rig change helped, and is worth
running after any change to the rig or to a source file. Sources in `assets/` are
never modified; re-running any of these is always safe.

**Maps are split raw/processed, and only the processed half is in the repository.**
`tools/prepare_map.py` reads `assets/source/Rust/rust.glb` — a 337 MB Blender
export of the Rust arena, 333 MB of which is fifty-two lossless 2K PNGs — and
writes `art/maps/rust/rust.glb` at about 43 MB. It drops Blender's default cube
and the scale-reference figure the map was blocked out against (along with the
one animation clip, which only ever animated that figure), prunes everything
left unreferenced, and re-encodes the textures as JPEG: base colour at 2048 q85,
normal maps at 1024 q90 with no chroma subsampling, and the handful of normals
covering more than 5% of the arena's surface area held at 2048. The one texture
with a real alpha channel stays a PNG, because JPEG has nowhere to put it. The
raw export is `.gitignore`d — it is over GitHub's 100 MB single-file limit — so
it lives on the team's shared drive and only has to be on disk when the map is
being regenerated. Geometry is untouched: the export is already 1 unit = 1 metre
(D-002). The run prints the arena's true world bounds and its lowest vertex,
which is where the match's void kill height comes from, and then re-reads what it
wrote and checks it.

The **textures Godot extracts back out** of that `.glb` are `.gitignore`d, and
only `rust.glb` and `rust.glb.import` are committed. The importer is set to
Extract, which is what gets each of the 51 images its own VRAM compression — but
it writes all 41 MB of them out beside the file they came from, which would
nearly double the map's cost in the repository to store nothing new. They come
back in about half a minute from the import step that `tools/smoke_test.sh` runs
first and that the editor runs on a fresh clone, so there is nothing to do by
hand.

**The map itself is four nodes and eight coordinates.** `scenes/world/maps/rust.tscn`
instances the `.glb` untouched; `scripts/world/static_map.gd` builds the
collision and puts back the back-face culling at load, because neither survives
the import (**D-031**). `tools/preview_map.gd` is how you look at it and how the
gate checks its spawn pads.

---

## Layout

```
art/generated/   game-ready meshes and textures — committed, no Python needed
assets/          raw source art (.gdignore'd; only the MegaKit is imported)
audio/sfx/       synthesised sound effects — committed, see tools/make_sfx.py
docs/            STATUS, PLAN, DECISIONS, ARCHITECTURE
resources/       shaders, environment, bus layout
scenes/          player, items, ui, world
scripts/         game, items, net, player, ui, util, world
tools/           dev tools and testbeds — none of this ships
```

Autoloads: `Settings`, `Net`, `MatchState`, `SceneFlow`, `AudioDirector`.

---

## Credits and licence

The game's own code and assets are **MIT** licensed — see [LICENSE](LICENSE).

Environment art is the **Stylized Nature MegaKit** (CC0). The Gub, spear, lure
and mushroom are project assets. Sound effects are synthesised from scratch by
`tools/make_sfx.py`.
