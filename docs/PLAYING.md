# Playing GUB

You are a Gub. You throw spears at other Gubs. Last team standing wins.

## Setup — once, about five minutes

**1. Join the tailnet.** Install [Tailscale](https://tailscale.com/download), sign
in, and accept the invite. This is what lets everyone reach each other without
anyone touching a router. Leave it running when you play.

**2. Get the game.** Download `GUB.exe` and put it anywhere. It is one file —
there is nothing to install. Windows will warn you it is from an unknown
publisher: *More info → Run anyway*.

## Playing

**To host:** Host Game → read out the invite code (`XXXXX-XXXXX`).
Whoever hosts also plays, so nobody sits out.

**To join:** Join with a code → paste it in. Case and dashes do not matter.

The caption above the code says how far it reaches. **TAILNET** means anyone on
the tailnet can join. If it says **LAN**, Tailscale is not running — start it and
reopen the lobby.

## Controls

| | | | |
|---|---|---|---|
| Move | `W` `A` `S` `D` | Throw spear | Left click |
| Jump | `Space` | Aim | Right click |
| Dive | `Space` again in the air | Place shield mushroom | `Q` |
| Sprint | `Shift` | Throw lure | `E` |
| Crouch | `Ctrl` or `C` | Interact | `F` |
| Scoreboard | `Tab` (hold) | Respawn | `R` |
| Chat | `T` | | |
| Pause / settings | `Esc` | | |

Two of those are worth a sentence. **Double-tap `Space`** — jump, then jump
again while you are still in the air — is a dive: a long committed leap that you
only get once per jump and cannot take back. And the **spear does not leave on
the click**: the Gub winds up first and throws about half a second later, aimed
where you are pointing *then*, so a moving target has to be led.

## If something goes wrong

**"Could not reach…"** — the host is not hosting yet, or their code is stale.
Have them reopen the lobby and read out a fresh one.

**The code says LAN, not TAILNET** — Tailscale is not running on the host's
machine.

**Nothing happens when you click** — the game takes the mouse when a match
starts. Press `Esc` to get the cursor back.

Up to eight can play. The free Tailscale plan covers six people, so a full
lobby needs a paid seat or one spare account.
