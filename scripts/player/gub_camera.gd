class_name GubCamera
extends Node3D
## Third-person camera rig. Lives under a `Gub`, and only wakes up for the Gub
## the local player owns.
##
## Structure: this node yaws, the `SpringArm3D` under it pitches and pulls the
## camera in when scenery gets between it and the Gub, and the `Camera3D` sits
## off to one side so the Gub does not cover the crosshair.
##
## The rig follows the body's *position* but never its rotation — the body's
## facing is a consequence of where you are moving, not of where you are
## looking, so binding the two together would make the camera lurch every time
## the Gub turned to run somewhere.
##
## While the owner is dead it can follow somebody else instead (PLAN 6.5). That
## is deliberately a change of *subject* rather than a second camera: the spring
## arm, the collision mask, the mouse look and the shake are all already solved
## here, and a separate spectator rig would have to solve them again and then
## drift out of step with this one. A dead Gub's node is only hidden, never
## freed, so its rig is still alive and still holds the viewport — pointing it at
## a living Gub is the whole of the feature.

const PITCH_MIN := -1.20   # ~-69 degrees, looking down
const PITCH_MAX := 0.95    # ~54 degrees, looking up

const DISTANCE_DEFAULT := 3.6
const DISTANCE_AIMING := 2.4
const SHOULDER_DEFAULT := 0.62
const SHOULDER_AIMING := 0.48
const FOV_AIM_SCALE := 0.82

## The rig eases toward the Gub instead of being glued to it, so single-frame
## physics corrections (a step, a slide along a wall) do not jolt the view.
const FOLLOW_SPEED := 22.0
const ZOOM_SPEED := 8.0

## Radians per pixel at a sensitivity setting of 1.0.
const SENSITIVITY_SCALE := 0.0022

@onready var _arm: SpringArm3D = $SpringArm3D
@onready var _camera: Camera3D = $SpringArm3D/Camera3D

var _body: Gub
var _yaw: float = 0.0
var _pitch: float = -0.12
var _distance: float = DISTANCE_DEFAULT
var _shoulder: float = SHOULDER_DEFAULT
var _base_fov: float = 75.0
var _shake_strength: float = 0.0
var _shake_decay: float = 6.0
var _aiming: bool = false
## Whose shoulder we are watching over while dead. Null means our own Gub.
var _spectating: Gub = null


func _ready() -> void:
	_body = get_parent() as Gub
	if _body == null:
		push_error("GubCamera expects to be a child of a Gub")
		return

	if not _body.is_local():
		# A remote Gub still carries a rig (it is part of the scene), but it must
		# not steal the viewport or read the mouse.
		set_process(false)
		set_process_unhandled_input(false)
		_camera.current = false
		return

	_base_fov = float(Settings.get_value("fov"))
	_camera.current = true
	_arm.spring_length = _distance
	# The arm must be stopped by the world and by anything explicitly marked as
	# a camera blocker, but never by players — clipping to a team-mate standing
	# behind you is worse than seeing through them.
	_arm.collision_mask = 1 | 64
	_arm.margin = 0.28
	Settings.changed.connect(_on_setting_changed)


func _on_setting_changed(key: String, value: Variant) -> void:
	if key == "fov":
		_base_fov = float(value)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion):
		return
	if SceneFlow.cursor_is_free():
		return
	var motion := event as InputEventMouseMotion
	var sensitivity := float(Settings.get_value("mouse_sensitivity")) * SENSITIVITY_SCALE
	if _aiming:
		# Aiming narrows the field of view; without matching the sensitivity to
		# it, the same hand movement would sweep further across the world.
		sensitivity *= FOV_AIM_SCALE
	_yaw -= motion.relative.x * sensitivity
	var pitch_delta := motion.relative.y * sensitivity
	if bool(Settings.get_value("invert_y")):
		pitch_delta = -pitch_delta
	_pitch = clampf(_pitch - pitch_delta, PITCH_MIN, PITCH_MAX)


func _process(delta: float) -> void:
	if _body == null:
		return

	_aiming = Input.is_action_pressed("aim") and _body.alive and _spectating == null
	_follow(delta)
	_apply_zoom(delta)
	_apply_shake(delta)

	rotation.y = _yaw
	_arm.rotation.x = _pitch

	# Hand the body a view basis so WASD is relative to where you are looking,
	# and tell it to face the camera while aiming so a throw goes to the
	# crosshair rather than to wherever the Gub happened to be running.
	# Not while spectating: the corpse is not ours to steer, and turning the view
	# would spin a body somebody else is still watching.
	if _spectating == null:
		_body.set_view_basis(global_transform.basis, _aiming or _body_is_throwing())


func _body_is_throwing() -> bool:
	var animator := _body.get_node_or_null("AnimationTree") as GubAnimator
	return animator != null and animator.is_throwing()


## The Gub the rig is currently framing — the one we are spectating if that Gub
## is still around, and our own otherwise. A spectated Gub can be freed out from
## under us (they leave, the match resets), so this is checked every frame rather
## than trusted once.
func _subject() -> Gub:
	if _spectating != null and is_instance_valid(_spectating):
		return _spectating
	return _body


## Watch `target` instead of our own Gub. Pass null to go back to our own.
func spectate(target: Gub) -> void:
	_spectating = target if target != _body else null


func spectating() -> Gub:
	return _spectating if is_instance_valid(_spectating) else null


func _follow(delta: float) -> void:
	var subject := _subject()
	var target := subject.global_position + Vector3.UP * subject.eye_height()
	# Vertical follow is slower than horizontal: stairs and small bumps should
	# not pump the camera up and down.
	var next := global_position
	next.x = lerpf(next.x, target.x, clampf(FOLLOW_SPEED * delta, 0.0, 1.0))
	next.z = lerpf(next.z, target.z, clampf(FOLLOW_SPEED * delta, 0.0, 1.0))
	next.y = lerpf(next.y, target.y, clampf(FOLLOW_SPEED * 0.55 * delta, 0.0, 1.0))
	global_position = next


func _apply_zoom(delta: float) -> void:
	var want_distance := DISTANCE_AIMING if _aiming else DISTANCE_DEFAULT
	var want_shoulder := SHOULDER_AIMING if _aiming else SHOULDER_DEFAULT
	var want_fov := _base_fov * (FOV_AIM_SCALE if _aiming else 1.0)

	var t := clampf(ZOOM_SPEED * delta, 0.0, 1.0)
	_distance = lerpf(_distance, want_distance, t)
	_shoulder = lerpf(_shoulder, want_shoulder, t)
	_arm.spring_length = _distance
	_camera.fov = lerpf(_camera.fov, want_fov, t)
	_camera.position.x = _shoulder


## Called on kills, hard landings and nearby impacts.
func shake(strength: float, decay: float = 6.0) -> void:
	_shake_strength = maxf(_shake_strength, strength * float(Settings.get_value("camera_shake")))
	_shake_decay = decay


func _apply_shake(delta: float) -> void:
	if _shake_strength <= 0.0001:
		_camera.h_offset = 0.0
		_camera.v_offset = 0.0
		return
	_shake_strength = maxf(0.0, _shake_strength - _shake_decay * _shake_strength * delta)
	_camera.h_offset = randf_range(-1.0, 1.0) * _shake_strength * 0.06
	_camera.v_offset = randf_range(-1.0, 1.0) * _shake_strength * 0.06


## World-space ray the crosshair is pointing down. Everything the player throws
## is aimed with this, so the spear goes where the reticle is rather than where
## the Gub's hand happens to be.
func aim_ray() -> Dictionary:
	var viewport := get_viewport()
	var centre := viewport.get_visible_rect().size * 0.5
	return {
		"origin": _camera.project_ray_origin(centre),
		"direction": _camera.project_ray_normal(centre),
	}


## Swing the rig until the crosshair is on `point`.
##
## Solved from the *camera's* position rather than the rig's, because the camera
## sits behind and to one side: aiming the rig at a target leaves the crosshair a
## shoulder-width off it at every distance. Moving the rig moves the camera, so
## one call gets close and calling it again on the next frame converges — which
## is what the scripted testbeds do.
func look_at_point(point: Vector3) -> void:
	var to := point - _camera.global_position
	if to.length_squared() < 0.0001:
		return
	to = to.normalized()
	_yaw = atan2(-to.x, -to.z)
	_pitch = clampf(asin(clampf(to.y, -1.0, 1.0)), PITCH_MIN, PITCH_MAX)


func camera() -> Camera3D:
	return _camera


func yaw() -> float:
	return _yaw


func pitch() -> float:
	return _pitch
