# Design & Engineering Decisions

Running log. Newest phase last. Each entry: what was decided, and why.

---

## D-001 — Engine: Godot 4.7.2 stable, GDScript, Forward+
The user has `Godot_v4.7.2-stable_win64` locally, so the project pins that version.
GDScript over C# to keep the toolchain to a single dependency (no .NET SDK required to
build). Forward+ renderer because the map leans on volumetric fog, many small dynamic
torch lights, and SDFGI/SSAO — all Forward+-only or Forward+-preferred features.

## D-002 — World scale: 1 unit = 1 metre
*The Gub's half of this is history: it is now authored at 1.80 m and imported at
`root_scale 1.0` (**D-029**). Everything else still holds.*
The Stylized Nature MegaKit is authored at roughly human scale (a common tree is ~7 m
tall, tall grass ~1.8 m). The supplied `Gub.glb` is 5.18 units tall in bind pose, so the
Gub is imported at **0.35 scale** → ~1.81 m. Spear (1.90 units) is scaled to ~0.75 →
1.42 m. This lets us use realistic gravity and jump tuning without fighting the kit.

## D-003 — Source meshes are decimated offline
*The Gub is no longer one of these targets — it has its own pipeline,
`tools/build_gub.py` (**D-029**). The three props below are unchanged.*
Every supplied `.glb` (`Gub`, `Spear`, `Lure`, `Mushroom/base_*`) is a ~500,000-triangle
photogrammetry-style mesh with a 4K texture. Eight networked Gubs plus spears, deployed
mushrooms and lures would be 5M+ triangles per frame before shadows — untenable.

`tools/decimate_assets.py` performs quadric-error decimation (`fast_simplification`) and
re-attaches UVs by seam-aware nearest-source-vertex transfer, then rewrites a clean `.glb`
into `art/generated/`. Skin weights are *not* transferred — they are solved on the
decimated mesh itself, for the reason in D-023. Sources in `assets/` are never modified — the
pipeline is re-runnable and the raw art stays pristine.

Targets: Gub 18k tris (skinned, drawn up to 8× plus shadows), Spear 4k, Lure 6k,
Mushroom 12k.

## D-004 — Networking: ENet, host-authoritative, host also plays
Godot's high-level multiplayer over ENet. The host runs the authoritative match state
(scores, kills, spawns, projectile simulation) and also plays. This is the right shape for
a casual 2–8 player party game: no dedicated server to operate, no matchmaking backend.

Split of authority:
- **Client-authoritative**: its own Gub's position/rotation/animation (replicated via
  `MultiplayerSynchronizer`). Cheating a position in a friends-only party game is an
  acceptable trade for eliminating prediction/reconciliation complexity.
- **Server-authoritative**: throwing (client sends an *intent* RPC), all projectile
  simulation, hit resolution, deaths, respawns, scoring, match phase, and timers.

## D-005 — Invite codes encode the host endpoint
The user asked for "click invite, get a key, anyone with the key can join". Doing that
across the internet with no fixed address normally needs a signalling/relay server, which
means infrastructure to run and pay for. Instead the invite code is a **Crockford-base32
encoding of the host's IPv4 address + port**, formatted `XXXXX-XXXXX`. Six bytes
of payload become exactly ten characters, so there is no padding and every code
is the same length.

This is real and works today over LAN, over a VPN (Tailscale/Hamachi/Radmin), or over the
internet with one forwarded port — and it needs zero backend. The code is opaque enough to
feel like a lobby key while remaining a pure client-to-client dial.

`docs/ARCHITECTURE.md` records the seam where a relay/signalling transport would slot in
later without touching game code (`Net` exposes `host()`/`join()` against an
abstract `MultiplayerPeer`).

## D-006 — Ragdolls are built at runtime, not authored
Hand-authoring 29 `PhysicalBone3D` nodes with fitted capsules into a `.tscn` is fragile and
unreadable in diffs. `scripts/player/ragdoll_builder.gd` walks the imported skeleton's rest
pose and generates the physical-bone hierarchy procedurally (capsule length/radius derived
from each bone's child offset). One code path, no scene bloat, and it survives a re-import
of `Gub.glb`.

## D-007 — The map is generated from a seed, not hand-placed
The island surface, its rocky underside, and the several hundred scattered props are
produced by a seeded generator (`scripts/world/`). Reasons: a hand-placed `.tscn` with 600
nodes is unreviewable; a seed guarantees every client builds a byte-identical map without
replicating placement; and it lets the layout be tuned by changing numbers instead of
dragging meshes. Landmarks (shrine, arch, bridges, torch ring, spawn pads) are placed
explicitly on top of the generated terrain, so the map still reads as designed rather
than as noise.

## D-008 — The Gub's animation clips needed three fixes before they were usable
*History. The asset these fixes were applied to no longer exists — the Gub was
rebuilt from eight Mixamo clips in **D-029**, which had to solve the facing
problem below a second time, on a different rig.*
Inspecting `Gub.glb` turned up three problems that would each have been a
mysterious bug later. All three are fixed in `tools/decimate_assets.py`, so they
stay fixed across re-imports rather than being patched around in game code.

**1. Every clip shipped twice.** `Idle` has two keyframes — a held pose — while
`Idle.001` has the 326 keyframes that are the actual animation. That is what a
Blender NLA export looks like when both the strip and its action get written.
The pipeline keeps whichever variant has the most keyframes and gives it the
clean name, so gameplay code asks for `Idle`, not `Idle_001`. Eight real clips
survive: Idle, SlowRun, FastRun, CrouchWalk, Crouch, Jump, Slide, SpearThrow.

**2. Every clip carried its travel baked into the root joint.** SlowRun walks
4.5 units forward over its 0.73 s; Jump arcs 12.6 units and rises 3.0. Left in,
the mesh slides out of the `CharacterBody3D` carrying it. The pipeline locks the
root joint's horizontal translation always, and its vertical translation only
when the rise is over 0.5 units — that keeps the weight-shift bob that gives a
run cycle its life while discarding the leap the physics body is already doing.

That baked travel is useful on the way out, though: it is the speed each clip
was *authored* to move at, and matching it is the difference between feet that
grip and feet that skate. The pipeline prints it, and `gub.gd` uses it:

| clip       | authored speed |
|------------|----------------|
| CrouchWalk | 1.21 m/s       |
| SlowRun    | 2.20 m/s       |
| Slide      | 3.00 m/s       |
| FastRun    | 4.01 m/s       |

**3. Every clip was authored at a different resting yaw.** Idle sits 65.8° off
the rest pose, CrouchWalk 33.9°, FastRun 13.4°. One clip at a time this is
invisible; the moment an AnimationTree blends between two of them the body
swings sideways on every state change.

Measuring this correctly needs forward kinematics: the root bone carries the
rig's own rest orientation, so reading a Euler yaw off its quaternion measures
the bone, not the body. `tools/rig_math.py` walks the rest hierarchy and takes
the facing from the line between the hips — the one pair of joints that stays
put while the arms and torso animate. The pipeline then applies a compensating
yaw to the root joint's rotation keys. Motion *within* a clip is untouched, so a
throw still winds the body up. After the pass every clip measures within 0.01°
of the rest facing.

## D-009 — The sky is a shader, and the environment is tuned around torches
Whisperbloom Hollow's sky (`resources/shaders/enchanted_sky.gdshader`,
`resources/config/arena_sky.tres`) is fully procedural: gradient, stars, moon,
aurora and cloud wisps are all computed in one `shader_type sky` pass. A
panorama texture would have been simpler, but it cannot animate, it cannot be
retuned without a round trip through an image editor, and a night sky that never
moves reads as a painted backdrop the moment a player stands still. Every
animated term is driven off `TIME` at speeds between 0.012 and 0.05 — a cloud
wisp takes about ninety seconds to cross the dome — so the sky has life without
ever pulling the eye during a fight.

**Cost is controlled by which pass does what.** The sky is drawn three ways per
frame: the screen, the radiance cubemap, and (because the shader declares
`use_quarter_res_pass`) a quarter-resolution buffer.

- *Aurora and clouds* — the only fbm noise in the shader — run **only** in the
  quarter-res pass and are composited back with premultiplied alpha. That is a
  16× saving on the expensive half of the sky, and the upscale blur is free art
  direction on something that is meant to look like vapour.
- *Stars* run **only** at full res. They are single-cell hash lookups, not
  loops, and in a 256 px radiance cubemap they would be sub-texel sparkle noise
  in the ambient term; in a reduced-res pass they would alias into crawling
  dots.
- The *cubemap pass* has no sub-res buffer to read, so it recomputes the
  aurora and clouds at one octave instead of three. The ambient light only ever
  wanted the low-frequency colour.

There is no raymarch anywhere. The aurora is three gaussian bands whose centre
heights wander with 2-octave noise; the moon is a disc with a phase terminator
in a disc-local frame, so its face does not slide as the camera turns.

**The moon follows LIGHT0.** With `moon_follow_light` on (the default) the disc
is drawn at `LIGHT0_DIRECTION`, so the arena's DirectionalLight3D *is* the moon
and the two can never disagree. `moon_direction` is the fallback when no
directional light exists. The arena is expected to carry one: cool
(≈`Color(0.62, 0.72, 1.0)`), energy ≈0.30, aimed at the island from
`(-0.42, 0.38, -0.82)`, shadows on. That value is deliberately low — it is fill,
not key. The torches are the key light.

**Colour uniforms are declared in linear space in the shader** so the in-source
defaults land on the same colour as the sRGB values `arena_sky.tres` writes back
through the `source_color` hint. Without that the two disagree by a gamma curve
and the shader's own defaults look like a different sky.

### The environment (`resources/config/arena_env.tres`)
- **Glow threshold 1.45, not 1.0.** The Gub is near-saturated yellow. At the
  default threshold he wore a permanent halo and read as a light source rather
  than a target. At 1.45 a torch-lit Gub peaks around 0.9 and stays crisp, while
  flames, the moon and emissive props still bloom hard.
- **Ambient energy 2.5 with the source set to the sky.** The number looks large
  until you remember what it is multiplying: the radiance cubemap of a night sky
  averages out almost black. At 1.0 everything outside a torch pool crushed to
  literal `(0, 0, 0)`; at 2.5 it reads as dark. Retuning the sky retunes the
  island's fill light for free, which is the whole point of sourcing it there.
- **Volumetric fog at density 0.02**, with the depth fog kept very thin
  (0.0035) purely to separate the island's far edge from the void. Torch
  OmniLights need `light_volumetric_fog_energy` around 2.0 to punch a visible
  halo through it.
- **SDFGI is off.** The island is generated at load and then never moves, so
  SDFGI's cascades would spend their budget re-solving static geometry. Sky
  ambient plus SSAO gets the same read for a fraction of the cost.

`tools/preview_sky.tscn` is the harness all of this was judged in — a floating
slab, torches, silhouette cones and a Gub, with the camera framing picked by a
trailing `horizon` / `up` / `edge` argument that `tools/snapshot.gd` passes
through untouched.

## D-010 — Ragdolls are local and cosmetic, and barely damped
Corpses are **not** replicated. Each client builds and simulates its own, so two
players see the same death land slightly differently. That costs nothing: by the
time a Gub is a ragdoll it has stopped being part of the game, and nobody makes
a decision from where a corpse ended up. Replicating thirteen rigid bodies per
death — with an instant-kill weapon and eight players — would spend most of the
bandwidth budget on scenery.

The bodies are generated from the skeleton's rest pose by
`scripts/player/ragdoll_builder.gd` (see D-006) and placed at the *current* pose
before simulation starts, so the corpse begins mid-stride rather than snapping
to a T-pose first.

One tuning note worth keeping, because it cost a debugging pass: the first
version used heavy damping (linear 0.35, angular 1.6) to stop corpses twitching.
It worked — so well that a Gub killed while standing still simply *stayed
standing*, held up by its own joint limits. A ragdoll that does not fall over is
worse than one that jitters. Damping is now near zero (0.02 / 0.22), joints are
slack (softness 0.92), and `can_sleep` handles the settling instead.

## D-011 — The testbeds run the real match, not a parallel offline branch
`Net.start_offline()` opens a session on an `OfflineMultiplayerPeer`: peer id 1,
`is_server()` true, no socket, no port, no firewall prompt. Everything
downstream — every `Net.is_host` branch, every `@rpc`, every authority check —
then takes exactly the path it takes when hosting for real. The `rpc()` half of
the codebase's `rpc()`-then-call-locally pattern simply reaches nobody, and the
local half still runs.

The alternative was an `if offline:` branch inside `GubCombat`. That would have
been three lines and it would have been wrong: the offline path is the one the
testbeds exercise every day and the networked path is the one that ships, so any
divergence between them rots in exactly the direction that hurts.

`tools/combat_range.tscn` builds on this. It writes fake entries straight into
`Net.players` for peer ids in the 900s, and `MatchState` spawns a Gub for each
without ever asking whether the peer behind one is real. The opponents are
therefore *remote* Gubs to the running client — no input, no gravity, no camera —
which is both what a target dummy should be and the only regular look anyone
takes at the remote-Gub code path before eight people do. Two of the three bugs
found on the first run of that scene were remote-Gub bugs.

## D-012 — Snapshot warmup is counted in physics ticks
`tools/snapshot.gd` used to count its own `_process` calls. On a fast card that
loop runs at several hundred frames a second, so "90 frames" meant a different
amount of *game* time on every machine and in every window size — and the first
few frames are the slow ones (scene load, shader compilation), during which the
physics engine catches up by running several ticks inside one draw.

It now caps `Engine.max_fps` to the physics rate and waits on
`Engine.get_physics_frames()`, so one warmup unit is one physics tick and a scene
that scripts itself off `_physics_process` is caught at the moment it intended.

This is not a tidiness fix. Every visual check in Phases 2 and 4 was made through
this tool, and the ragdoll was signed off on a frame that — under the old
counter — was about 0.2 s after death. The corpse pulls itself apart at 0.5 s.
A verification loop that silently samples earlier than you asked will certify
broken things, and did.

## D-013 — The ragdoll's joints were too tight, not too loose
A corpse held together perfectly in the air and detonated the instant it touched
the ground — always starting at a foot, reaching 200 m/s within a dozen ticks.
Three plausible causes were investigated and are recorded here so nobody spends
another afternoon on them:

- **The basis handedness** (`_basis_along`) was genuinely wrong once and is now
  right. Fixing it changed nothing.
- **`body_offset`** is correct. Instrumenting the corpse showed every bone
  tracking its rigid body exactly; the bodies themselves were separating.
- **Continuous collision detection**, which the small fast-moving shin capsules
  looked like a textbook case for, delays the blow-up by four physics ticks and
  fixes nothing.

The actual cause: a cone-twist joint driven past its limit does not clamp.
Godot's limit solver pushes back, and past a large enough violation it pushes
back hard enough to *add* energy. Chain thirteen of them and the corpse tears
itself apart. Landing folds a knee far further than the 44 degrees it was
allowed, so the explosion happened on the first ground contact, every time.

Bisecting the joint configuration is what proved it. With the angular limits
removed entirely (pin joints) the corpse settled normally. With Godot's stock
softness/relaxation/bias but the original spans, it still exploded. So the
solver tuning — the obvious suspect, and the thing D-010 spends a paragraph on —
was never involved. The spans were.

Two changes were needed. The spans are now wide enough to cover the range a
falling body actually reaches (knees and elbows to 105 degrees). And the joint
frame is rotated 90 degrees about Z, because a cone-twist measures swing and
twist about its frame's local **X** while the capsules run along local **Y**:
with an identity basis the cone opened sideways across the limb, so "swing"
limited rotation about the bone and "twist" limited the bend. A knee folding on
impact was being checked against a 14-degree twist limit.

The lesson worth keeping: **when in doubt, open a ragdoll joint up.** A corpse
that bends too freely looks rubbery, which is the intended look anyway. One that
bends too little does not look stiff — it explodes.

## D-014 — Thrown arcs are solved, not aimed
The lure is slow enough for gravity to matter — 22 m/s under 22 m/s² — so firing
it flat along the aim direction dropped it about five metres from the thrower no
matter where the crosshair was. A lure "lobbed past cover" landed at your feet
every time, and the ability was unusable in a way no amount of tuning would have
fixed.

The host now solves the launch angle that actually reaches the aim point, taking
the flatter of the two solutions so it reads as a thrown object rather than a
mortar shell, and falling back to 45 degrees — maximum range — when the point is
out of reach, so an over-ambitious throw still travels as far as it can.

This puts a hard ceiling on the ability at `s²/g`, about 22 m, which is a
feature: the lure pulls someone out of nearby cover, it is not a way to reach
across the island.

The wire format carries the **target point**, not a velocity. The client still
chooses where the lure goes and the host still chooses how fast it gets there,
so a modified client cannot fling one at an arbitrary speed. `LURE_GRAVITY` in
`gub_combat.gd` must stay equal to `Lure.GRAVITY`, which integrates the flight —
the arc is solved in one file and flown in another, and if they disagree the
lure lands somewhere other than where it was aimed.

The spear does not need this. At 42 m/s with a third of world gravity its drop
is small enough over its useful range that leading the target is a skill rather
than an obstacle, which is the point of D-004's fast, flat, instant-kill weapon.

## D-015 — Anything a still frame cannot prove gets a harness
Two things shipped as "done" that were not, and both failed the same way: the
only check on them was a rendered frame, and a rendered frame cannot show a
trend, a rule, or a decision.

The ragdoll was certified on a screenshot taken 0.2 s after death, and pulled
itself apart at 0.5 s (D-012 covers the clock bug that made that sampling
possible). The match rules ran, but only ever in free-for-all with one live
player — teams, lives, the clock and the results summary were written, compiled,
and never once executed.

So there are now three tiers of verification, each for a different kind of claim:

| tool | proves |
|---|---|
| `tools/preview_*.tscn` | it *looks* right — needs a person, always will |
| `tools/ragdoll_stability.tscn` | a corpse is still a corpse 150 ticks later |
| `tools/match_rules.tscn` | 42 assertions across 8 scoring scenarios |
| `tools/smoke_test.sh` | all of the above, plus the import, as one gate |

Two details make these worth more than they look. `ragdoll_stability` was
checked against the *old* builder and correctly FAILs — a regression guard that
has never been seen to fail is not a guard. And `smoke_test.sh` treats any
`SCRIPT ERROR` in the output as a failure, because Godot prints one and carries
on running: a clean exit code proves nothing on its own, which is exactly how
the lure managed to be "compiling" for a week while never once launching.

`match_rules` runs as a *scene*, not a `--script` main loop. A script main loop
is compiled before the autoloads are registered, so it cannot so much as name
`MatchState` or `Net` without failing to parse — and any script it statically
references inherits that failure, silently loading the scene without its script
attached. That is worth knowing before writing the next dev tool.

## D-016 — The sound effects are synthesised, not sampled
There is no sound library for this project, so `tools/make_sfx.py` generates the
whole set: filtered noise for the throw whoosh, a 150→62 Hz sweep with a noise
slap for a body hit, three *inharmonic* partials for the lure's struck-glass
chime (whole-number ratios would sound like a musical note rather than glass), a
rising tone for its fuse and a falling one for its pull.

For a game that looks like this, that is not a compromise. A Gub is a cartoon,
and short synthetic hits read as deliberate stylisation where a mismatched
library sample reads as an accident. It is also the same argument already made
for the meshes (D-003) and the ragdoll (D-006): generated means diffable,
tunable from a single number, and reproducible on any machine. The complete set
is 381 KB.

Placement carries as much meaning as the sounds. Impacts, throws, deaths and
deployments are **3D and positional**, because they are events in the world that
give away where you are. Three are deliberately **2D**: the spear regrowing in
your hand, the respawn, and the hitmarker. Each is feedback about your own
situation rather than something another player could hear — and the hitmarker in
particular is the only confirmation a thrower ever gets that a spear landed,
since the victim may be sixty metres away behind a tree and the spear is already
gone.

## D-017 — The engine version is part of the source, and 4.6 is not close enough
`project.godot` pins 4.7 (D-001) and that pin is load-bearing rather than
aspirational. Opening this project in Godot **4.6** does not degrade gracefully:
`AnimationNodeBlendSpace1D.add_blend_point()` gained a fourth `name` argument in
4.7, `gub_animator.gd` passes it, and the whole animation tree therefore fails to
parse. Every single check in `tools/smoke_test.sh` then fails — including the
ones that have nothing to do with animation — with

```
Parse Error: Too many arguments for "add_blend_point()" call.
             Expected at most 3 but received 4.
```

which reads exactly like a bug in this repository and is not one. That cost real
time to diagnose on a machine whose `/Applications/Godot.app` was 4.6.3.

Two things follow, both now in the tree:

- `tools/smoke_test.sh` **finds** the engine instead of hardcoding one path, and
  refuses a binary that does not report 4.7 rather than running it and producing
  a wall of misleading parse errors. Having several Godots installed at once is
  the normal state of a machine, not an exotic one.
- The correct diagnostic is `--version`, and it is worth reaching for early. A
  clean `--headless --path . --import` that rewrites **no** `.import` files is
  the confirmation that the engine in hand is the one the committed assets were
  generated by; if those files come back modified, the engine is wrong.

## D-018 — The arena instances the HUD, and nothing had ever put the two together
`scripts/ui/hud.gd` was written on `feat/ui` and opens with "the arena is
expected to instance this once". `scripts/world/arena.gd` was written on
`feat/island` and never did. Both branches were green, both were reviewed, both
were honest — and the game they merged into would have run every match with no
crosshair, no score, no kill feed, no scoreboard, no pause menu and no results
screen, because the one line joining them belonged to neither author.

Neither a code review of a branch nor a screenshot of a testbed can catch that
class of defect: `tools/hud_range.tscn` hangs the HUD on the combat range by
hand, so the HUD had been *seen working* the whole time. Only something that
walks the real path from the menu to the results screen can notice a join that
nobody made. That is what `tools/playthrough.tscn` is for (D-019), and finding
this is what it was written to prevent happening again.

The same merge produced a quieter version of the same bug. `Ambience.LOOPS`
pointed at `res://assets/audio/ambience/forest_night.ogg`, a path invented on the
island branch; the audio branch committed the real beds to
`res://audio/ambience/ambient_forest.wav`. `_build_audio` skips a file that does
not exist **in silence**, by design, so the island shipped with no ambience at
all and nothing anywhere said so. A silent fallback is the right behaviour for a
missing optional asset and the wrong behaviour for a typo, and there is no way
for the code to tell those apart — so the guard against it is a test that asserts
the sound is playing, not a louder `if`.

## D-019 — Anything that crosses two systems gets a playthrough, not a testbed
D-015 established that anything a still frame cannot prove gets a harness, and
four of them exist. Every one looks at a single seam: `match_rules` scores a
match with no island under it, `combat_range` throws a spear in a room with no
lobby in front of it, `ui_range` photographs screens that were never navigated
to, `ragdoll_stability` drops a corpse. All were worth writing. Not one of them
could see D-018, because the defect was not inside any seam — it was the absence
of a join between two of them.

`tools/playthrough.tscn` runs the whole path in one go — menu, host, lobby,
start, arena build, warmup, kills, results — through the real scenes and the real
autoloads, and asserts something at every stop. It is in `smoke_test.sh` and it
is the only check there that can notice a scene flow coming apart.

The rule this generalises to: **a harness per seam catches bugs inside parts, and
only a harness per path catches bugs between them.** Two agents working on
disjoint file sets will produce clean merges and broken games, and this is the
cheapest thing that notices.

## D-020 — Spectating is a change of subject, not a second camera
A dead Gub is hidden, never freed (`MatchState._apply_death`), so its
`GubCamera` is still alive and still holds the viewport. Spectating therefore
needed no new node: `GubCamera.spectate(gub)` swaps which body `_follow` tracks
and everything else — the spring arm, the collision mask that ignores players,
mouse look, shake, the aim zoom — is already solved and stays solved.

A separate spectator rig was the obvious alternative and would have had to
re-derive all of that, then drift out of step with the real camera the first time
either was tuned. The cost of the chosen approach is two guards in `_process`
(do not hand a view basis to a body that is not ours, do not let a corpse aim),
which is a good trade for not owning a second camera.

The target is held in the HUD as an **index** into `MatchState.living_gubs()`
rather than as a reference to a Gub. The list changes constantly underneath —
the watched player dies, respawns, or disconnects — and an index degrades into
"you are now watching somebody else" where a stale reference degrades into a
crash.

## D-021 — Ending a match is a broadcast, not a navigation
The results screen's "back to the lobby" moved exactly one person. Every other
client stayed on a results screen whose only remaining exit was leaving the
session, because `Net` had no "the match is over, everyone come back" message at
all — the previous author noted this in a comment rather than fixing it, which
was the right call at the time and is fixed now.

`Net.request_return_to_lobby()` and `Net.request_rematch()` are host-only and
broadcast. A match is something a lobby does together, so ending one or running
it again is a decision with one owner, and the buttons that make it are shown
only to the host; everyone else is told who they are waiting for. A *client's*
own "back to the lobby" still works and still moves only them, because leaving a
match you are finished with should never need anyone's permission.

A rematch deliberately keeps the map seed. "Again" is a request for another go at
the match everyone just agreed to, and quietly handing them a different island
would be answering a different question. Rerolling the map is a lobby control.

A related hole was open in the same place: a client that dropped mid-match left
its Gub standing in the arena **on every other machine**, because `Net` erased
the roster entry and nothing told `MatchState` to clear up the body. It stayed
targetable and, worse, kept counting toward "last Gub standing", so a lives match
could reach a state where it could never end. `Net.player_left` is broadcast now,
and `MatchState` frees the Gub and re-runs the win check.

## D-022 — Two processes, one socket: what offline mode could never show
D-011 argued that `Net.start_offline()` is the right shape for a testbed, and it
was: peer 1, `is_server()` true, no socket, and every `is_host` branch and
authority check downstream takes the shipping path. That argument has one hole it
was always honest about — `rpc()` reaches nobody. Only the "call locally" half of
the codebase's rpc-then-call-locally pattern had ever run, and **nothing had ever
been serialised**.

`tools/net_loopback.tscn` and `tools/net_test.sh` close it on one machine: two
real Godot processes, a real ENet socket on 127.0.0.1, and nine stages —
connect, roster, name collision, config, chat both ways, match start, the arena
with the client's three abilities used in it (added later, by D-024), a kill, and
a disconnect. Both peers load the real arena and build the same island from the
replicated seed, so the kill is asserted end to end: the host calls
`report_kill`, the client's `player_killed` fires, and both sides' `stats` agree.

It is deliberately **not** in `smoke_test.sh`. It binds UDP 27015, and a firewall
prompt would hang an automated gate with no way to tell that apart from a hang in
the game.

Three bugs fell out of the first run, and the interesting thing about all three
is *why* offline mode hid them:

- **The host RPC'd itself.** `send_chat`, `set_ready`, `set_team` and
  `set_name_local` all sent to peer 1 and then called locally, and on the host
  peer 1 is itself. Godot refuses (`RPC on yourself is not allowed by selected
  mode`) once per chat line for the whole session. Nothing was lost — the local
  call did the work — so the only symptom was a filling log.
  `OfflineMultiplayerPeer` swallows `rpc_id` in silence, so no testbed could see
  it. The fix is to send only when we are *not* the host.
- **A spawned Gub raced its own synchronizer**, and chasing it turned up a
  second, larger bug behind it. `_create_gub` is reliable; the
  `MultiplayerSynchronizer` pushes position as unreliable from the moment the
  node enters the tree. Different ENet channels, no ordering between them, so an
  update arrives before the node it addresses exists. Offline has no channels to
  race.

  The first attempt — hold the owner's synchronizer quiet for a third of a
  second — barely helped, and the reason why was the real finding: **the host
  began the match as soon as its own island had built, while other peers were
  still building theirs.** The island is generated and blocks the main thread for
  two to six seconds per machine, so the host was spawning Gubs and replicating
  them into peers that had no arena yet. Worse than the noise, `_create_gub` is
  sent once and never re-sent, so a peer still building when it arrived could
  miss a spawn permanently and spend the match in an empty arena including its
  own body. That never actually bit, because the RPC queues behind the blocking
  build rather than being dropped — but that was luck, not design.

  So `register_arena` now reports up to the host, and the host waits for every
  peer before starting (with `ARENA_READY_TIMEOUT`, so one crashed peer cannot
  hang a lobby for ever). Nobody plays until everybody can. With the receiver
  guaranteed to have an arena, the quiet window only has to outlast channel
  reordering, which is what it is sized for now.

  `MultiplayerSpawner` remains Godot's real answer — it puts the spawn and the
  state on one ordered path — and adopting it is a rewrite of `_create_gub` worth
  doing before this ships to strangers.
- **`MatchState` asked a peer that was already gone**, exactly as `Gub.is_local`
  used to. Everything there goes through `Net.local_id()` now, which guards it.

Two paths worked correctly the first time over a real socket and are worth
recording as such: the connect timeout (a client dialling a dead host fails
cleanly at eight seconds with the right message) and the bind-failure branch
(`Could not open port 27015` when something already holds it).

What this still cannot tell anyone: latency. Loopback has none, so nothing here
says whether a client-authoritative Gub *feels* right on a real link, or whether
the lure's client-side pull reads as fair to the person being pulled. That needs
two machines and remains the largest untested thing in the project.

## D-023 — The Gub's skin was rebound, because the tearing was in the weights
*History. The mesh, the rig and `tools/rig_clean.py` are all gone — see **D-029**,
which records what the replacement asset is worse at, measured with the same tool.*
D-008 fixed what was wrong with the Gub's *clips*. It did not touch what was
wrong with its *bind*, and that was the larger problem: at a dead run, triangles
detached from the Gub's back and hung in the air behind it.

**A number first.** "It tears" is not something you can fix twice and compare,
so `tools/rig_report.py` runs the same linear-blend skinning the GPU runs, over
every clip at 60fps, and reports four things: how far mesh edges stretch, the
third derivative of vertex motion (which spikes at a bad keyframe and at nothing
else), the gap between a looping clip's first and last pose, and how differently
the left and right halves are bound. On the asset as it shipped, 19% of vertices
sat on an edge that stretched past 1.5× its rest length.

Ratios turned out to be a poor headline: the mesh has edges a fifth the median
length, where half a millimetre of drift reads as "6×". The metric that matches
what an eye sees is edge growth measured against the body's own size, and that
is what `torn` counts.

**What was actually wrong.** Seven of the twenty-nine bones — `breast.L/R`,
`pelvis.L/R`, `heel.02.L/R` and `spine.005` — rotate by exactly 0.0° in every
clip. They are Rigify helpers, meant for posing and never for deforming.
Automatic weights does not know that and gave them 19% of the mesh, including a
band of chest either side of the armpit. That band stayed welded to the ribcage
while the vertices beside it, bound to `upper_arm.L`, swung through 89°. That
one boundary was the worst edge in the file, at 99× its rest length.

The same blindness bound the right heel to `heel.02.R` and the left to `foot.L`,
so the two feet deformed differently — one bending at the ankle, the other
pivoting around a point behind it.

**What replaced it** (`tools/rig_clean.py`). The helpers are unbound and the
skin is computed rather than painted: label each vertex with the nearest bone
*segment*, then delete any label region that is not connected across the surface
to the bone it names — the chest can only reach the arm bone across open air, so
that label is a lie — then diffuse the labels by solving `(A + a L) W = A P` with
the cotangent Laplacian. Clamping the cotangent weights at zero keeps that an
M-matrix, which is the guarantee that no weight overshoots into [0,1]; and since
`L` annihilates constants, the rows sum to exactly 1 with no renormalising.
Finally left and right are averaged so the Gub deforms symmetrically.

`spine.005` is deliberately left bound. It is as motionless as the rest, but it
is a link in the neck chain rather than a helper hanging off one, and binding it
is what makes the neck's falloff graded instead of a step halfway up.

**The bind is solved on the decimated mesh, not transferred onto it.** This
reverses part of D-003. A nearest-source-vertex transfer of a smooth weight
field does not arrive smooth — doing it that way put back a tenth of the tearing
this removes — so `decimate_assets` now carries only UVs across and binds the
finished 18k-triangle geometry directly. The seam-aware transfer still earns its
place for UVs, which genuinely are per-corner data with no other source.

**Three more things were wrong with the curves**, beyond D-008's three:

- **Quaternion sign flips**, 44 of them. A quaternion and its negation are the
  same rotation and the exporter emits both; between two keys that straddle the
  sign, interpolating the *numbers* takes the long way round the sphere.
- **Corrupted keyframes.** `toe.L` in `SlowRun` turns 155° in one 60th of a
  second and comes back — an axis flip in whatever produced the bake.
  `forearm.L` in `Jump` holds still to within half a degree for five frames and
  then leaves at 51° per frame, a pose snapped in with no ease at all. Both are
  the same measurement: an angular acceleration nobody authored. Keys are eased
  back toward the local trend only in proportion to how far past a per-track
  threshold they sit, so ordinary motion is left bit-identical — the median
  acceleration across every track is unchanged at 1.87°, while the worst falls
  from 122° to 18°.
- **Two thirds of every clip was dead.** 474 of 696 channels never leave the
  rest pose — every `scale` track, and every `translation` but the root's. And
  because Blender bakes from frame 1, each clip's first key sat one frame in,
  so a looping clip held its opening pose an extra 60th of a second every time
  round: a stutter once per stride at a 32-frame sprint.

**`Crouch` was the T-pose.** It shipped as two keyframes of the bind pose, so a
crouching Gub stood bolt upright with its arms out. There is no other crouched
motion in the file, so the pose is taken from `CrouchWalk` at the frame where the
skeleton is closest to its own mirror image — the passing pose, legs together —
rather than by guessing which frame of a cycle that is. Its ground position comes
from the clip's start, not from that frame, or the still pose would stand a
stride and a half to one side of the body carrying it.

**Result**, on the shipped `art/generated/gub.glb`:

| | before | after |
|---|---|---|
| edges torn (grown >2% of body) | 1294 | 257 |
| worst edge growth | 7.66% of body | 4.42% |
| worst vertex jerk | 0.419 | 0.119 |
| worst angular acceleration | 122.4°/frame² | 18.5° |
| worst single-frame turn | 154.7° | 45.9° |
| quaternion sign flips | 44 | 0 |
| animation channels | 696 | 222 |
| file size | 2.17 MB | 1.97 MB |

What none of that proves is that it *looks* right, so it was also checked by eye
in Godot at the worst frame of each clip. The flying triangles are gone; the hip
reads as one surface; the crouch crouches. The remaining 257 torn edges are at
the outside of hard bends, which is where linear-blend skinning always loses and
where the fix is a corrective shape, not a better weight.

## D-024 — The `Combat` node belongs to the host, not to the Gub around it
The first real playtest found that **a non-host player's abilities happened for
nobody** — not for the other players, and not even for themselves. The thrower
saw their cooldown sweep, because that is predicted locally, and nothing else:
the spear stayed in their hand, no mushroom grew, no lure flew. The host's own
abilities worked perfectly for everyone, which is what made it look like a
rendering bug rather than a networking one.

Every non-host console said what was actually happening, three lines per press:

```
ERROR: RPC '_do_throw_spear' is not allowed on node
       /root/Arena/Players/Gub_565667163/Combat from: 1.
       Mode is "authority", authority is 565667163.
```

`MatchState._create_gub` calls `set_multiplayer_authority(peer_id)` on the Gub,
and that is recursive, so the `Combat` child was owned by the client too. But
`GubCombat`'s traffic runs in *both* directions: `_request_*` goes client → host
and is `any_peer` with a sender check, while `_do_*` goes host → everyone and is
`authority`. Godot checks an `authority` RPC against whoever owns the node it
**lands on**, so a broadcast from peer 1 arriving at a node owned by peer
565667163 is refused — on every machine, including the thrower's own.

So `_create_gub` now hands that one child back:
`combat.set_multiplayer_authority(1, false)`. It reads oddly next to D-004 until
you say the split out loud: **the owner decides *when*, the host decides
*whether*.** The node the deciding lands on is the host's. The alternative —
`@rpc("any_peer")` on the three `_do_*` methods plus a
`get_remote_sender_id() == 1` guard in each — works, but it makes three methods
carry a check that the authority system exists to make for them, and it would
leave `Combat` owned by a peer that never broadcasts anything from it.

Two things this did not touch, on purpose. The `MultiplayerSynchronizer` beside
`Combat` must keep belonging to the peer whose position it publishes, which is
why the call is non-recursive. And `Gub.is_local()` still asks the *Gub*, so
input, movement and the camera are unaffected.

**The lure's pull was the same bug wearing a different hat.** `Lure._catch` runs
on the host and told each victim's client to apply the pull with
`_pull_target.rpc_id(peer, ...)` *on the lure node*. An RPC is addressed by node
path, and a lure has no path two machines agree on: every peer builds its own
copy into `spawned_items`, and Godot disambiguates a duplicate name with a
counter local to that process. Before this fix the client had no lure at all and
the log said so —

```
ERROR: Node not found: "Arena/SpawnedItems/Lure" (relative to "/root").
ERROR: Invalid packet received. Requested node was not found.
```

— and after it, two lures in the air would have been enough to deliver a pull to
the wrong crystal. The message now lands on `GubCombat.apply_lure_pull`, because
`Players/Gub_<peer>/Combat` is a name both ends already have and is now owned by
the host, so it can stay an `authority` RPC with no guard. The host/victim split
from `Lure`'s header is unchanged, and `caught` still carries the whole victim
list, which is what `tools/combat_range.gd`'s `lure` mode listens to.
`ShieldMushroom` was checked for the same shape and has no RPCs at all.

**Why nothing caught this.** `net_loopback`'s kill stage kills the client by
calling `MatchState.report_kill` on the *host*, which never goes near
`GubCombat`. Eight green stages and a release tag, and no stage had ever asked a
non-host peer to *do* something. Stage 7 now does: the client throws a spear,
plants a mushroom and lobs a lure through the public `try_*` calls, and both
peers assert the three items exist and that the spear left the client's hand —
which is the host's broadcast arriving, not local prediction. The throw is short
enough that the thrower is inside its own lure's radius, so the same stage
exercises the pull travelling back the other way. `net_test.sh` also fails a peer
outright on `is not allowed on node` now, because Godot prints that on the
*receiver* and carries on, so the sender is told nothing and the damage surfaces
somewhere else entirely.

That is the same lesson as D-018 and D-019 with a new seam: **a harness proves
what it exercises, and this one was exercising only the host.**

## D-025 — The spear leaves the hand at the animation's release, not at the click
*Still the design. The number moved: the release is 0.71 s into the new throw clip,
not 0.57 s, and it is derived rather than measured by hand — see **D-029**.*
The first playtest's complaint was "it throws and then the animation comes in
later". It was right, and it was the wrong way round: `try_throw_spear` spawned
the projectile on the frame of the click and fired the `SpearThrow` OneShot
underneath it, so the spear was already twenty metres away while the Gub was
still drawing its arm back. Nothing about the throw could be *timed*, either —
the aim was sampled on the click, so a target that ran during the animation was
hit anyway.

So the click now starts a windup and the spear leaves at
`GubCombat.THROW_RELEASE_TIME`, **0.57 s** later, with the aim read at that
moment and not before. In the designer's words, you have to time it out: a Gub
that walks during your windup has to be led.

**Where 0.57 comes from.** Not from taste. `SpearThrow` is 1.53 s, and the
`hand.R` bone tracked against the spine through an `AnimationPlayer` says the
arm draws back until 0.39 s, whips up over the shoulder to its highest at
0.54 s, crosses in front of the body at 0.55 s, and reaches furthest forward at
0.60 s. A thrown object separates at peak forward hand speed, which is the
0.54-0.60 s stretch; by 0.60 the hand is already decelerating and a release
there would read as a push rather than a throw. `tools/preview_anim.tscn` takes
an optional `from`/`to` window now, so a contact sheet can be made of that sixth
of a second instead of of the whole clip — six evenly spaced Gubs across 1.53 s
put one sample anywhere near the release, which is not enough to pick a frame
off. The OneShot's 0.10 s fade-in needs no allowance on top: the clip barely
moves for its first 0.21 s, so the blend has long finished before anything the
eye is following depends on it.

**Four consequences, and they are the interesting part.**

- *The windup is a broadcast of its own.* A tell only the thrower can see is not
  a tell. The thrower plays the animation on its own click; the host relays a
  cosmetic `_do_throw_windup` to everyone else, and the thrower's copy of that
  relay returns early on `_gub.is_local()` — replaying it half a round trip in
  would snap the arm back to the start of a throw it was in the middle of.
  `_do_throw_spear` no longer calls `play_throw()` at all, for the same reason.
  The relay is deliberately **not** gated on the host's cooldown: it is
  cosmetic, and a Gub that winds up and produces no spear is an honest picture
  of a client that asked for a throw it could not have.
- *The cooldown starts at the click, and the HUD had to be told.* The input is
  spent either way, and a crosshair that sits ready through half a second of
  windup only invites the second click that will be refused. The local
  prediction is therefore `THROW_RELEASE_TIME + spear_recharge`, and the HUD
  divides by `GubCombat.spear_cycle()` rather than by the recharge alone —
  otherwise the ring pegs at full through the windup and then jumps, which reads
  as a stall rather than as a throw being made. The host's
  `_server_spear_ready_at` still starts when the throw actually happens, and the
  two land on the same instant.
- *The held spear stays in the hand until the release.* `HeldSpear`'s header
  says an empty hand is how other players read that you are harmless, so the
  timing has to be honest: the hand empties at 0.57 s, when the spear really is
  gone, and not on the click.
- *A windup can be cancelled.* Dying, being respawned, or losing ownership
  mid-windup drops the throw — the animation is left to fade out on its own,
  because it is cosmetic, but no spear comes out of it. `reset()` clears a
  pending one along with the cooldowns.

**What it cost the harnesses.** `tools/smoke_test.sh`'s "spear kills" check
snapshots `combat_range` in `hit` mode, which clicks on tick 20; the spear now
appears on tick 55 and the kill lands on tick 75, so that warmup went from 70
ticks to 110. The old count would have failed with a message that reads exactly
like a broken throw. `tools/net_loopback.gd` needed no change at all — its stage
7 waits on the spear *existing*, with a 20 s timeout, rather than on a frame
count. That is the difference between a harness that waits for an outcome and
one that waits for a clock, and only one of them survives a timing change.

## D-026 — Single jump and double-tap dive, and why the old one froze
*Still the design, on a rebuilt graph. The clips, the windows and the freeze-proof
rule are **D-029**; the input design and the serial-not-flag pattern below are
unchanged.*
The same playtest reported two things that turned out to be one thing: "the dive
plays one time in a hundred", and "there is a weird position the jump goes into
that isn't the actual animation".

`Jump` is 2.37 s and was never a jump. It is a full dive — leap, tumble, roll,
stand up — and D-008 already measured it arcing 12.6 m forward and 3.0 m up
before the pipeline locked the root joint. It sat as input 1 of the `grounded`
Blend2 as a plain `AnimationNodeAnimation`, and **an animation node inside a
blend runs its own clock from the moment the tree starts**, whether or not
anything is blending toward it. So the first jump of a match caught the clip
somewhere near its beginning and looked more or less right, and 2.37 s into the
round the clip reached its last frame and stopped there for good. Every later
jump showed one frozen pose from the end of a dive. It was never one jump in a
hundred working — it was the *first* one, and nothing after it.

The fix is two clips out of the one file, and that is the design change:

**A single jump is the take-off only, and it restarts.** The airborne node uses
a custom timeline over 0.34-0.50 s of `Jump` — the push-off, and the legs coming
up under the body — with `stretch_time_scale` off so it plays at authored speed
and `loop_mode` none so it runs out and *holds*. 0.00-0.30 s is the anticipation
crouch, which has already happened by the time the Gub is off the ground; past
0.50 s the clip pitches over into the dive it really is. An
`AnimationNodeTimeSeek` in front of it is driven to 0 every time the feet leave
the ground, so the sixth jump of a match is the same as the first.

That seek hangs off the grounded→airborne *transition* rather than off
`Gub.jumped`, on purpose: `jumped` fires only on the owning client, while
`is_grounded()` reads the replicated `sync_grounded` on everyone else's screen.
One code path then covers the Gub you are driving, the seven you are watching,
and stepping off a ledge.

**A double jump is the dive, whole.** Press jump while already airborne, once
per airtime, and the Gub commits: `DIVE_FORWARD_SPEED` (9.5 m/s, well above
RUN_SPEED, or it would be a worse way of running) along the wish direction — or
the facing, if you are asking for nothing — plus `DIVE_UP_VELOCITY` (5.4 m/s,
enough to keep it airborne long enough for the leap to read, not enough to clear
the treeline). No further air jumps until the feet touch anything at all, and
the flag comes back on landing and on respawn. The lure still blocks it, because
the lure is meant to feel like being grabbed.

The gate is `_coyote <= 0.0`, which is what makes a double-tap on flat ground
jump first and dive second rather than dive twice: coyote time is still running
for the twelfth of a second after walking off a ledge, and is zeroed by a jump.
An airborne press past that point dives instead of going into the jump buffer.
That costs the buffer exactly one press per airtime, which is the price of the
ability having a button at all.

**Remote Gubs see it because a number changed, not because a message arrived.**
`Gub.sync_dive_serial` is an `int` on the existing `MultiplayerSynchronizer`
(spawn, on-change), bumped once per dive; `GubAnimator` fires the dive OneShot
whenever the value it last acted on stops matching. A counter and not a flag,
because a bool that goes true and false again inside one replication tick
arrives as no change at all, and two dives in a row have to be two dives on
every screen. No new RPC, and one code path for the local Gub and the remote
ones — the pattern `sync_grounded` already set.

The one place the clip and the physics cannot be reconciled is the landing. The
dive clip is 2.37 s and a dive is airborne for well under a second, so its
tumble-and-recover half can never line up with a real touchdown; the OneShot is
faded out on landing rather than left to play a ground roll on top of a run
cycle.

Noted here and deliberately not fixed: `Crouch` is a two-keyframe held pose.
That is an art limitation, not a fault in the graph.

## D-027 — Readability passes: the name shrinks, the spear is lit, the landing is drawn
Three complaints from the same playtest, all of them about what the player can
*see* rather than about what the game does.

**"That's the biggest bug right now is you can't see the spear."** Part of that
was the throw RPC and is fixed elsewhere. The rest is that a thrown stick is a
thin, dark, fast object in a night forest, and nothing about it was loud. Three
changes, in order of how much each one bought:

- The trail is twice as long — `SpearTrail.SAMPLES` 12 → 24, which is 0.4 s of
  flight and about seventeen metres — nearly twice as wide (`HALF_WIDTH` 0.055
  → 0.09), and warm instead of pale blue. The colour mattered more than
  expected: the old streak sat in the same range as the sky and the fog and was
  swallowed by both, while every other thing in this game worth looking at is
  torch-coloured. Its brightness falls off as `t^1.4` rather than `t²`, because
  squared put the whole ribbon in its front quarter and made the extra length
  decorative. It is still one additive draw call and still shortens to nothing
  0.4 s after impact.
- The projectile is lit in flight and unlit the moment it stops. This is
  smaller than it sounds, because of something worth writing down about the
  art: **every model in `art/generated` has a black albedo and a pre-shaded
  emission texture**, so a Gub and a spear are already made entirely of
  emission. There is no glow to add, only one to turn up, and it has to be
  turned up through `emission_energy_multiplier` — the materials' emission
  operator is multiply, so giving one a warm colour *darkens* its blue instead
  of warming it. `GLOW_BOOST` is 3.0, tuned by eye rather than by theory: the
  environment tonemaps ACES at a white point of 6.0, and at the 1.25 that
  sounded right on paper the spear was indistinguishable from an unlit one. A
  copy of the material per projectile, freed with it, the way `GubRagdoll`
  copies materials to fade a corpse.
- The glow comes off in `_stick` and `_stick_in`. A spear in the dirt and a
  spear through a corpse are scenery and have to read as scenery; leaving them
  lit would make every miss a beacon and every body a lamp.

**"I wish I knew where my spear was going, does it have drop?"** It does — a
third of world gravity — and no crosshair can answer that question, because the
crosshair is a point on a ray and the spear flies a parabola. So the answer is
drawn in the world: `scripts/player/aim_marker.gd`, a ring on the ground where a
spear thrown right now would land, shown only while the aim button is held and
only for the Gub you are driving. Local, cosmetic, and nowhere near the network.

Two things about it are load-bearing. The first is that the path is not a
closed-form parabola but the projectile's *own* integration loop — same speed,
same gravity, same mask, same exclusion of the thrower, and crucially the same
step, because Euler integration is step-size dependent and predicting at 30 Hz
would put the ring metres from where the spear actually lands. The second is
that a flat ring alone does not work. It is seen from eye height along a nearly
flat throw, which foreshortens it to a line about one pixel tall at the ranges
anybody throws from; the first render of it looked like nothing at all. What
makes it visible is the low band standing up off the ring's rim — a vertical
surface is never edge-on to a camera roughly level with it.

It is gated on the aim button rather than always on, deliberately. Judging the
arc is where a lot of the skill in this fight lives (D-014, D-025), and a
permanent marker turns the throw from something you read into something you line
up. Holding the button is the price of the answer, and it costs the wider field
of view while you ask.

`tools/combat_range.tscn` gained an `aim` mode for it: it holds the button at
the far wall and never throws, which is a state no other mode here spends a
single frame in, because every other mode's job is to get the projectile out of
the hand. It aims deliberately off the centre line — straight down it the spear
meets Dummy 1 at fourteen metres and the ring is drawn on a Gub's chest, which
proves the marker works on players and shows nothing about drop — and it prints
where the ring landed, so a run says something without anybody opening the PNG.
Aimed at a wall 43 m away it reports the spear coming down on open dirt at 23 m,
19.8 m short and 1.2 m low. That number *is* the answer to the question.

**"The names are too big."** `Nameplate` was `fixed_size`, which pins a label to
a constant number of screen pixels at any range. That reads as correct in a
screenshot and wrong in motion: a name across the island was exactly as large as
the name on the Gub beside you, so a crowd came out as a wall of identical
floating text with the players somewhere behind it. Perspective is the cue that
says which name belongs to which body, and it was the one thing being thrown
away. The plate now has a size in the world — `FONT_SIZE * PIXEL_SIZE`, about
0.21 m tall, so a six-letter name is roughly the width of a Gub's shoulders —
and it shrinks and grows with the Gub like everything else.

Two consequences. The fade came down with it, from 34-46 m to 20-28 m: at a
fixed screen size the old numbers were honest, but in perspective a name at 34 m
is four or five pixels tall and is no longer a name, it is a smear saying
"somebody is over there", which the Gub's own silhouette already says for free.
Fading it out where it stops being readable is the same decision the old numbers
made, applied to a plate that now has a size. And `GubBackdrop` lost its
`plate_scale`: it existed to shrink lobby plates by 0.60 and 0.40 because those
formations are shot at 42 and 36 degrees against the game's 75, and a fixed-size
plate does not care how wide the lens is. A plate with a world size does — the
narrow lens magnifies the name and the Gub under it by exactly the same amount —
so the two now stay matched with nothing to tune. The lobby renders
pixel-for-pixel the same as it did with the correction in place, which is the
proof that the correction was only ever undoing the bug.

**Corpses, one line.** `GubRagdoll.LINGER` 9.0 → 2.5 s and `FADE` 1.6 → 0.8 s.
All of the value in a ragdoll is the flight, and the flight is over in about a
second and a half; after that a body is clutter, and at eight players with a
three-second respawn the corpse from your last kill was still lying between you
and your next one. `tools/smoke_test.sh` moved its ragdoll grab from tick 160 to
155, which is now a narrow window with a reason at each end: `ragdoll_stability`
does not print its verdict until tick 150, and the corpse starts fading at 160
and is gone by 208.

## D-028 — The host runs a tunnel, so that nobody else has to install anything
Until now the only way to play this across the internet was `docs/PLAYING.md`'s
first instruction: *everybody* installs Tailscale, makes an account, and joins
one tailnet. That works — D-005's code carries whatever address `select_ipv4()`
picks, and a tailnet address is a real routable address that reaches both across
the country and across a shared LAN. It is also five people's setup before
anyone throws a spear, and the free plan caps at six people against a lobby cap
of eight, so a full game needed a paid seat.

The designers' framing was the whole design: *"then only the host has to set
up"*. The host is already the person doing something different from everyone
else — they open the lobby, they read out the code — so they are the right
person to carry the cost. Everyone else should download one `.exe` and paste
ten characters, which is what they were promised in the first place.

**What was added.** A persisted setting, `public_address`, a String, default
`""`, edited in Settings → Network. The host puts the address of a
[playit.gg](https://playit.gg) UDP tunnel in it — `angry-gub.at.ply.gg:41235` —
and when the lobby opens, `Net.invite_code()` encodes that endpoint instead of a
local one. `invite_scope()` says `INTERNET (PLAYIT)`. Blank is the old
behaviour exactly, tailnet and LAN and all, which is what everybody who is not
hosting will always have.

playit was chosen over the obvious alternative of "tell the host to forward
UDP 27015 on their router" because port forwarding is unavailable to a growing
share of players (carrier-grade NAT), is different on every router, and cannot
be checked from inside the game. A tunnel agent is one download, and it either
says connected or it does not.

**The local port is fixed at 27015 and the public port is not.** playit
allocates the outside port; the inside port is whatever the host configures the
agent to forward to. Making the game bind whatever the tunnel's public port
happens to be would be backwards — the two numbers are on opposite sides of the
tunnel and nothing connects them. So the game keeps binding `DEFAULT_PORT`, the
docs require the tunnel's local port to be 27015, and the *public* port is what
goes in the code. That is the one setup step a host can get wrong in a way the
game cannot detect, which is why it is in a table in `docs/PLAYING.md` and in
the caption under the settings field.

**Why the code carries the resolved IP and not the hostname.** The tempting
change is to widen the invite code so it can hold `angry-gub.at.ply.gg` and let
the joiner resolve it. We did not, for three reasons:

1. **Six bytes is the format.** Four for the address, two for the port, which is
   exactly ten Crockford characters with no padding — every code the same
   length, which is most of what makes a code readable down a phone line
   (D-005). A hostname is 20-ish bytes and variable, so codes become long,
   variable-length, and no longer the thing this project promised.
2. **The lookup belongs on the side that can report it.** Resolving on the
   host means one machine does it, once, at a moment when there is a lobby
   caption to say it failed. Resolving on the joiner's side means every joiner
   does it, in the middle of a dial, where a DNS failure is indistinguishable
   from a host who is not there.
3. **playit's addresses are stable per region.** The hostname resolves to a
   playit anycast IPv4 that does not move under a live tunnel.

The known risk, stated plainly: **if playit re-homes a tunnel to a different
IP, every code already handed out points at the old one.** The fix is the fix
for a stale code, which this game has always had and already documents — the
host reopens the lobby and reads out a fresh one, and reopening is what
re-runs the lookup. Nothing new to learn, and the same failure the LAN path has
when a DHCP lease changes.

**Resolution happens once, when the port is bound — not in `invite_code()`.**
`IP.resolve_hostname` blocks for a DNS round trip, and `lobby.gd::_refresh_invite`
calls `invite_code()` on every roster change. Resolving there would freeze the
lobby for a moment every time somebody joined, readied up, or switched team. The
tunnel's address does not change while a lobby is open, so it is resolved in
`host_lobby()` and cached with the port for the life of the session.

**Parsing is separate from resolving, and static.** `Net.parse_public_address`
takes a String and returns `{host, port}` or nothing: it strips whitespace
anywhere (this arrives via a clipboard), demands exactly one colon and a port in
1..65535, and touches no network. That makes it exhaustively testable with no
socket, which is what `tools/invite_codes.gd` does with it — a valid address,
whitespace in four places, an IPv4 literal (accepted with no lookup at all), and
fourteen kinds of rubbish including a URL, an IPv6 address, and a bare hostname
with no port. `Net.is_ipv4_literal` does double duty: it skips the resolver for
a host who typed an IP, and it checks what came *back* from the resolver, since
a well-formed IPv6 answer will not fit in four bytes and has to be refused
rather than truncated.

**Failure is loud, because the fallback is silent.** A public address that does
not parse or does not resolve falls back to the local address, which produces a
perfectly valid code that simply does not leave the building — the exact shape
of failure D-005's address selection was written to avoid. So `invite_problem()`
returns a line, and the lobby prints it *instead of* the scope caption:
`PUBLIC ADDRESS DID NOT RESOLVE — USING LAN`. There is one line of space there
and this is the more urgent thing for it to say.

**Nothing changed on the joining side, and that is the point.** A resolved
playit anycast address is four bytes and a port, which is what
`ENetMultiplayerPeer.create_client` has always been given; ENet speaks plain UDP
to whatever it is pointed at, and a tunnel is transparent to it. The seam
`docs/ARCHITECTURE.md` describes did not have to move.

**One trap in the tooling.** Godot keys its user data directory on the project
*name*, not the path, so every checkout and every process of this project shares
one `user://settings.cfg` — the thing that already forced `tools/net_loopback.gd`
to set player names explicitly. `public_address` lands in that same file, so a
developer who has set up a tunnel for a playtest would find `tools/net_test.sh`
resolving their tunnel's hostname over real DNS and encoding a public endpoint
into a loopback test. `Net.ignore_public_address` exists for that, set by the
harness before it hosts. Turned off explicitly rather than by clearing the
setting, because clearing it would write to the file the person running the test
is about to host a real game with.

## D-029 — The Gub was rebuilt from eight Mixamo clips, and its animator was rebuilt around them
Two playtest complaints, one root: "the transitions are poor" and "you never see
the whole jump or the whole slide". D-026 had already found the mechanism for
half of it — an `AnimationNodeAnimation` inside a blend runs its own clock from
tree start and freezes on its last frame — and fixed it for the jump by carving
a 0.16 s slice out of a 2.37 s dive. The slide had the identical bug and nobody
had looked. Behind both sat an asset that could not give a better answer: one
`Gub.glb`, an 18k decimation of a 500k-triangle photogrammetry mesh on a
hand-made Rigify rig, carrying eight clips — one of which had shipped as the
bind pose where a crouch should be (D-023), and one of which was a whole dive
where a jump should be (D-026).

So the instruction was to replace the asset and **not to base the new
implementation on the old one**. Both halves of that happened, and this entry is
the record of what the new source actually turned out to be, which was not what
anyone assumed. The retired source, `assets/source/Gub.glb`, is deleted from the
tree in the same commit: nothing builds from it any more, and git history has it
if D-008 or D-023 ever need re-reading against the file they describe.

### The source, and the one script that builds it

`assets/source/GUB_2/` holds eight Mixamo FBX files — same character, same mesh,
one clip each at 60 fps, a 2048² base-colour JPG packed in every file. All eight
agree on 8814 vertices, 49 bones, 40 vertex groups and a bind pose identical to
a matrix delta of **0.0**, which is what makes consolidating them into one
armature legitimate rather than hopeful.

`tools/build_gub.py` (Blender 5.2, headless, 1303 lines) does the whole
conversion and prints every measurement it takes, in the style
`tools/decimate_assets.py` established. `bash tools/build_gub.sh` locates
Blender the way `tools/find_godot.sh` locates Godot. Three consecutive runs
produce a **byte-identical** `art/generated/gub.glb`, so "rebuild it and see" is
a real answer to a question.

Three things in that script exist only because Blender or the exporter lied
first:

- **Blender 5.2 actions are layered and slotted.** `action.fcurves` does not
  exist; the curves are at `action.layers[].strips[].channelbags[].fcurves`.
  Every loop in the script goes the long way round for that reason.
- **Applying an armature's scale does not scale its pose-bone `location`
  fcurves.** The mesh comes out 1.80 m tall and the root motion stays at a fifth
  of it, so the Gub travels a fifth of the distance its feet do. 960 location
  fcurves are multiplied by the armature-local factor **1.903149** by hand at
  the moment the transform is applied. Every measurement is then re-derived at
  scale before anything is stripped — Run's hips travel 1.941 m in 0.450 s,
  JumpOne's reach 1.120 m at 0.750 s — so a scale mistake fails loudly instead
  of shipping.
- **The extracted texture is named after the image's *filepath*, not its
  datablock.** Renaming the datablock to `basecolor` was not enough; the first
  build produced `gub_cartoon+monster+3d+model_basecolor.jpg`. The script sets
  `image.filepath_raw = '//basecolor.jpg'`, and because the embedded image stays
  JPEG the file Godot extracts is **`art/generated/gub_basecolor.jpg`**, not the
  `.png` everyone including the spec expected.

The old `art/generated/gub_shaded.png` is deleted, `tools/rig_clean.py` and
`tools/rig_math.py` with it, and `tools/decimate_assets.py` — which is now three
unskinned props and nothing else — raises rather than silently discarding a rig
if a source ever turns out to be skinned.

### The clips

Nine, not the eight that arrived: `CrouchIdle` is synthesised from `CrouchWalk`
frame 37, the passing pose, after root-motion locking so its hips sit at the
origin. Lengths are what Godot reports; the four cycles are one frame shorter
than the source because the duplicate tail key is dropped (`DROP_LOOP_TAIL`), or
the loop holds its first pose twice.

| clip | length | loops | authored speed | playback rate in game |
|---|---|---|---|---|
| `Idle` | 4.15 s | yes | 0 | 1.0 |
| `Walk` | 1.233 s | yes | **1.079 m/s** | 2.1316 |
| `Run` | 0.433 s | yes | **4.314 m/s** | 1.2517 |
| `CrouchWalk` | 1.117 s | yes | **1.273 m/s** | 1.2569 |
| `CrouchIdle` | 1.000 s | yes | 0 | 1.0 |
| `Slide` | 1.767 s | no | 3.9→1 m/s | 1.0 |
| `JumpOne` | 1.883 s | no | 0 (in place) | scrubbed |
| `JumpTwo` | 2.367 s | no | leaps 4.6 m | scrubbed |
| `Throw` | 3.833 s | no | steps ~0.9 m | 1.6 |

**Every clip faced a different way**, which is D-008's problem arriving a second
time on a completely different rig. The build measures each clip's facing by
forward kinematics — the yaw of the `LeftUpLeg`→`RightUpLeg` line in world space
— against the rest pose measured identically, and pre-multiplies the Hips
`rotation_quaternion` keys by the compensating yaw about the bone's local +Y.
The corrections are not small: Idle **+50.96°**, CrouchIdle +39.48, JumpOne
+38.20, CrouchWalk +37.74, Slide −35.58, JumpTwo −19.19, Throw +17.59, Run
−6.22, Walk +1.06. All nine now measure **0.00°** residual against the same
reference, and the build aborts above 1°. Motion *within* a clip is untouched:
the slide still turns 120° onto its side and the throw's torso still swings 162°.

**Loop modes are declared in the GLB, not in the `.import`.** `_subresources`
with `settings/loop_mode` does work — but Godot then rewrites `gub.glb.import`
with every default for every animation it names, all 256 `slice_N` blocks
apiece: **348,496 bytes instead of 1,137**, regenerated on every import, with
the answer to "does this clip loop?" split across two files. So the five cycles
are exported as `Idle-loop`, `Walk-loop`, `Run-loop`, `CrouchWalk-loop`,
`CrouchIdle-loop`; Godot's importer strips the suffix and sets `LOOP_LINEAR`.
`_subresources={}`, and `nodes/use_name_suffixes` must stay true or the clips
arrive with `-loop` still in their names. The single source of truth for which
clips loop is the `CLIPS` table in `build_gub.py`. Anything that reads the GLB
directly rather than through Godot has to strip the suffix, which is why
`tools/rig_report.py` has a `clip_base()`.

### The vertical rule: one clamp was right and one was catastrophic

Both jump clips rise — JumpOne's pelvis by 0.41 m, JumpTwo's by 0.57 — and the
physics capsule already performs that arc, so the first pass clamped the hips Y
to its first key in both. For **JumpOne**, a vertical hop, that is exactly
right: the legs tuck under a pelvis that stays put and the ballistic motion is
left to the body that is really doing it.

For **JumpTwo** it was a disaster, and the reason is that JumpTwo is not a jump.
It is a front somersault that plants its hands and rolls out. Pin the pelvis and
the inverted body rotates about a point 0.62 m too low: head and hands went
**0.41 m below the floor** from clip 1.00 to 1.60 s, and the dive touched down
upside-down. The raw clip is self-consistent — the hands reach the ground at
1.18 s *because* the hips are high.

    VERTICAL_RISE_KEPT = {"JumpOne": 0.0, "JumpTwo": 1.0}

The up axis is scaled toward the first key by `1 − kept`, so 0.0 is the old flat
clamp and 1.0 leaves the clip alone; only keys *above* the first key move, so
every clip keeps its landing absorb and ground roll either way. With the rise
kept, JumpTwo's hips top out at **0.900 s** at 1.293 m (0.618 m above the first
key), the hands take the ground at **1.183 s** and stay down until 1.833, and
the feet arrive at 1.530. Those are the numbers `JUMP_TWO_APEX` and the roll
window are read off.

**The build now refuses to ship a clip that goes through the floor.** After
processing, `check_ground()` samples every bone head over each jump, prints the
deepest one either side of the frame the hands plant, and aborts against a
per-clip `FLOOR_LIMIT`. A companion `check_tables()` refuses a build whose rule
table names a clip that is not built, or a clip with no limit.

| | JumpOne | JumpTwo |
|---|---|---|
| deepest joint, shipped | −0.141 m (`LeftToe_End`, 0.583 s) | −0.167 m (`RightHandThumb4`, 1.400 s) |
| deepest joint while airborne | — | −0.103 m (1.183 s) |
| deepest joint if clamped | — | **−0.410 m** (1.167 s) |
| `FLOOR_LIMIT` | −0.15 | −0.20 |

`FLOOR_LIMIT["JumpTwo"]` is −0.20 and not the −0.08 that was asked for, because
**no build of this clip can meet −0.08**: the *authored* ground roll takes a
knuckle to −0.167 m at 1.400 s, and those hips keys are below the clip's first
key, which the vertical rule deliberately never touches. The first run with
−0.08 aborted correctly and refused to write the GLB, which is how we know the
check works. −0.20 still bites: a clamped JumpTwo measures −0.410.

### The graph, and the one sentence that makes D-026's bug impossible

`scripts/player/gub_animator.gd` is a new `AnimationNodeBlendTree` built in
code. The rule it is built to is written at the top of the class:

> **Ground poses come from speed, air poses come from the arc, events are
> one-shots.** Nothing in the tree runs a clock that is not either a looping
> locomotion cycle, a OneShot that restarts on fire, or a node that is scrubbed
> every frame.

```
stand    BlendSpace1D  Idle @ 0 | Walk @ 2.3 | Run @ 5.4      (positions in game m/s)
crouch   BlendSpace1D  CrouchIdle @ 0 | CrouchWalk @ 1.6
stance   Blend2(stand, crouch)
air_one  TimeSeek -> JumpOne    scrubbed to an absolute clip time every frame
air_two  TimeSeek -> JumpTwo    scrubbed every frame
air      Blend2(air_one, air_two)     1 while this airtime contains a dive
grounded Blend2(stance, air)
slide -> land -> roll -> throw  four chained OneShots; throw filtered to 37 upper-body bones
```

Every locomotion node carries its own rate in a custom timeline
(`timeline_length = length / (game_speed / authored_speed)`,
`stretch_time_scale = true`, node-level `LOOP_LINEAR`), so the feet stay planted
without a global TimeScale node and without the `.import` having an opinion.
That replaces `SPEED_SCALE`, `JOG_SPEED` and `AUTHORED_JOG`, which are gone.

**The airborne clips are indexed, not played.** JumpOne is 0.35 s airborne
against a 0.70 s physics jump, so a clock can never agree with the body:

    phase = clamp(0.5 * (1 - vy / v_launch), 0, 1)    # 0 leaving, 0.5 apex, 1 about to land
    t     = phase < 0.5 ? lerp(START, APEX, phase / 0.5)
                        : lerp(APEX,  END,  (phase - 0.5) / 0.5)

    JumpOne  START 0.68  APEX 0.83  END 0.95    v_launch = JUMP_VELOCITY (9.0)
    JumpTwo  START 0.58  APEX 0.90  END 1.48    v_launch = vy when the dive serial changed

`JUMP_ONE_START` is 0.68 rather than 0.60 because the push-off frames before it
extend the legs 0.13 m below the floor and the physics take-off is instant
anyway. A Gub that walks off a ledge has vy ≈ 0, so phase *starts* at 0.5 — the
apex pose — and falls through to the pre-landing pose. Falls are covered by the
same mechanism with no extra clip.

**The trap in that rule, which only a trace found:** `move_and_slide` zeroes vy
on touchdown, the arc reads vy = 0 as "apex", and the air pose snapped back to
the top of the leap on the landing frame — a **0.48 m hip pop** on every
landing. A grounded Gub now holds the about-to-land pose instead; the residual
bump is 0.14 m.

**Every unweighted cycle was frozen at phase 0.** `sync = false` on the two
BlendSpace1Ds and the three Blend2s meant a node nothing was blending toward did
not advance, so the sprint entry cross-faded a *static* Run frame into a
mid-stride Walk — the same class of defect as D-026, one layer up. Measured on
the shipped tree: after 1.5 s of walking, `parameters/stand/{idle,walk,run}` and
`crouch/{still,walk}` all read `current_position` **0.0000**. With `sync = true`
they read 0.2816 / 0.0540 / 0.5503 and advance. (`sync` is the legacy alias:
setting it true reads back as `sync_mode = INDEPENDENT`.
`SYNC_MODE_CYCLIC_MUTABLE` would go further and phase-*lock* them — measured at
26.4% against 26.5% of their own timelines — at the cost of the phase rate
stepping once as the blend crosses the midpoint. Not shipped; noted for whoever
tunes the sprint entry.)

The throw's window is `[0.50, 2.10]` of `Throw` at rate 1.6, and
`THROW_RELEASE_TIME` is now derived rather than tasted:

    (THROW_RELEASE_IN_CLIP - THROW_CLIP_START) / THROW_RATE = (1.633 - 0.50) / 1.6 = 0.7081 s

which is **42.5 physics ticks**, up from D-025's 0.57 s / 34 ticks on the old
`SpearThrow`. `gub_combat.gd` reads it from `GubAnimator`, so the number exists
once. The kill in `combat_range hit` lands about tick 83 of the 110-tick budget;
the lure's 132 is unaffected.

### Emission 0.15, because the new texture is not pre-shaded

The old asset was a pre-shaded emission texture and was always visible (D-027).
This one is a flat base colour with a Principled BSDF over it, and at night in
unlit undergrowth it measured **1.5×** the shadowed background — a brown smudge
at 20 m — while the still-pre-shaded spear in its hand stayed bright. The build
wires the base-colour texture into Emission Color at `--emission`, default
**0.15**:

| | 0.00 | 0.15 |
|---|---|---|
| distant Gub in unlit undergrowth, mean luminance | 21.7 | 38.9 |
| …as a ratio to the shadowed background | 1.51× | 2.71× |
| torch-lit Gub against the sky, mean luminance | 43.4 | 64.0 |
| …its *peak* luminance | 166 | 142 |
| clipped channels, either view | 0 | 0 |

The peak falling is the point: 0.15 lifts the shadow side into legibility
without flattening the shading gradient or turning the Gub into a lamp, and the
torch flames are still the brightest things in frame. At exactly 0 the emission
socket is left unconnected rather than wired to black — a wired-but-black
emission is a second texture sample per fragment that can never do anything.

### The hitbox follows the pose the clips actually strike

The new crouch is not a low pose. Measured silhouette heights: Idle 1.49 m,
**CrouchWalk 1.51**, Run 1.41, Walk 1.73 (the antennae). `CROUCH_HEIGHT` was
0.95, which left the whole chest and head outside the capsule and made a
crouching Gub's head **unhittable**. It is now **1.35**.

The slide is the opposite problem and is genuinely prone — the hips drop to
0.165 m — so `SLIDE_HEIGHT := 0.75` is layered on the crouch blend through a new
`pose_height()` that the capsule, `eye_height()`, `_has_headroom()` and
`_follow_network` all read, so a remote Gub is shaped like a local one.

| pose | capsule top | mesh top | eye height |
|---|---|---|---|
| idle / run | 1.55 | 1.427 / 1.412 | 1.33 |
| crouch | 1.35 | 1.499 | 1.16 |
| slide | 0.77 | 0.730 | 0.65 |

1014 of 8818 vertices are still above the crouch capsule — 602 of them the two
antennae and the crown of the head blob, 412 the raised right fist. That is
0.10 m of crown and 0.29 m of antenna, against 0.56 m of chest-and-head before.
For scale: **the old asset had 0.5 m of head outside its crouch capsule too**,
so this is not a defect that was introduced, it is one that was measured. The
capsule *radius* is unchanged at 0.38 m, so in every pose the spread feet and
out-held arms are outside it laterally — most obviously in the slide, where a
vertical capsule cannot follow a prone body at all.

### One number for the roll, shared by the rule and the animation

`ROLL_LOCK` (0.45 s of ignored input and gentle friction after a dive landing,
so the body travels with the roll instead of skating through it) is a new
gameplay rule, and it needed three coherence fixes:

- It outlived the floor. A dive that landed on a ledge and carried over its edge
  kept the lock in the air: no air control, and `ROLL_FRICTION` (10.0) dragging
  on the fall instead of `AIR_FRICTION` (1.5). Two reviewers found it
  independently. `_tick_timers` now zeroes `_roll_lock` the moment the feet
  leave the floor — the roll is a ground move, and a fall out of it is an
  ordinary fall.
- It armed on *any* landing, including a one-tick scuff off a kerb.
  `Gub.ROLL_MIN_AIRTIME := 0.20` now gates it, and the animator's
  `LAND_MIN_AIRTIME` is literally `Gub.ROLL_MIN_AIRTIME` — the rule and the
  animation cannot drift apart because there is one constant.
- The comment on `_handle_jump` promised that a jump pressed during the roll
  fires when the lock ends. It did not: the buffer decays in 0.14 s and the lock
  lasts 0.45. `_jump_buffered` is now frozen while `is_rolling()`. Measured:
  lock armed at tick 106, press at 112, jump fired at **134** — the first tick
  `is_rolling()` was false — at vy exactly 9.00. Before, that press was silently
  dropped at tick 120.

`Gub.vertical_speed()` returns `velocity.y` locally and `sync_velocity.y`
remotely, and feeds both the arc scrub and the dive launch speed. On a remote
Gub that is a tick fresher than `velocity`, because the synchronizer writes
`sync_velocity` before `_follow_network` copies it out.

**Respawn used to pin every remote copy airborne.** `revive_at()` ended with
`_publish()`, which sets `sync_grounded = is_on_floor()` — and on a remote copy
`is_on_floor()` is permanently false. The owner's own value never changed
(true→true), so ON_CHANGE replication never corrected it, and every other screen
showed a Gub falling on the spot. `revive_at` now seeds the replicated fields
field by field, `sync_grounded = true` among them, because a spawn pad is on the
ground.

### The spear was in the Gub's head, and the fix was 5 cm

The idle is a boxer's guard: the right fist sits beside the face. The first
grip, derived against a three-ellipsoid stand-in for the body, ran the shaft **in
under the chin and out above the crown** — nearest-skin distance 0.004 m, i.e.
through the surface — and in Walk the tip ploughed the ground at 0.004 m. The
stand-in was the error: the real belly is 0.37 m half-depth and the head 0.35 m
across.

Re-derived against the actual skinned mesh — 27 poses over the six clips the
spear is carried in, scoring the shaft's distance to the nearest
head-or-torso-weighted vertex:

    HAND_BONE      "RightHand"
    GRIP_OFFSET    (-0.206, -0.582, 0.097)
    GRIP_ROTATION  (-12, 0, -15)

A near-vertical Idle carry — shaft 81–86° above horizontal, 53° round from
forward toward the Gub's own right — with the fist 55% up the 1.236 m shaft so
the butt clears the ground when the arm hangs. `GRIP_OFFSET` is *derived*, not
free: it is the palm pass-point minus `0.55 × 1.236 ×` the shaft direction, and
it has to be recomputed if `GRIP_ROTATION` changes.

The 5 cm that matter are lateral. Passing the shaft 5 cm off the wrist axis
instead of through it is what takes it from grazing the face to 11 cm clear, and
5 cm is still inside the fist — the `RightHand`-weighted skin spans
x −0.083…0.085, z −0.065…0.065.

| nearest skin, metres | Idle | Walk | Run | CrouchWalk | CrouchIdle | Throw |
|---|---|---|---|---|---|---|
| before | 0.004 | 0.029 | 0.080 | 0.019 | 0.061 | 0.006 |
| after | **0.114** | 0.151 | 0.254 | 0.187 | 0.193 | 0.055 |

Walk and Run still point the tip *down* (−14…−42° and −43…−59°) and that is not
fixable with a rigid `BoneAttachment3D`: the hand's world orientation differs by
more than 100° between a raised guard and a hanging arm. What is fixed is the
tip in the ground — Walk's lowest shaft end went 0.004 → 0.234 m, and both ends
now stay at least 0.148 m up in every ground clip. Standing the shaft up in Walk
as well needs an animated or IK'd attachment.

### The ragdoll's headline defect was a material, not a joint

The corpse looked shattered: eyeball meshes apparently outside the head, black
self-intersecting seams, a shard-edged crumple. Every one of those is the same
bug, and it is not physics. **The corpse's materials were switched to
`TRANSPARENCY_ALPHA` at spawn.** An alpha material renders in the transparent
pass and writes no depth, so a closed body stops occluding *itself* — you were
looking straight through the skin at the inside of the head and the backs of the
eyes. The bodies were exactly where they belonged the whole time, which was
proven by dumping bone world positions: `RightHand` at
`(0.123545, 0.984243, -0.318786)` on the live Gub and on its corpse, to six
decimals. Corpse materials now stay opaque for the whole 2.5 s linger and switch
to alpha plus `DEPTH_DRAW_ALWAYS` at the first frame of the 0.8 s fade.

On top of that, real improvements that are not what fixed the picture: the 13
bodies of the new `SEGMENTS` table were refitted to the mesh's outer extent
(pelvis radius 0.329, chest 0.301, head 0.320 — the head is a third of the
character), which required **`MAX_RADIUS` 0.30 → 0.40 out of necessity, not
tidiness**: at 0.30 the pelvis and head were being silently clamped and the
refit had no effect at all. A p90 fit is right for a cylindrical limb and wrong
for three overlapping blobs, which is why the torso rows sit near the outer
extent while the hand and foot rows sit near the median — their splayed digits
double the p90. Total mass 39.0 kg, worst ratio 8:1.

**The neck is 35°/25° and the spine stayed at 45°, against a request for 30°
everywhere.** This is D-013's warning arriving on schedule — a cone-twist driven
past its limit adds energy rather than clamping — and the reason is measurable: a
corpse is snapped to the pose it died in, so any span below the bend the
*animation* already contains starts the joint outside its own limit. Idle alone
bends the neck 38°, Run 69°, JumpTwo 71°; JumpOne bends Spine1 49°.

| configuration | `ragdoll_stability` |
|---|---|
| head 60/50, spine 45 (first pass) | PASS but jittery — 1.46 m/s at settle against a 1.5 limit |
| head 45/25, spine 45 | PASS, 0.47 m/s |
| **head 35/25, spine 45 — shipped** | **PASS, 0.55 m spread / 0.76 m/s** |
| head 30/25, spine 45 | PASS marginally, 1.18 m/s |
| head 25/25, spine 45 | FAIL — 160 m/s at tick 121 |
| head 18/25, spine 45 | FAIL — 285 m/s at tick 33 |
| head 45/25, **spine 30** | FAIL — 123 m/s at tick 55 |

**And "settled spread 0.59 m for a 1.80 m body" was a misread metric, not a
crumpled corpse.** `ragdoll_stability`'s spread is the maximum distance of a body
from the centroid — a *radius* — so 1.0–1.5 m is geometrically impossible for
this rig, and anything over 1.5 fails the test outright. It reads 0.55 m, and
the corpse is prone: its thirteen body centres occupy 0.70 × 0.29 × 0.89 m,
about 1.4 m of skin on the ground once the capsule radii and the 0.36 m of skull
beyond the head body are counted.

Last, **every corpse faced backwards**, and had done since before this rework.
`GubRagdoll._adopt` copied `Model`'s yaw onto the holder, but the 180° turn that
makes `body_yaw` mean "the way the Gub is looking" lives on the `Model/gub`
*child* in `gub.tscn`. The whole chain is now composed, found by walking up from
the skeleton rather than by name.

### What this asset is worse at than the old one

`tools/rig_report.py` measures the new asset the same way it measured the old one
for D-023, and the honest answer is that **Mixamo's stock weights skin worse at
the neck and shoulder ring than D-023's solved bind did**:

| | old asset, after D-023 | new asset |
|---|---|---|
| worst edge growth | 4.42% of body | **9.81%** (Throw) |
| torn-edge instances | 258 over 8 clips / 28113 edges | **1061** over 9 clips / 19033 edges |
| left/right bind asymmetry (mean) | 0.762 | **0.219** |

The table it reports, on the shipped GLB — `stretch` is a multiple of rest edge
length, `jerk` is per frame as a fraction of body size, and the clip names carry
the `-loop` suffix because `rig_report` reads the GLB rather than Godot's copy of
it:

```
  binding
    8818 verts, 10542 tris, 49 joints; 7444 have a mirror twin within 2.0% of body size (84%)
    left/right asymmetry:  mean 0.219  p95 1.000  max 1.000   (0 = mirrored exactly)
    influences/vertex: [0, 2879, 2846, 2208, 885]   weights under 0.02: 4085

    clip           frames    dur  stretch    p99.9    torn%  jerk avg  jerk max loop seam
    Idle-loop         250   4.15     5.30     3.28   0.284%   0.00007   0.00518    0.0015
    Walk-loop          75   1.23     5.36     2.98   0.289%   0.00055   0.02100    0.0014
    Run-loop           27   0.43     8.00     3.38   0.336%   0.00413   0.18424    0.0114
    CrouchWalk-loop    68   1.12     7.53     5.01   0.720%   0.00081   0.08413    0.0040
    Slide             107   1.77    11.88     4.08   1.235%   0.00329   0.25157         -
    JumpOne           114   1.88     8.09     3.34   0.594%   0.00171   0.03444         -
    JumpTwo           143   2.37     7.22     3.12   0.678%   0.00684   0.16445         -
    Throw             231   3.83    11.88     4.00   0.856%   0.00051   0.02537         -
    CrouchIdle-loop    61   1.00     7.26     4.92   0.583%   0.00000   0.00000    0.0000
```

The `stretch` column is the ratio D-023 already warned is a poor headline: this
mesh also has edges a fifth of the median length, where half a millimetre reads
as "12×". Measured against the body's own size instead, the worst edge growth per
clip is Walk 4.00%, Idle 4.43%, CrouchIdle 6.55%, JumpOne 6.61%, CrouchWalk
6.74%, JumpTwo 7.01%, Slide 8.25%, Run 9.33%, **Throw 9.81%**. The loop seams are
all under 1.2% of body size, so dropping the duplicate tail key did not cost the
cycles their joins.

It is not the old failure mode — there are no detached flying triangles, and the
Idle sheet is clean. It is the jaw/chest ring, where a cartoon head sits straight
on the shoulders with no neck to grade the falloff, plus the hip ring in Slide:
the outside of a hard bend, where linear-blend skinning always loses and where
the fix is a corrective shape, not a better weight. The bind is markedly *more
symmetric* than the old solved one, and the figure is stable across pairing
tolerance, so that part is real. If the tearing turns out to be visible at
gameplay distance the fix is a re-solve or a corrective — and `tools/rig_clean.py`,
which is what earned the old numbers, is deleted.

(Two measurement footnotes for anyone comparing against an older `rig_report`
run. Its mirror-pairing tolerance is now 2% of the body diagonal rather than an
absolute 1 mm; at 1 mm the pairing found 0–1 vertices on *any* generated asset,
so the asymmetry row was statistics over one vertex. And the old asset's torn
count above is the adapted tool's own re-run on `HEAD`'s GLB, which reads 258
where D-023's table reads 257 — one edge, and worth knowing only so that nobody
goes looking for a discrepancy that means something.)

### Art limitations, kept on purpose

None of these are bugs and all of them are visible if you look for them:

- **`CrouchWalk`'s feet slip 53%.** At the game's 1.6 m/s crouch speed the
  stance foot still travels 0.849 m/s. Walk is 9.4% and Run 16.3%, which are
  fine; CrouchWalk is authored at 1.273 m/s and would need its rate nearly
  doubled to plant, for a 0.17 m/s gain. The clip is what it is.
- **`JumpTwo`'s ground roll is authored below the floor.** From clip 1.333 s on,
  the kept and clamped variants are numerically identical — those hips keys are
  *below* the first key, which the vertical rule never touches — and the skin
  reaches 0.247 m under the plane three ticks after a dive landing, recovering to
  ~0.10 m ten ticks in. It is a human-proportioned roll retargeted onto a body
  whose head is a 0.8 m blob. The air scrub hands over at 1.48, which is the
  most-sunk 0.15 s of the clip, so `ROLL_CLIP_START` is 1.62 instead — within
  0.10 m of the floor and closing (1.73 would be within 0.03 m) — at the cost of
  the first two frames of the tumble, which the touchdown's own impact hides.
  What remains is invisible from the chase camera, which looks down, and visible
  on a contact sheet.
- **The nameplate crosses the model at dive apex.** Keeping JumpTwo's rise puts
  the pelvis 0.618 m above the capsule at clip 0.90 s, and the plate is pinned to
  the capsule at 1.80 m — down from 2.05, which fixed the standing case: the gap
  above the antennae went 0.46 → 0.18 m. Anything keyed off the capsule rather
  than the model — plate, camera height, a `BoneAttachment3D` — separates from
  the body mid-dive. Fixing it properly means offsetting the plate by the model's
  own head height.
- **A sliding Gub is hard to hit.** The 0.77 m capsule is vertically correct —
  nothing of the body is above it — but its 0.38 m radius sits over the hips of a
  body whose head is half a metre forward of the axis.
- **A held spear vanishes when its Gub dies.** `_adopt_spears` adopts *embedded*
  projectiles, not the carried one, so a corpse carries the spear that killed it
  and not the one it was holding. Pre-existing, and left.
- **A settled corpse still creases at the neck and shoulder rings** at 2× zoom,
  for the skinning reason above. The real fix is *more bodies* — driving `Neck`
  and the shoulders instead of leaving them frozen at the death pose — which is a
  change to the size of `SEGMENTS`, not to its numbers. Resetting those undriven
  links to rest at death was tried, rendered, and reverted: no visible gain, and
  it costs the corpse the pose it died in.

### Result

`bash tools/smoke_test.sh` is 10 of 10. `art/generated/gub.glb` is 1.53 MB
against the old 1.97 MB, with 10542 triangles (down from 18k), 49 unprefixed
bones, an AABB of 1.902 × 1.800 × 0.748 with its base at y = 0, and
`nodes/root_scale = 1.0` — the model is authored in metres and the skeleton is
unscaled, so bone attachments and ragdoll capsules are in the same units as the
world.
## D-030 — A map is an id in the match config, not a scene path on the wire
The game is about to have a second map: a bought `.glb` of a well-known FPS arena,
hand-made where Whisperbloom Hollow is generated (D-007). Making room for it needed
one decision — how a peer learns which map it is building — and everything else
followed from it.

**`MatchConfig.map` carries an id, and `MapCatalog` turns ids into maps.** A scene
path would have been shorter by a whole file. It would also mean a client calling
`load()` on a string a peer sent it, which is the one thing the config's flat
dictionary of primitives exists to avoid: `apply_dict` validates everything it
reads because on a client every value in it is attacker-controlled (see the header
of `match_config.gd`). An id is validated the same way every other field is — an
entry that is not in the catalog clamps to `MapCatalog.DEFAULT` in `_clamp_all`,
alongside the kill limit and the enums — and the only paths in the build are the
ones a developer typed into the catalog.

The id also survives version skew in the only direction that matters. A host running
a build with a map an older client does not have sends an id that client cannot
resolve, and the client falls back to the island rather than to a failed `load()`
inside `_ready`. That is still a broken match, but it is a broken match that reaches
the results screen instead of one that hangs behind a loading card forever.

**The catalog is one table because "the map" was previously spelled out three times.**
`arena.gd` built it, `SceneFlow` named it on the loading card, and the lobby offered
a seed for it, and each of those knew "Whisperbloom Hollow" independently. Two of them
disagreeing about which map is loading is not a bug anyone would think to look for.
The entry carries the display name and the loading line as well as the kind and the
scene, so the card is generated from the same row the arena builds from.

**The seed and the map are separate fields, and only one of them means anything at a
time.** A static map has no seed — the lobby hides the seed row rather than greying it
out, for the same reason `friendly_fire` is hidden in a free-for-all: a greyed control
invites the question of what it would do, and there is no good answer.

**`arena.gd` branches once, at the top, and the branch is about lighting as much as
geometry.** A static map owns its own `WorldEnvironment` and `Sun`, so
`_build_environment` and the moon must not run for one — the island's environment is
tuned around torches being the key light at 0.30 moon energy (D-009), and dropping it
over a daylit arena makes both look broken. That is why the contract in
`static_map.gd` names the nodes it does, and why the void height is an export on the
map rather than `MatchState.VOID_HEIGHT`: -45 metres is a property of a floating island
with a deep rocky underside, not of an arena standing on the ground.

`scripts/world/static_map.gd` is written and the first map scene is not. The stub is
deliberate — the plumbing is testable today, and `MapCatalog` deliberately contains
no entry for a scene that does not exist yet, because `tools/playthrough.tscn` loads
for real every scene a map names.

## D-031 — Rust: collision baked in world space at load, and culling put back
The second map is a hand-made one — a fan remake of a small industrial FPS arena,
42 x 28 x 64 m of shipping containers and scaffolding, 148 meshes and 96,301
triangles — instanced whole by `arena.gd`'s static branch (D-029). Three things
about it needed deciding, and all three came out differently from what the
obvious answer would have been.

**Collision is built at runtime, in world space, from transformed triangles.**
The obvious answer is the importer's `-col` name suffix, or a `CollisionShape3D`
under each mesh carrying that mesh's `create_trimesh_shape()`. Neither works
here: 66 of the map's 150 nodes carry a **non-uniform** scale and five carry a
**negative** one, and a `ConcavePolygonShape3D` is not reliably scaled by the
transform of the node above it — the physics server takes a single scale off the
shape's owner, and a non-uniform one comes out wrong. The failure is not
dramatic, which is the problem: the containers look right and you fall through a
corner of one.

So `StaticMap._ready` walks every `MeshInstance3D`, transforms its `get_faces()`
into world space by its own `global_transform`, and hands the result to a single
`StaticBody3D` that has no transform of its own. The scaling problem stops
existing rather than being worked around. **`backface_collision` is on**, because
those five negatively scaled instances arrive wound the other way and a spear
would otherwise pass straight through the tower supports. The nets keep their
collision — they are chain-link, you can see through them, and a spear should
still stop on one.

Runtime rather than baked into a `.res`: it costs **110-190 ms** on the machine
this was written on, against 2.8 s to load the `.glb` itself, so a bake would
save under 7% of the map's load time and would add a build artefact that goes
stale silently the next time the source changes. The triangles are grouped into
16 m cells by *instance* — 12 shapes for this map — which keeps each shape's
bounding box tight without a per-triangle loop in GDScript. Bucketing whole
instances is 148 iterations; bucketing triangles would be 96,301, and the actual
vertex work stays inside the engine's `Transform3D * PackedVector3Array`.

**Back-face culling is forced back on, at load, on 28 of the 30 materials.**
Every material in the export is `doubleSided`, so the importer gives them all
`CULL_DISABLED` and the renderer draws the inside of every container, barrel and
oil tank before throwing it away behind the outside. The two exceptions are the
transparent ones — the chain-link `Net` and the `Solid Glass` in the doors — which
have to stay double-sided or they become see-through from one side only. The five
negative-determinant instances get a *duplicated* material with culling still off,
per instance, because a negative determinant reverses the winding the rasteriser
sees and back-face culling turns them inside out; duplicating is how the other
hundred-odd nodes sharing those materials keep their culling. `Mesh.030` on
`SM _ Tower _001` carries COLOR_0/COLOR_1, and its material imports with
`vertex_color_use_as_albedo` false, so nothing is tinting it — checked, not
assumed.

**Spawns sit at y ≈ 1.70 and were found by rendering, not by reading
coordinates.** The map's floor is not at zero: the walkable plane is 1.70 m up,
with a second tier near 2.0 and catwalks at 4-6.5 m. The eight pads are on the
main plane, each lifted 0.12 m the way the island lifts its solved pads, each
with its own measured floor height because the yard is not flat (1.59 to 1.82 m
across the eight). Finding them needed a tool: `tools/preview_map.gd` scans the
floor on a 2 m grid and prints three ASCII maps — height, whether a Gub-sized
capsule fits, and **how far you can see toward the middle from there** — and that
third one is the one that mattered. Two of the first eight pads passed every
geometric test and opened onto a container wall a metre away. The tool then
re-checks each pad with the physics the match will use, and the check is in the
gate, so a pad that ends up inside a shipping container fails a build rather than
being found by a player.

**The void is at -13 m, not -45.** The lowest vertex in the map is -0.64, so
anything below -13 has left through the one gap in the perimeter and is not
coming back. Forty-five metres of falling is a property of a floating island
(D-029), not of a yard.

**The environment is lighting and nothing else.** None of Whisperbloom Hollow's
look comes across — no sky shader, no moon, no aurora, no volumetric fog, no
torches, no scatter. Rust's own textures are the look. `rust_env.tres` is a plain
`ProceduralSkyMaterial`, one warm sun at 50 degrees with shadows, sky-sourced
ambient and reflections, and the island's tonemapping unchanged. It keeps glow
(a thrown spear makes its own material emissive so it can be seen coming, D-027,
and with glow off it simply cannot), keeps SSAO at about half the island's
intensity, drops volumetrics for plain distance fog, and has no `Lights` node at
all — it is outdoors under a hard sun and the containers with interiors are open
at one end.

One thing worth writing down because it cost an hour: **with
`ambient_light_source` set to SKY, Godot 4.7 ignores `ambient_light_energy` and
`ambient_light_sky_contribution` entirely.** Sweeping the energy from 1.0 to 2.0
produced byte-identical renders; only switching the source off changed anything.
The control that works is `background_energy_multiplier`, and 1.45 is where the
shadow under the drilling tower stops crushing (9% of the frame below 8/255 at
1.0, 1.6% at 1.45) with nothing anywhere clipping. This also means
`arena_env.tres`'s `ambient_light_energy = 2.5` does nothing — left alone, since
that is the island's file and its look is already signed off, but the comment
there is wrong about why it is dark.
