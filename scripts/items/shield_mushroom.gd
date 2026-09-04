class_name ShieldMushroom
extends StaticBody3D
## A mushroom a Gub plants in front of itself to hide behind.
##
## It is solid to spears and to Gubs alike, which is the whole point: it stops a
## throw *and* it stops you walking through your own cover, so committing to one
## costs you mobility. It is not destructible — a spear thrown into it sticks and
## is simply spent. Making cover breakable would turn every fight into whoever
## has more spears, and the spear recharge is already the scarcity dial.
##
## Placement is validated by `GubCombat._mushroom_spot`, so by the time one of
## these exists it is standing on real ground.

const MODEL := preload("res://art/generated/mushroom.glb")

const LAYER_DEPLOYABLE := 8
## Blocks nothing itself — it is static. The Gub and the spear both include the
## deployable layer in their masks, which is what makes it cover.
const MASK_NONE := 0

## Mushrooms erupt rather than fade in. A shield that is not solid the instant
## you press the button is a shield that gets you killed, so the collision is
## live immediately and only the visual grows.
const GROW_TIME := 0.28
const WITHER_TIME := 0.45

## Collision is two cylinders rather than the 10k-triangle mesh: a fat cap to
## catch spears and a thin stem so a Gub can stand close and still peek round it.
const STEM_RADIUS := 0.22
const STEM_HEIGHT := 1.45
const CAP_RADIUS := 0.82
const CAP_HEIGHT := 0.46
const CAP_CENTRE_Y := 1.72

var owner_peer_id: int = 0

var _model: Node3D
var _lifetime: float = 25.0
var _age: float = 0.0
var _withering: bool = false


func plant(spot: Vector3, yaw: float, lifetime: float, planted_by: int) -> void:
	owner_peer_id = planted_by
	_lifetime = lifetime
	global_position = spot
	# A quarter turn of variation so a row of them does not look stamped out.
	rotation.y = yaw + randf_range(-0.5, 0.5)

	collision_layer = LAYER_DEPLOYABLE
	collision_mask = MASK_NONE
	_build_collision()

	_model = MODEL.instantiate() as Node3D
	add_child(_model)
	_model.scale = Vector3(0.15, 0.02, 0.15)
	var grow := create_tween()
	grow.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	grow.tween_property(_model, "scale", Vector3.ONE, GROW_TIME)


func _build_collision() -> void:
	var stem := CollisionShape3D.new()
	var stem_shape := CylinderShape3D.new()
	stem_shape.radius = STEM_RADIUS
	stem_shape.height = STEM_HEIGHT
	stem.shape = stem_shape
	stem.position = Vector3(0.0, STEM_HEIGHT * 0.5, 0.0)
	add_child(stem)

	var cap := CollisionShape3D.new()
	var cap_shape := CylinderShape3D.new()
	cap_shape.radius = CAP_RADIUS
	cap_shape.height = CAP_HEIGHT
	cap.shape = cap_shape
	cap.position = Vector3(0.0, CAP_CENTRE_Y, 0.0)
	add_child(cap)


func _process(delta: float) -> void:
	if _withering:
		return
	_age += delta
	if _age >= _lifetime:
		wither()


## Retract and disappear. Called when the lifetime runs out, when the planter
## exceeds their cap, or when a round ends.
func wither() -> void:
	if _withering:
		return
	_withering = true
	# Stop being cover the moment it starts collapsing, so nobody dies to a
	# spear that visibly passed through a shrinking stalk.
	collision_layer = 0
	if _model == null:
		queue_free()
		return
	var shrink := create_tween()
	shrink.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	shrink.tween_property(_model, "scale", Vector3(0.1, 0.01, 0.1), WITHER_TIME)
	shrink.tween_callback(queue_free)


func seconds_left() -> float:
	return maxf(0.0, _lifetime - _age)
