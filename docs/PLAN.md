# GUB — Master Build Plan

A match-based 3rd-person multiplayer game in Godot 4.7.2. Players are GUBs — small yellow
aliens — fighting on a floating enchanted-forest island with instant-kill thrown spears.

This is the single source of truth for scope. Every item is tracked to completion.
Design rationale for non-obvious choices lives in `docs/DECISIONS.md`.

---

## Phase 0 — Foundation

- [ ] 0.1  Git repo, `.gitignore`, `.gitattributes`, LICENSE, README
- [ ] 0.2  Godot project skeleton: `project.godot`, input map, physics layers, render settings
- [ ] 0.3  Asset pipeline — decimate the 500K-tri source meshes to game-ready density,
           preserving UVs + skin weights; generate import presets
- [ ] 0.4  Docs: PLAN.md, DECISIONS.md, ARCHITECTURE.md

## Phase 1 — Networking & Lobby

- [ ] 1.1  `Net` autoload — host / join / disconnect, peer registry, player info replication
- [ ] 1.2  Invite-code system — short shareable code that encodes the host endpoint
- [ ] 1.3  Main menu — name entry, Host, Join-by-code, Settings, Quit
- [ ] 1.4  Lobby UI — player list, invite code + copy, match settings (host-only),
           ready toggle, team pick, start button, chat
- [ ] 1.5  Lobby 3D backdrop — real Gubs standing in a ring with live nameplates
- [ ] 1.6  `MatchConfig` resource — mode, limits, timers, cooldowns, friendly fire
- [ ] 1.7  Scene flow — Menu → Lobby → Game → Results → Lobby
- [ ] 1.8  Robust disconnect handling (host leaves, client drops, mid-match join as spectator)

## Phase 2 — The Gub (character)

- [ ] 2.1  Gub scene — CharacterBody3D, capsule, skinned mesh, skeleton
- [ ] 2.2  Third-person camera rig — spring arm, collision, shoulder offset, aim zoom
- [ ] 2.3  Movement — walk / run / sprint, jump, crouch, slide, air control, coyote time
- [ ] 2.4  AnimationTree — smooth blended state machine across all 8 source clips,
           upper-body throw layer so throwing works while moving
- [ ] 2.5  Nameplate — billboarded Label3D, team tint, distance fade, occlusion
- [ ] 2.6  Network sync — transform + animation state, interpolation, ownership
- [ ] 2.7  Ragdoll — physical-bone skeleton built at runtime, death impulse, corpse cleanup

## Phase 3 — Combat & abilities

- [ ] 3.1  Spear permanently held in the right hand (bone attachment)
- [ ] 3.2  Throw — aim, wind-up, release, arcing projectile, trail
- [ ] 3.3  Hit resolution (server-authoritative), instant kill, spear sticks in the corpse
- [ ] 3.4  Spear regeneration / retrieval
- [ ] 3.5  Mushroom shield — deployed in front of the Gub, blocks spears, timed/HP, cooldown
- [ ] 3.6  Lure — thrown, arms on landing, briefly yanks nearby Gubs in and holds them
- [ ] 3.7  Death & respawn — spawn points, spawn protection, fall-off-island death
- [ ] 3.8  Feedback — kill feed, hitmarker, sounds, camera shake

## Phase 4 — The map (Whisperbloom Hollow)

- [ ] 4.1  Procedural floating island — surface heightfield + rocky underside + collision
- [ ] 4.2  Out-of-bounds death volume below the island
- [ ] 4.3  Seeded prop scatter — trees, bushes, ferns, grass, flowers, mushrooms, pebbles
- [ ] 4.4  Hand-placed landmarks — shrine, mushroom grove, rock arch, log bridges, high ground
- [ ] 4.5  Torches — mesh, flame particles, flickering light, crackle audio
- [ ] 4.6  Sky — custom shader: dusk gradient, stars, moon, aurora, drifting cloud band
- [ ] 4.7  WorldEnvironment — volumetric fog, glow, SSAO, tonemap, colour grade
- [ ] 4.8  Ambience VFX — fireflies, drifting spores, wind-swayed foliage, falling leaves
- [ ] 4.9  Ambient audio — forest loop, wind, water
- [ ] 4.10 Spawn points + traversal pass (scale, sightlines, cover balance)

## Phase 5 — Match rules

- [ ] 5.1  `MatchManager` — warmup / playing / post-match phases, authoritative timers
- [ ] 5.2  Free-for-all — kill limit, time limit
- [ ] 5.3  Teams — assignment, team colours, team score, friendly fire toggle
- [ ] 5.4  Lives / elimination — last Gub standing, spectate on elimination
- [ ] 5.5  Match end → results screen → rematch or back to lobby

## Phase 6 — UI / UX

- [ ] 6.1  HUD — crosshair, ability cooldowns, score, timer, lives
- [ ] 6.2  Scoreboard (hold Tab)
- [ ] 6.3  Kill feed
- [ ] 6.4  Pause & settings — sensitivity, FOV, volume, quality preset, keybinds
- [ ] 6.5  Spectator camera
- [ ] 6.6  Scene transitions / loading
- [ ] 6.7  Chat (lobby + in-match)

## Phase 7 — Ship

- [ ] 7.1  Export preset (Windows), icon, app metadata
- [ ] 7.2  Headless import + automated smoke test script
- [ ] 7.3  README — how to build, run, host, and join
- [ ] 7.4  Final pass + tagged commit
