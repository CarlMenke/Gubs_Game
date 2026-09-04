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

## D-009 — Ragdolls are local and cosmetic, and barely damped
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
