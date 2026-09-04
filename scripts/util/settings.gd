extends Node
## Local, per-machine preferences. Never replicated — these are this player's
## own display/input/audio choices plus the name they last used.
##
## Autoloaded as `Settings`.

const CONFIG_PATH := "user://settings.cfg"

signal changed(key: String, value: Variant)

const DEFAULTS := {
	# identity
	"player_name": "",
	"last_invite_code": "",
	# input
	"mouse_sensitivity": 0.25,
	"invert_y": false,
	# view
	"fov": 75.0,
	"camera_shake": 1.0,
	# audio (linear 0..1, converted to dB when applied)
	"volume_master": 0.9,
	"volume_music": 0.5,
	"volume_sfx": 1.0,
	"volume_ambience": 0.7,
	# video
	"quality": 2,  # 0 low, 1 medium, 2 high
	"vsync": true,
	"fullscreen": false,
}

var _values: Dictionary = DEFAULTS.duplicate(true)


func _ready() -> void:
	load_from_disk()
	apply_video()


func get_value(key: String) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	if _values.get(key) == value:
		return
	_values[key] = value
	changed.emit(key, value)
	save_to_disk()


## A display name that is always safe to show above a Gub's head.
func sanitized_player_name() -> String:
	var raw := String(get_value("player_name")).strip_edges()
	if raw.is_empty():
		return "Gub"
	# Collapse whitespace and clamp length so nameplates stay readable.
	var collapsed := ""
	var last_was_space := false
	for c in raw:
		var is_space := c == " " or c == "\t"
		if is_space and last_was_space:
			continue
		collapsed += " " if is_space else c
		last_was_space = is_space
	return collapsed.substr(0, 16).strip_edges()


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for key: String in DEFAULTS:
		if cfg.has_section_key("settings", key):
			_values[key] = cfg.get_value("settings", key)


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	for key: String in _values:
		cfg.set_value("settings", key, _values[key])
	cfg.save(CONFIG_PATH)


func apply_video() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if get_value("vsync") else DisplayServer.VSYNC_DISABLED
	)
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if get_value("fullscreen")
		else DisplayServer.WINDOW_MODE_WINDOWED
	)
