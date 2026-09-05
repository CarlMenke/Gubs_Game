class_name Crosshair
extends Control
## The reticle, and the single most important thing on the HUD: it is also the
## spear-ready indicator (PLAN 3.4, 6.1).
##
## Spears are the only weapon and they always kill, so "am I dangerous right
## now" is the one piece of state a Gub must never have to look away to read.
## Putting it in the crosshair rather than in a corner means it is answered
## wherever the eye already is: armed, the ticks are the Gub's own yellow and
## the centre is a filled dot; empty, they go grey and hollow and an amber ring
## closes around them as the spear grows back.
##
## Drawn rather than assembled from textures because every part of it is a
## rectangle or an arc, and because a crosshair that has to stay crisp at any
## window size is better off as vectors than as a sprite someone has to re-export.

## Distance from the centre to the inner end of each tick, and how long the
## ticks are. Kept small: the aim point is the gap, and a wide crosshair on an
## instant-kill weapon encourages people to aim with the wrong pixel.
const GAP := 6.0
const TICK := 8.0
const THICKNESS := 2.0
const DOT_RADIUS := 1.7

## The recharge ring sits outside the ticks with clear air between, so a
## half-full ring is never mistaken for a longer tick.
const RING_RADIUS := 21.0
const RING_WIDTH := 2.5

## The hitmarker: four short diagonals that snap in on a kill and fade. Purely
## visual — `MatchState` already plays the sound, and doubling it up would be
## two hitmarkers for one kill.
const MARK_INNER := 9.0
const MARK_OUTER := 17.0
const MARK_FADE := 0.4

## Fraction of the spear cooldown remaining, 0 when armed. Set by the HUD.
var recharge: float = 0.0
## Hidden entirely while dead or spectating: a crosshair with nothing behind it
## invites you to aim.
var armed: bool = true

var _mark: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


## Called by the HUD every frame. Repaints only when something changed, because
## this is a `_draw` on top of a running game.
func set_state(new_recharge: float, is_armed: bool) -> void:
	if is_equal_approx(new_recharge, recharge) and is_armed == armed:
		return
	recharge = new_recharge
	armed = is_armed
	queue_redraw()


## Flash the hitmarker. Called when this client's Gub gets a kill.
func strike() -> void:
	_mark = MARK_FADE
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_mark = maxf(0.0, _mark - delta)
	if _mark <= 0.0:
		set_process(false)
	queue_redraw()


func _draw() -> void:
	var centre := size * 0.5
	var ready := recharge <= 0.0
	var tint := UIPalette.GUB if ready and armed else UIPalette.faded(UIPalette.TEXT, 0.5)

	# Four ticks. The vertical pair is drawn the same length as the horizontal
	# one; a "T" crosshair reads as broken rather than as deliberate at this size.
	for direction: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		draw_line(centre + direction * GAP, centre + direction * (GAP + TICK),
			tint, THICKNESS)

	if ready and armed:
		draw_circle(centre, DOT_RADIUS, tint)
	elif armed:
		# Hollow while the hand is empty: the missing dot is the missing spear.
		draw_arc(centre, DOT_RADIUS + 0.8, 0.0, TAU, 10,
			UIPalette.faded(UIPalette.TEXT, 0.45), 1.0)
		# The ring fills clockwise from twelve o'clock, which is the direction
		# every cooldown sweep in every game fills, and therefore the one that
		# needs no explaining.
		var swept := (1.0 - recharge) * TAU
		draw_arc(centre, RING_RADIUS, -PI * 0.5, -PI * 0.5 + TAU, 48,
			UIPalette.faded(UIPalette.TEXT, 0.14), RING_WIDTH)
		if swept > 0.01:
			draw_arc(centre, RING_RADIUS, -PI * 0.5, -PI * 0.5 + swept, 48,
				UIPalette.AMBER, RING_WIDTH)

	if _mark > 0.0:
		var alpha := _mark / MARK_FADE
		var colour := UIPalette.faded(Color(1, 1, 1), alpha)
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			draw_line(centre + corner * MARK_INNER, centre + corner * MARK_OUTER,
				colour, 2.0)
