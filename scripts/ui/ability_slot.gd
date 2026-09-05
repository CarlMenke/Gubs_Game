class_name AbilitySlot
extends Control
## One square in the ability bar: what it is, which key fires it, and how long
## until it will (PLAN 6.1).
##
## The glyphs are drawn rather than imported. There is no icon set in this
## project and there is not going to be one for three shapes that are a spear, a
## mushroom and a lure — a stick with a point on it, a cap on a stem, and a ball
## with spikes are half a dozen `draw_` calls each, they stay crisp at any
## window size, and they tint with the slot's state for free.
##
## The key cap is read out of the input map rather than typed in, so a slot can
## never claim Q while the action is bound to something else.

enum Kind { SPEAR, MUSHROOM, LURE }

const SIZE := 62.0
const RADIUS := 5.0

@export var kind: Kind = Kind.SPEAR
## The input action this slot fires, used for the key cap.
@export var action: String = "throw_spear"
@export var label_text: String = "Spear"

## Seconds left, and what the full cooldown is, so the sweep has a denominator.
var _remaining: float = 0.0
var _total: float = 1.0

@onready var _cap: Label = %KeyCap
@onready var _name: Label = %Name


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(SIZE, SIZE)
	_cap.text = SettingsPanel.primary_key(action)
	_name.text = label_text


## Called by the HUD each frame. `total` is the configured cooldown, which the
## host can change mid-lobby, so it is passed in rather than cached.
func set_cooldown(remaining: float, total: float) -> void:
	if is_equal_approx(remaining, _remaining) and is_equal_approx(total, _total):
		return
	_remaining = maxf(0.0, remaining)
	_total = maxf(0.01, total)
	queue_redraw()


func is_ready() -> bool:
	return _remaining <= 0.0


func _draw() -> void:
	var box := Rect2(Vector2.ZERO, Vector2(SIZE, SIZE))
	var ready := is_ready()
	var tint: Color = UIPalette.GUB if ready else UIPalette.faded(UIPalette.TEXT, 0.34)

	draw_rect(box, Color(0.02, 0.027, 0.04, 0.62), true)
	# The border is the state at a glance from the corner of the eye; the sweep
	# is the detail you look at only when you care how long is left.
	draw_rect(box, UIPalette.faded(tint, 0.85 if ready else 0.5), false, 1.5)

	if not ready:
		_draw_sweep()
	_draw_glyph(tint)

	if not ready:
		# One decimal under a second, whole seconds above it: "0.4" is worth
		# waiting for and "8.7" is not.
		var text := "%.1f" % _remaining if _remaining < 1.0 else "%d" % ceili(_remaining)
		var font := get_theme_default_font()
		var font_size := 20
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_string(font, Vector2((SIZE - width) * 0.5, SIZE * 0.5 + 26.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, UIPalette.AMBER)


## The unavailable part of the cooldown, as a wedge eaten out of the square from
## twelve o'clock clockwise. Approximated with a triangle fan, which at this
## size is indistinguishable from an exact sector and is one call.
func _draw_sweep() -> void:
	var fraction := clampf(_remaining / _total, 0.0, 1.0)
	if fraction <= 0.001:
		return
	var centre := Vector2(SIZE, SIZE) * 0.5
	# Long enough to reach the corners of the square from the centre.
	var reach := SIZE
	var steps := maxi(3, int(fraction * 28.0))
	var points := PackedVector2Array([centre])
	for i in steps + 1:
		var angle := -PI * 0.5 + TAU * fraction * (float(i) / float(steps))
		points.append(centre + Vector2(cos(angle), sin(angle)) * reach)
	draw_colored_polygon(points, Color(0.008, 0.012, 0.02, 0.62))


func _draw_glyph(tint: Color) -> void:
	var c := Vector2(SIZE, SIZE) * 0.5 - Vector2(0, 4)
	match kind:
		Kind.SPEAR:
			# A shaft on the diagonal with a head on the top end. Drawn on the
			# diagonal because a vertical line in a square reads as a divider.
			var tail := c + Vector2(-11, 12)
			var neck := c + Vector2(7, -6)
			var tip := c + Vector2(12, -13)
			draw_line(tail, neck, tint, 2.4)
			draw_colored_polygon(PackedVector2Array([
				tip, neck + Vector2(-4.5, -1.0), neck + Vector2(1.0, 4.5)]), tint)
		Kind.MUSHROOM:
			draw_rect(Rect2(c + Vector2(-3, -1), Vector2(6, 14)), tint, true)
			# The cap is a fan rather than a half-circle primitive so it can be
			# a shallow dome instead of a semicircle.
			var cap := PackedVector2Array()
			for i in 13:
				var t := float(i) / 12.0
				var angle := PI + t * PI
				cap.append(c + Vector2(cos(angle) * 15.0, sin(angle) * 11.0 - 1.0))
			cap.append(c + Vector2(15, -1))
			draw_colored_polygon(cap, tint)
		Kind.LURE:
			draw_circle(c + Vector2(0, 2), 7.0, tint)
			for i in 6:
				var angle := TAU * float(i) / 6.0
				var dir := Vector2(cos(angle), sin(angle))
				draw_line(c + Vector2(0, 2) + dir * 8.0,
					c + Vector2(0, 2) + dir * 13.0, tint, 2.0)
