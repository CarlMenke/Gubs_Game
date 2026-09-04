extends Node
## Bus volumes and fire-and-forget sound playback. Autoloaded as `AudioDirector`.
##
## Gameplay code should never create its own AudioStreamPlayer for a one-shot:
## spear throws, hits and footsteps all fire in bursts, and a fresh node per
## sound means allocation churn plus a real chance of leaking players that never
## finish. Everything short goes through a fixed pool here instead.

const BUSES := {
	"volume_master": "Master",
	"volume_music": "Music",
	"volume_sfx": "SFX",
	"volume_ambience": "Ambience",
}

## Enough voices for a busy fight without ever growing at runtime.
const POOL_2D := 12
const POOL_3D := 24

var _pool_2d: Array[AudioStreamPlayer] = []
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _next_2d: int = 0
var _next_3d: int = 0


func _ready() -> void:
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool_2d.append(p)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.max_distance = 60.0
		p.unit_size = 6.0
		add_child(p)
		_pool_3d.append(p)

	Settings.changed.connect(_on_setting_changed)
	apply_all_volumes()


func _on_setting_changed(key: String, _value: Variant) -> void:
	if BUSES.has(key):
		apply_volume(key)


func apply_all_volumes() -> void:
	for key: String in BUSES:
		apply_volume(key)


func apply_volume(key: String) -> void:
	var bus_index := AudioServer.get_bus_index(BUSES[key])
	if bus_index < 0:
		return
	var linear := clampf(float(Settings.get_value(key)), 0.0, 1.0)
	AudioServer.set_bus_mute(bus_index, linear <= 0.001)
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(linear, 0.001)))


## Play a UI or non-positional sound.
func play_2d(stream: AudioStream, bus: String = "SFX", pitch: float = 1.0,
		volume_db: float = 0.0) -> void:
	if stream == null:
		return
	var p := _pool_2d[_next_2d]
	_next_2d = (_next_2d + 1) % _pool_2d.size()
	p.bus = bus
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = volume_db
	p.play()


## Play a sound at a world position. Returns the player so a caller can follow
## it to a moving source if it needs to; most callers should ignore it.
func play_3d(stream: AudioStream, position: Vector3, pitch: float = 1.0,
		volume_db: float = 0.0, bus: String = "SFX") -> AudioStreamPlayer3D:
	if stream == null:
		return null
	var p := _pool_3d[_next_3d]
	_next_3d = (_next_3d + 1) % _pool_3d.size()
	p.bus = bus
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = volume_db
	p.global_position = position
	p.play()
	return p


## Small random pitch variation so repeated sounds do not machine-gun.
func play_3d_varied(stream: AudioStream, position: Vector3, spread: float = 0.12,
		volume_db: float = 0.0) -> void:
	play_3d(stream, position, randf_range(1.0 - spread, 1.0 + spread), volume_db)
