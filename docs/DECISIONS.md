# Design & Engineering Decisions

Running log. Newest phase last. Each entry: what was decided, and why.

---

## D-001 — Engine: Godot 4.7.2 stable, GDScript, Forward+
The user has `Godot_v4.7.2-stable_win64` locally, so the project pins that version.
GDScript over C# to keep the toolchain to a single dependency (no .NET SDK required to
build). Forward+ renderer because the map leans on volumetric fog, many small dynamic
torch lights, and SDFGI/SSAO — all Forward+-only or Forward+-preferred features.

## D-002 — World scale: 1 unit = 1 metre
The Stylized Nature MegaKit is authored at roughly human scale (a common tree is ~7 m
tall, tall grass ~1.8 m). The supplied `Gub.glb` is 5.18 units tall in bind pose, so the
Gub is imported at **0.35 scale** → ~1.81 m. Spear (1.90 units) is scaled to ~0.75 →
1.42 m. This lets us use realistic gravity and jump tuning without fighting the kit.

## D-003 — Source meshes are decimated offline
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
