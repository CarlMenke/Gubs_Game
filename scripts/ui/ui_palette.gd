class_name UIPalette
extends RefCounted
## The colours and metrics every GUB screen is built from.
##
## These live in a class of their own rather than inside the theme because the
## HUD draws several things — the crosshair, the cooldown sweeps, the kill feed
## tints — with `_draw` and `draw_arc`, which a `Theme` cannot reach. One list of
## colours keeps a hand-drawn crosshair and a themed button the same family.
##
## The scheme is the game's own lighting: a night-time enchanted forest lit by
## torches. Backgrounds are the project's clear colour and near-blacks of it;
## anything the player can act on is torch amber; anything that says "you, or
## your readiness" is the Gub's own yellow. Nothing else is coloured, so the two
## accents keep their meaning.

# ------------------------------------------------------------------ ground ---

## The project's `default_clear_color`. Menus sit on this so a fade to black and
## a fade to the menu are the same colour.
const VOID := Color(0.024, 0.031, 0.047)
## Panel glass. Deliberately translucent: the lobby and the menu both have live
## 3D behind them and a solid panel would throw that away.
const PANEL := Color(0.043, 0.055, 0.078, 0.90)
## A panel sitting on another panel — a row inside a list, a settings field.
const RAISED := Color(0.078, 0.098, 0.133, 0.85)
const RAISED_STRONG := Color(0.094, 0.118, 0.157, 1.0)
## Hairlines. Low alpha on purpose: at 1600x900 a 1 px border at full strength
## reads as a wireframe, not as an edge.
const LINE := Color(0.55, 0.66, 0.80, 0.16)
const LINE_STRONG := Color(0.62, 0.74, 0.88, 0.30)

# -------------------------------------------------------------------- text ---

const TEXT := Color(0.90, 0.94, 0.98)
const TEXT_DIM := Color(0.58, 0.65, 0.73)
const TEXT_FAINT := Color(0.42, 0.48, 0.56)
const TEXT_ON_ACCENT := Color(0.05, 0.04, 0.02)

# ----------------------------------------------------------------- accents ---

## Torch amber: interaction. Hover, focus, the selected thing, the live clock.
const AMBER := Color(1.00, 0.64, 0.26)
const AMBER_DIM := Color(0.72, 0.45, 0.18)
const AMBER_GLOW := Color(1.00, 0.72, 0.38)
## The Gub's own yellow: you, your state, "ready", "armed".
const GUB := Color(1.00, 0.84, 0.26)
const GUB_DIM := Color(0.62, 0.52, 0.18)

const DANGER := Color(1.00, 0.36, 0.30)
const GOOD := Color(0.48, 0.87, 0.51)

# ------------------------------------------------------------------ scales ---

## Authored against the 1600x900 base viewport; `canvas_items` stretch scales
## the whole lot from there, so these are the only sizes that ever need tuning.
const FONT_TINY := 14
const FONT_SMALL := 16
const FONT_BODY := 19
const FONT_LEAD := 23
const FONT_HEAD := 30
const FONT_DISPLAY := 44

const RADIUS := 4
const GAP := 12
const PAD := 20


## Team tint, shared with the nameplate above the Gub's head so a row in the
## lobby and a name over a head are unmistakably the same player.
static func team_colour(team: int) -> Color:
	return Nameplate.colour_for_team(team)


## `m:ss`, or `mm:ss` past ten minutes. Negative clamps to zero rather than
## printing a minus, because a clock that has run out reads as 0:00 everywhere.
static func clock(seconds: float) -> String:
	var total := int(maxf(0.0, seconds) + 0.5)
	return "%d:%02d" % [total / 60, total % 60]


## Fade a colour toward nothing without touching its hue, for pips, ghosted
## rows and anything that dims rather than changes meaning.
static func faded(colour: Color, alpha: float) -> Color:
	return Color(colour.r, colour.g, colour.b, colour.a * alpha)
