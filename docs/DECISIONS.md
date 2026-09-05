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
re-attaches UVs, skin joints and weights by nearest-source-vertex transfer, then rewrites
a clean `.glb` into `art/generated/`. Sources in `assets/` are never modified — the
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
encoding of the host's IPv4 address + port**, formatted `XXXX-XXXX-XX`.

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
