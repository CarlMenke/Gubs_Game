# Architecture

How GUB is put together, and where the seams are.

`docs/PLAN.md` is the scope. `docs/DECISIONS.md` is why non-obvious things are
the way they are, and this file points into it rather than repeating it.
`docs/STATUS.md` is where the work is up to. Read this one when you need to know
*where a thing lives* or *what you are allowed to change without breaking
something two directories away*.

---

## The shape of it

Five autoloads and one scene at a time. Nothing else is global.

```
Settings        local, per-machine preferences. Never replicated.
Net             transport, roster, chat. Owns the socket.
MatchState      the authoritative match: alive, kills, score, phase, respawns.
SceneFlow       scene changes, the fade, the loading card, mouse-capture policy.
AudioDirector   bus volumes and a pooled one-shot player.
```

Exactly one scene is loaded at a time — `main_menu.tscn`, `lobby.tscn` or
`arena.tscn` — and `SceneFlow` is the only thing that swaps them.

The dependency direction is strictly one way:

```
        Settings          (depends on nothing)
           ↑
          Net             (roster; asks Settings for the player's name)
           ↑
      MatchState          (the match; asks Net who is here)
           ↑
   arena / gub / ui       (the world and the screens)
```

Nothing below reaches up. `Net` does not know a match exists; `MatchState` does
not know what a spear is; the arena does not know what a lobby is. The one
call that closes the loop between the world and the match is
`MatchState.register_arena(players_root, spawn_points)` — until something makes
it, there is no game. `scenes/world/arena.tscn` makes it, and so does
`tools/combat_range.tscn`, which is why a testbed can run the real match code.

### Why `Net` and `MatchState` are two files

They were one, briefly. Splitting them means a disconnect is handled in exactly
one place: `Net` notices the peer is gone and emits `player_left`, `MatchState`
listens and clears up the body that peer left standing in the arena. The roster
is `Net`'s business; a corpse in the world is not. It also means the whole lobby
can be exercised with no match code loaded at all.

---

## Authority

Host-authoritative, and the host also plays (**D-004**). There is no dedicated
server and no matchmaking backend — the host is peer 1.

| owned by | what |
|---|---|
| **the owning client** | its own Gub's position, rotation, animation state |
| **the host** | throws, projectile hits, deaths, respawns, scoring, phase, timers, the roster |

A client's Gub is client-authoritative because prediction and reconciliation is
a large amount of complexity to buy accuracy that a friends-only party game does
not need. `set_multiplayer_authority(peer_id)` is called on spawn and a
`MultiplayerSynchronizer` pushes the result out; remote Gubs run no input and no
gravity, they only smooth toward what the network last said.

Everything else is a request. `GubCombat` decides *when* it wants to throw and
plays its own feedback immediately so the game feels instant, but it sends an
intent RPC and the host decides whether the throw actually happened. Cooldowns
are therefore tracked twice on purpose — the local copy drives the HUD sweep
without a round trip, the host's copy is the one that counts, and a client that
lies about its cooldown gets its request dropped.

The pattern throughout is **`rpc()` then call locally**. Both halves matter, and
only one of them has ever been exercised offline — see the testbed note below.

### Two things that deliberately do not replicate

- **The terrain.** Every client generates it from `Net.config.map_seed` and must
  land on a byte-identical island, because a spear that clears a ridge on the
  host has to clear it everywhere (**D-007**).
- **Ragdolls.** Local and cosmetic. A corpse that disagrees between machines
  costs nothing, and replicating 29 physical bones costs a great deal
  (**D-010**).

Thrown spears sit between the two: every peer simulates its own copy from the
same launch parameters, so the flight is pure ballistics with no packets, and
only the host's copy is allowed to declare a kill.

---

## The transport seam

`Net` dials an **abstract `MultiplayerPeer`**. `ENetMultiplayerPeer.new()`
appears in exactly two places in the codebase, both of them in
`scripts/net/net.gd`:

- `host_lobby(port)` — `create_server()`
- `join_address(ip, port)` — `create_client()`

Nothing in `scripts/game`, `scripts/player`, `scripts/world` or `scripts/ui`
constructs a peer or names a transport. That is the seam a relay or signalling
transport slots into later (**D-005**): swap what those two functions assign to
`multiplayer.multiplayer_peer` and no game code changes.

This is not a hypothetical. `start_offline()` already exercises it — it assigns
an `OfflineMultiplayerPeer`, which reports itself as peer 1 and as the server, so
every `is_host` branch and every authority check downstream takes the shipping
path. That is the mechanism the testbeds run on (**D-011**), and it is the proof
the seam is real.

The invite code is the other half of having no backend: a Crockford-base32
encoding of the host's IPv4 address and port, ten characters, formatted
`XXXXX-XXXXX` (**D-005**). It works on a LAN, over a VPN, or over the internet
with UDP 27015 forwarded. It also means the code carries the host's address,
which is a product decision worth confirming rather than a settled one.

---

## The match, end to end

```
main_menu ──host/join──> lobby ──start──> arena ──> results ──> lobby
```

`SceneFlow` drives every one of those arrows, and it is also the only thing that
decides whether the mouse is captured. Cursor state is a stack of named holds
(`release_cursor("pause")`, `recapture_cursor("pause")`) rather than a boolean,
because the "I opened the pause menu and now I can't click anything" bug is what
a boolean gets you the moment two things want the cursor at once. Anything gated
on the cursor asks `SceneFlow.cursor_is_free()`.

Inside a match, `MatchState` runs a phase machine — warmup, then live, then
finished. Ending a match is a **broadcast, not a navigation** (**D-021**): the
host declares the match over and every peer's results screen comes up off that
signal, rather than each client deciding on its own that it is time to leave.
Spectating is a change of subject rather than a second camera (**D-020**) — a
dead player's camera re-targets a living Gub, it does not switch to some other
rig.

The loading card exists because the arena is *generated* and that costs two to
six seconds inside `arena.gd`'s `_ready`. `change_scene_to_file` does not return
until that finishes, so the card has to be on screen *before* the call — there is
no main thread left to animate anything once the island starts building.

---

## The world

`scenes/world/arena.tscn` is Whisperbloom Hollow. It is built from one integer
seed at load, in an order that is load-bearing:

1. **terrain** — everything else asks it how high the ground is;
2. **landmarks** — hand-placed, and they get first refusal on where they stand;
3. **spawn points** — dodge the landmarks, then become obstacles themselves;
4. **prop scatter** — fills what is left, never landing on 2 or 3;
5. **torches** — in the spots the landmarks asked for.

`IslandGenerator` is also the map's **height oracle**: prop scatter, landmark
placement and spawn points all ask `height_at`/`slope_at` rather than
ray-casting, so they can run before any collision shape exists. Nothing in the
generator touches the global RNG — every random number comes from a local
`RandomNumberGenerator` or a seeded `FastNoiseLite`, both pure functions of the
seed. Break that and clients silently get different islands.

The surface mesh is built in **polar** coordinates, not on a square grid,
because the rim is the most-looked-at line on a floating island and a grid
leaves a staircase edge there. A polar ring lands on the outline by
construction, and the last surface ring *is* the first underside ring.

---

## Where things live

```
art/generated/   game-ready meshes and textures — committed, no Python needed
assets/          raw source art (.gdignore'd; only the MegaKit is imported)
audio/sfx/       synthesised sound effects — committed, see tools/make_sfx.py
docs/            STATUS, PLAN, DECISIONS, ARCHITECTURE
resources/       shaders, environment, theme, bus layout
scenes/          player, items, ui, world
scripts/         game, items, net, player, ui, util, world
tools/           dev tools and testbeds — none of this ships
```

`scripts/` mirrors `scenes/`. A few files worth knowing by name:

| file | what it is |
|---|---|
| `scripts/net/net.gd` | the socket, the roster, chat. The transport seam |
| `scripts/net/invite_code.gd` | endpoint ⇄ ten characters, and back |
| `scripts/game/match_state.gd` | the authoritative match |
| `scripts/game/match_config.gd` | mode, limits, timers, cooldowns, friendly fire |
| `scripts/util/scene_flow.gd` | transitions, the fade, cursor policy |
| `scripts/world/arena.gd` | the map scene, and `register_arena` |
| `scripts/world/island_generator.gd` | terrain, and the height oracle |
| `scripts/player/gub.gd` | a player character |
| `scripts/player/gub_combat.gd` | spear, mushroom, lure |
| `scripts/player/ragdoll_builder.gd` | 29 physical bones, generated at runtime |
| `scripts/items/spear_projectile.gd` | hand-integrated ballistics, swept for hits |

`export_presets.cfg` is deliberately committed — it is the only record of what a
shippable build excludes (`tools/`, `assets/`, `docs/`), and ignoring it would
make "there is an export preset" a claim nobody could check out.

---

## Two rules that are easy to break by accident

- **`queue_free()` is deferred.** A `while` loop that frees a child and re-reads
  `get_child_count()` never terminates. That hung the whole game on the sixth
  death of every match.
- **A testbed supplies things by hand.** Every integration defect this project
  has had was a thing wired into a testbed and into nothing else — movement
  input, the HUD, the mouse grab, the ambience path. When you add a harness, ask
  what it is providing that the real game does not, because that list is the
  list of things nothing is checking (**D-018**, **D-019**).

Verification is three tiers and the table of what each tool proves is in
`docs/STATUS.md`. The gate is `bash tools/smoke_test.sh`.
