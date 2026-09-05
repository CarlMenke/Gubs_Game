class_name SettingsPanel
extends Control
## The settings overlay (PLAN 6.4). One scene, opened from the main menu and
## from the pause menu, so the two can never drift apart.
##
## The rows are built in code rather than authored as thirty nodes: every one of
## them is the same shape — a label, a control, a live readout — and as scene
## nodes that is thirty places to forget a theme variation. The scene holds the
## frame (scrim, card, header, footer); this holds the list.
##
## Every control writes straight through to `Settings`, which persists on each
## change and emits `changed`. Nothing here caches: the panel is a view onto
## `Settings`, and closing it is not a "save".

signal closed()

## Quality presets are applied here, on the viewport, rather than by writing
## project settings: these are per-machine display choices, and a viewport
## property can be turned back down again the moment the player changes their
## mind. Fields are MSAA, screen-space AA, and the 3D render scale.
const QUALITY_PRESETS := [
	{"msaa": Viewport.MSAA_DISABLED, "ssaa": Viewport.SCREEN_SPACE_AA_DISABLED, "scale": 0.77},
	{"msaa": Viewport.MSAA_2X, "ssaa": Viewport.SCREEN_SPACE_AA_FXAA, "scale": 1.0},
	{"msaa": Viewport.MSAA_4X, "ssaa": Viewport.SCREEN_SPACE_AA_FXAA, "scale": 1.0},
]

## Shown as a reference, not as a rebinding UI — see the class note in
## `docs/DECISIONS.md` D-016. Order is the order a new player needs them in.
const CONTROL_REFERENCE: Array[Array] = [
	["Move", "move_forward"],
	["Sprint", "sprint"],
	["Crouch / slide", "crouch"],
	["Jump", "jump"],
	["Throw spear", "throw_spear"],
	["Aim", "aim"],
	["Plant mushroom", "place_mushroom"],
	["Throw lure", "throw_lure"],
	["Scoreboard", "scoreboard"],
	["Chat", "chat"],
	["Pause", "pause"],
]

const MOUSE_BUTTON_NAMES := {
	MOUSE_BUTTON_LEFT: "Left Mouse",
	MOUSE_BUTTON_RIGHT: "Right Mouse",
	MOUSE_BUTTON_MIDDLE: "Middle Mouse",
	MOUSE_BUTTON_WHEEL_UP: "Wheel Up",
	MOUSE_BUTTON_WHEEL_DOWN: "Wheel Down",
}

## The same buttons for a key cap sixty pixels wide. "Left Mouse" spills out of
## an ability slot and "LMB" is what everyone calls it anyway.
const MOUSE_BUTTON_CAPS := {
	MOUSE_BUTTON_LEFT: "LMB",
	MOUSE_BUTTON_RIGHT: "RMB",
	MOUSE_BUTTON_MIDDLE: "MMB",
	MOUSE_BUTTON_WHEEL_UP: "WH+",
	MOUSE_BUTTON_WHEEL_DOWN: "WH-",
}

@onready var _sections: VBoxContainer = %Sections
@onready var _done: Button = %DoneButton
@onready var _reset: Button = %ResetButton
@onready var _close: Button = %CloseButton

## Rebuilt rows would lose the slider being dragged, so readouts are refreshed
## in place. key -> the Label showing the current value.
var _readouts: Dictionary = {}


func _ready() -> void:
	visible = false
	_build()
	_done.pressed.connect(close)
	_close.pressed.connect(close)
	_reset.pressed.connect(_restore_defaults)
	Settings.changed.connect(_on_setting_changed)
	apply_quality(int(Settings.get_value("quality")))


func open() -> void:
	visible = true
	_refresh_all()
	# Grab focus so the panel owns the keyboard: without this, Escape and the
	# arrow keys still reach whatever opened it.
	_done.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _gui_input(event: InputEvent) -> void:
	# Swallowed rather than left to propagate, so closing settings from inside
	# the pause menu does not also close the pause menu behind it.
	if visible and event.is_action_pressed("pause"):
		accept_event()
		close()


# ------------------------------------------------------------------- rows ---

func _build() -> void:
	_section("Input")
	_slider_row("Mouse sensitivity", "mouse_sensitivity", 0.05, 1.50, 0.01, "%.2f")
	_toggle_row("Invert vertical look", "invert_y")

	_section("View")
	_slider_row("Field of view", "fov", 60.0, 110.0, 1.0, "%.0f")
	_slider_row("Camera shake", "camera_shake", 0.0, 1.5, 0.05, "%d%%", 100.0)

	_section("Audio")
	_slider_row("Master", "volume_master", 0.0, 1.0, 0.01, "%d%%", 100.0)
	_slider_row("Music", "volume_music", 0.0, 1.0, 0.01, "%d%%", 100.0)
	_slider_row("Effects", "volume_sfx", 0.0, 1.0, 0.01, "%d%%", 100.0)
	_slider_row("Ambience", "volume_ambience", 0.0, 1.0, 0.01, "%d%%", 100.0)

	_section("Video")
	_choice_row("Quality", "quality", ["Low", "Medium", "High"])
	_toggle_row("V-Sync", "vsync")
	_toggle_row("Fullscreen", "fullscreen")

	_section("Controls")
	for entry: Array in CONTROL_REFERENCE:
		_reference_row(entry[0], entry[1])
	var note := Label.new()
	note.theme_type_variation = "TinyLabel"
	note.text = "Rebinding is not wired up yet; these are the defaults."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sections.add_child(note)


func _section(title: String) -> void:
	if _sections.get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size.y = 18
		_sections.add_child(gap)
	var label := Label.new()
	label.theme_type_variation = "SectionLabel"
	label.text = title.to_upper()
	_sections.add_child(label)
	_sections.add_child(HSeparator.new())


## Every row is the same three-column shape, so alignment holds down the whole
## panel without a single hand-set margin.
func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.custom_minimum_size.y = 34
	var label := Label.new()
	label.text = label_text
	label.theme_type_variation = "DimLabel"
	label.custom_minimum_size.x = 230
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	_sections.add_child(row)
	return row


func _slider_row(label_text: String, key: String, low: float, high: float,
		step: float, format: String, display_scale: float = 1.0) -> void:
	var row := _row(label_text)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.value = float(Settings.get_value(key))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size.y = 18
	row.add_child(slider)

	var readout := Label.new()
	readout.theme_type_variation = "AccentLabel"
	readout.custom_minimum_size.x = 66
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(readout)
	readout.set_meta("format", format)
	readout.set_meta("scale", display_scale)
	_readouts[key] = readout
	_write_readout(key, slider.value)

	slider.value_changed.connect(func(value: float) -> void:
		Settings.set_value(key, value)
		_write_readout(key, value))


func _toggle_row(label_text: String, key: String) -> void:
	var row := _row(label_text)
	var toggle := CheckButton.new()
	toggle.button_pressed = bool(Settings.get_value(key))
	toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(toggle)
	_readouts[key] = toggle
	toggle.toggled.connect(func(on: bool) -> void:
		Settings.set_value(key, on)
		# Vsync and fullscreen only take effect when something applies them.
		if key == "vsync" or key == "fullscreen":
			Settings.apply_video())


func _choice_row(label_text: String, key: String, options: Array) -> void:
	var row := _row(label_text)
	var picker := OptionButton.new()
	for i in options.size():
		picker.add_item(String(options[i]), i)
	picker.selected = clampi(int(Settings.get_value(key)), 0, options.size() - 1)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(picker)
	_readouts[key] = picker
	picker.item_selected.connect(func(index: int) -> void:
		Settings.set_value(key, index)
		if key == "quality":
			apply_quality(index))


func _reference_row(label_text: String, action: String) -> void:
	var row := _row(label_text)
	var keys := Label.new()
	keys.theme_type_variation = "SmallLabel"
	keys.text = describe_action(action)
	keys.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(keys)


# --------------------------------------------------------------- refreshing ---

func _write_readout(key: String, value: float) -> void:
	var readout := _readouts.get(key) as Label
	if readout == null:
		return
	var scaled := value * float(readout.get_meta("scale", 1.0))
	var format := String(readout.get_meta("format", "%.2f"))
	readout.text = format % (int(round(scaled)) if format.contains("%d") else scaled)


func _refresh_all() -> void:
	for key: String in _readouts:
		_sync_control(key)


func _on_setting_changed(key: String, _value: Variant) -> void:
	if visible:
		_sync_control(key)


## Push a value from `Settings` back into whatever control shows it. Needed
## because "Reset to defaults" changes eleven settings at once and every one of
## them has a widget still displaying the old number.
func _sync_control(key: String) -> void:
	var node: Variant = _readouts.get(key)
	var value: Variant = Settings.get_value(key)
	if node is CheckButton:
		(node as CheckButton).set_pressed_no_signal(bool(value))
	elif node is OptionButton:
		(node as OptionButton).selected = int(value)
	elif node is Label:
		_write_readout(key, float(value))
		# The slider is the readout's left-hand sibling; find it rather than
		# keeping a second dictionary of the same rows.
		var row := (node as Label).get_parent()
		for child in row.get_children():
			if child is HSlider:
				(child as HSlider).set_value_no_signal(float(value))


func _restore_defaults() -> void:
	for key: String in Settings.DEFAULTS:
		# Identity is not a display setting; wiping the name someone typed
		# because they nudged a volume slider would be its own bug.
		if key == "player_name" or key == "last_invite_code":
			continue
		Settings.set_value(key, Settings.DEFAULTS[key])
	Settings.apply_video()
	apply_quality(int(Settings.get_value("quality")))
	_refresh_all()


# ----------------------------------------------------------------- quality ---

## Apply a preset to the current viewport. Public because the pause menu and the
## menu both open this panel, and whichever one is first should still leave the
## renderer matching what the player last chose.
func apply_quality(level: int) -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var preset: Dictionary = QUALITY_PRESETS[clampi(level, 0, QUALITY_PRESETS.size() - 1)]
	viewport.msaa_3d = preset["msaa"]
	viewport.screen_space_aa = preset["ssaa"]
	viewport.scaling_3d_scale = preset["scale"]


# ------------------------------------------------------------------ helpers ---

## The keys and buttons bound to an action, as something readable. Used by the
## settings reference and by the HUD, which labels each ability slot with the
## key that fires it rather than hard-coding "Q" and hoping.
static func describe_action(action: String) -> String:
	if not InputMap.has_action(action):
		return "-"
	var names: Array[String] = []
	for event: InputEvent in InputMap.action_get_events(action):
		var text := describe_event(event)
		if not text.is_empty() and not names.has(text):
			names.append(text)
	return " / ".join(names) if not names.is_empty() else "-"


## The shortest label for one binding. Keys are reported by *physical* code, the
## way the input map stores them, so a WASD binding still says W on a keyboard
## whose layout would otherwise make it Z.
static func describe_event(event: InputEvent, short: bool = false) -> String:
	if event is InputEventKey:
		var key := event as InputEventKey
		var code := key.physical_keycode if key.physical_keycode != 0 else key.keycode
		return OS.get_keycode_string(
			DisplayServer.keyboard_get_keycode_from_physical(code))
	if event is InputEventMouseButton:
		var button := (event as InputEventMouseButton).button_index
		var table: Dictionary = MOUSE_BUTTON_CAPS if short else MOUSE_BUTTON_NAMES
		return table.get(button, "Mouse %d" % button)
	if event is InputEventJoypadButton:
		return "Pad %d" % (event as InputEventJoypadButton).button_index
	return ""


## The first binding only, abbreviated, for a HUD key cap where there is room
## for about three characters.
static func primary_key(action: String) -> String:
	if not InputMap.has_action(action):
		return "?"
	for event: InputEvent in InputMap.action_get_events(action):
		var text := describe_event(event, true)
		if not text.is_empty():
			return text
	return "?"
