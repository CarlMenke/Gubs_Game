# Playing GUB

You are a Gub. You throw spears at other Gubs. Last team standing wins.

## If you are not hosting — that is it, you are done

**Get the game.** Download `GUB.exe` and put it anywhere. It is one file — there
is nothing to install, no account, and nothing else to set up. Windows will warn
you it is from an unknown publisher: *More info → Run anyway*.

**Join.** Join with a code → paste in the code the host reads out
(`XXXXX-XXXXX`). Case and dashes do not matter.

That is the whole thing. Everything below is for whoever is hosting.

---

## Hosting — once, about ten minutes

One person hosts, and that person also plays, so nobody sits out. The setup is
theirs alone.

**1. Make a tunnel.** Go to [playit.gg](https://playit.gg), make an account, and
install the playit agent. Create a tunnel and set it up like this:

| | |
|---|---|
| Tunnel type | **UDP** (not TCP — the game does not use TCP at all) |
| Local port | **27015** |
| Local address | `127.0.0.1` |

playit gives back a public address that looks like
`angry-gub.at.ply.gg:41235`. The number on the end is *not* 27015 and is not
supposed to be — playit picks the outside port and forwards it to 27015 on your
machine. Leave the agent running whenever you host.

**2. Tell the game about it.** Open GUB → Settings → **Network** → paste the
whole thing, hostname and port, into **Public address**. It is remembered, so
this is a one-time job unless you make a new tunnel.

**3. Host.** Host a Game, then read out the invite code. The caption above it
should say **INTERNET (PLAYIT)**. If it does, the code will work for anyone,
anywhere, with nothing installed on their end.

### The alternative: Tailscale

If you cannot or would rather not run playit, everyone — not just you — can
install [Tailscale](https://tailscale.com/download), sign in, and join one
tailnet. Leave **Public address** blank and the game hands out your tailnet
address instead; the caption says **TAILNET**. It works, and it has always
worked, but it is five people's setup instead of one person's, and the free plan
covers six people, so a full eight-player lobby needs a paid seat or a spare
account.

Blank also covers the simplest case of all: everyone in the same building on the
same Wi-Fi needs nothing at all. The caption says **LAN**.

---

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

**The host picks the map** in the lobby's Match panel — Whisperbloom Hollow, the
enchanted island, or Rust, an industrial yard in daylight — and everyone in the
lobby plays whichever one they chose.

Two of those are worth a sentence. **Double-tap `Space`** — jump, then jump
again while you are still in the air — is a dive: a long committed leap that you
only get once per jump and cannot take back. And the **spear does not leave on
the click**: the Gub winds up first and throws about three quarters of a second
later, aimed where you are pointing *then*, so a moving target has to be led.

Hold right click and a ring appears on the ground where your spear would
actually land. Spears drop, and that ring is the only honest answer to how much.

---

## If something goes wrong

**The caption says LAN or TAILNET when you expected INTERNET (PLAYIT)** — the
host left **Public address** blank, or typed it into a copy of the game that was
already hosting. Settings takes effect when the lobby is opened, so change it,
leave the lobby, and host again.

**The caption says PUBLIC ADDRESS DID NOT RESOLVE** — the hostname could not be
looked up. Usually a typo, or the tunnel was deleted from the playit dashboard.
Check the address against the dashboard and reopen the lobby.

**The caption says PUBLIC ADDRESS IS NOT HOST:PORT** — the field needs both
halves, with a colon between them: `angry-gub.at.ply.gg:41235`. A hostname on
its own is not enough, because playit picks the port and it is never 27015.

**"Could not reach…" or "Timed out reaching the host"** — the code reached
playit and playit had nowhere to send it. Nearly always one of three things: the
playit agent is not running on the host's machine, the tunnel is TCP instead of
UDP, or its local port is not 27015. Check all three in the dashboard.

**The code used to work and now does not** — codes go stale. The address is
baked into the code, so if the host reopens their lobby, reads out a fresh code,
and everyone uses that one, most of this section stops applying.

**Nothing happens when you click** — the game takes the mouse when a match
starts. Press `Esc` to get the cursor back.

Up to eight can play.
