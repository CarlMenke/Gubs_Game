# GUB — Master Build Plan

> Current position and how to resume: **`docs/STATUS.md`**.

A match-based 3rd-person multiplayer game in Godot 4.7.2. Players are GUBs — small yellow
aliens — fighting on a floating enchanted-forest island with instant-kill thrown spears.

This is the single source of truth for scope. Every item is tracked to completion.
Design rationale for non-obvious choices lives in `docs/DECISIONS.md`.

---

## Phase 0 — Foundation

- [x] 0.1  Git repo, `.gitignore`, `.gitattributes`, LICENSE, README
- [x] 0.2  Godot project skeleton: `project.godot`, input map, physics layers, render settings
- [x] 0.3  Asset pipeline — decimate the 500K-tri source meshes to game-ready density,
           preserving UVs + skin weights; generate import presets
- [x] 0.4  Docs: PLAN.md, DECISIONS.md, ARCHITECTURE.md

## Phase 1 — Networking & Lobby

- [x] 1.1  `Net` autoload — host / join / disconnect, peer registry, player info replication
- [x] 1.2  Invite-code system — short shareable code that encodes the host endpoint
- [x] 1.3  Main menu — name entry, Host, Join-by-code, Settings, Quit
- [x] 1.4  Lobby UI — player list, invite code + copy, match settings (host-only),
           ready toggle, team pick, start button, chat
- [x] 1.5  Lobby 3D backdrop — real Gubs standing in a ring with live nameplates
- [x] 1.6  `MatchConfig` resource — mode, limits, timers, cooldowns, friendly fire
- [x] 1.7  Scene flow — Menu → Lobby → Game → Results → Lobby
- [~] 1.8  Robust disconnect handling — host leaves and client drops are done and
           tested (a dropped peer's Gub is freed on every machine and the win check
           re-runs, so a lives match can still end). **Mid-match join as spectator
           is not**: a late joiner has no way to be told about Gubs that already
           exist, so it needs a world-state sync on join. See docs/STATUS.md.

## Phase 2 — The Gub (character)

- [x] 2.1  Gub scene — CharacterBody3D, capsule, skinned mesh, skeleton
- [x] 2.2  Third-person camera rig — spring arm, collision, shoulder offset, aim zoom
- [x] 2.3  Movement — walk / run / sprint, jump, crouch, slide, air control, coyote time
- [x] 2.4  AnimationTree — smooth blended state machine across all 8 source clips,
           upper-body throw layer so throwing works while moving
- [x] 2.5  Nameplate — billboarded Label3D, team tint, distance fade, occlusion
- [x] 2.6  Network sync — transform + animation state, interpolation, ownership
- [x] 2.7  Ragdoll — physical-bone skeleton built at runtime, death impulse, corpse cleanup

## Phase 3 — Combat & abilities

- [x] 3.1  Spear permanently held in the right hand (bone attachment)
- [x] 3.2  Throw — aim, wind-up, release, arcing projectile
- [x] 3.2a Spear trail
- [x] 3.3  Hit resolution (server-authoritative), instant kill
- [x] 3.3a Spear sticks in the corpse
- [x] 3.4  Spear regeneration — the hand empties on the throw and refills on the cooldown
- [x] 3.5  Mushroom shield — deployed in front of the Gub, blocks spears, timed/HP, cooldown
- [x] 3.6  Lure — thrown, arms on landing, briefly yanks nearby Gubs in and holds them
- [x] 3.7  Death & respawn — spawn points, spawn protection, fall-off-island death
- [x] 3.8  Feedback — sounds, hitmarker, camera shake, kill feed (6.3)

## Phase 4 — The map (Whisperbloom Hollow)

- [x] 4.1  Procedural floating island — surface heightfield + rocky underside + collision
- [x] 4.2  Out-of-bounds death volume below the island
- [x] 4.3  Seeded prop scatter — trees, bushes, ferns, grass, flowers, mushrooms, pebbles
- [x] 4.4  Hand-placed landmarks — shrine, mushroom grove, rock arch, log bridges, high ground
- [x] 4.5  Torches — mesh, flame particles, flickering light, crackle audio
- [x] 4.6  Sky — custom shader: dusk gradient, stars, moon, aurora, drifting cloud band
- [x] 4.7  WorldEnvironment — volumetric fog, glow, SSAO, tonemap, colour grade
- [x] 4.8  Ambience VFX — fireflies, drifting spores, wind-swayed foliage, falling leaves
- [x] 4.9  Ambient audio — forest loop, wind, water
- [x] 4.10 Spawn points + traversal pass (scale, sightlines, cover balance)

## Phase 5 — Match rules

- [x] 5.1  `MatchManager` — warmup / playing / post-match phases, authoritative timers
- [x] 5.2  Free-for-all — kill limit, time limit
- [x] 5.3  Teams — assignment, team colours, team score, friendly fire toggle
- [x] 5.4  Lives / elimination — last Gub standing, spectate on elimination
- [x] 5.5  Match end → results screen → rematch or back to lobby

## Phase 6 — UI / UX

- [x] 6.1  HUD — crosshair, ability cooldowns, score, timer, lives
- [x] 6.2  Scoreboard (hold Tab)
- [x] 6.3  Kill feed
- [x] 6.4  Pause & settings — sensitivity, FOV, volume, quality preset, keybinds
- [x] 6.5  Spectator camera
- [x] 6.6  Scene transitions / loading
- [x] 6.7  Chat (lobby + in-match)

## Phase 7 — Ship

- [x] 7.1  Export preset (Windows), icon, app metadata *(needs export templates installed)*
- [x] 7.2  Headless import + automated smoke test script
- [x] 7.3  README — how to build, run, host, and join
- [ ] 7.4  Final pass + tagged commit
