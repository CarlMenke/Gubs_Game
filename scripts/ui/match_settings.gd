class_name MatchSettingsPanel
extends PanelContainer
## The host's match dials, and everyone else's read-only view of them (PLAN 1.4,
## 1.6). One panel serves both: clients get exactly the same rows with every
## control disabled, so what the host is choosing is never a mystery to the
## people waiting on it.
##
## Every edit goes straight out through `Net.update_config`, which is
## host-authoritative and rebroadcasts the whole config. This panel therefore
## never holds state of its own — it renders `Net.config` and asks for changes.
## The alternative, editing a local copy and pushing it on "Apply", means the
## lobby can show a setting nobody else has, which is precisely the confusion a
## shared config exists to prevent.
##
## Rows are generated from a table rather than authored, for the same reason the
## settings panel generates its own: eleven rows of label-control-readout is
## eleven chances to forget a theme variation.

## Rows that only make sense under some configurations. Hiding them beats
## disabling them: a greyed-out "Friendly fire" in a free-for-all invites the
## question of what it would do, and there is no good answer.
const TEAM_ONLY := ["team_count", "friendly_fire"]

@onready var _rows_root: VBoxContainer = %Rows
@onready var _summary: Label = %Summary
@onready var _host_only_hint: Label = %HostOnlyHint

## Built in code, so it cannot be reached through `%` — nodes added at runtime
## have no owner to register a unique name with.
var _seed_button: Button

## field name -> {"row": Control, "control": Control, "readout": Label}
var _fields: Dictionary = {}
## Set while widgets are being written from `Net.config`, so the change signals
## that causes do not bounce straight back out as edits.
var _applying: bool = false


func _ready() -> void:
	_build()
	Net.config_changed.connect(refresh)
	Net.roster_changed.connect(refresh)
	refresh()


func _build() -> void:
	_section("Mode")
	_choice("mode", "Match type", ["Free-for-all", "Teams"])
	_choice("team_count", "Teams", ["2", "3", "4", "5", "6", "7", "8"], 2)
	_choice("win_condition", "Ends on",
		["First to the kill limit", "Last Gub standing", "The clock"])

	_section("Limits")
	_slider("kill_limit", "Kill limit", 1, 50, 1, func(v: float) -> String:
		return "%d" % int(v))
	_slider("lives", "Lives each", 1, 15, 1, func(v: float) -> String:
		return "%d" % int(v))
	_slider("time_limit", "Time limit", 0, 1800, 30, func(v: float) -> String:
		return "No limit" if v <= 0.0 else UIPalette.clock(v))
	_toggle("friendly_fire", "Friendly fire")

	_section("Feel")
	# The single most important balance dial in the game: spears always kill, so
	# the recharge is what decides how punishing a miss is.
	_slider("spear_recharge", "Spear recharge", 0.5, 15.0, 0.1, func(v: float) -> String:
		return "%.1f s" % v)
	_slider("respawn_delay", "Respawn delay", 0.0, 10.0, 0.5, func(v: float) -> String:
		return "Instant" if v <= 0.0 else "%.1f s" % v)
	_slider("max_players", "Lobby size", MatchConfig.MIN_PLAYERS, MatchConfig.MAX_PLAYERS,
		1, func(v: float) -> String: return "%d Gubs" % int(v))

	_section("Map")
	_seed_row()


# --------------------------------------------------------------- refreshing ---

## Pull everything from `Net.config`. Called on load, on every broadcast from
## the host, and whenever the roster changes (the lobby-size floor moves with
## the number of people already in the room).
func refresh() -> void:
	_applying = true
	var config := Net.config
	for field: String in _fields:
		_write_field(field, config)
	_apply_visibility(config)
	_apply_editability()
	_summary.text = config.summary()
	_applying = false


func _write_field(field: String, config: MatchConfig) -> void:
	var entry: Dictionary = _fields[field]
	var control: Control = entry["control"]
	var value: Variant = config.get(field)
	if control is OptionButton:
		var picker := control as OptionButton
		picker.selected = clampi(int(value) - int(entry.get("offset", 0)),
			0, picker.item_count - 1)
	elif control is CheckButton:
		(control as CheckButton).set_pressed_no_signal(bool(value))
	elif control is HSlider:
		var slider := control as HSlider
		if field == "max_players":
			# Never offer a lobby size smaller than the number of people
			# already standing in it.
			slider.min_value = maxf(float(MatchConfig.MIN_PLAYERS),
				float(Net.player_count()))
		slider.set_value_no_signal(float(value))
		_write_readout(field, slider.value)
	elif control is Label:
		(control as Label).text = str(value)


func _write_readout(field: String, value: float) -> void:
	var entry: Dictionary = _fields[field]
	var readout: Label = entry.get("readout")
	if readout == null:
		return
	var formatter: Callable = entry["format"]
	readout.text = formatter.call(value)


## Show only the rows this configuration can act on.
func _apply_visibility(config: MatchConfig) -> void:
	var teams := config.mode == MatchConfig.Mode.TEAMS
	for field: String in TEAM_ONLY:
		_fields[field]["row"].visible = teams
	_fields["kill_limit"]["row"].visible = \
		config.win_condition == MatchConfig.WinCondition.KILL_LIMIT
	_fields["lives"]["row"].visible = \
		config.win_condition == MatchConfig.WinCondition.LIVES


func _apply_editability() -> void:
	var editable := Net.is_host
	for field: String in _fields:
		var control: Control = _fields[field]["control"]
		if control is BaseButton:
			(control as BaseButton).disabled = not editable
		elif control is HSlider:
			(control as HSlider).editable = editable
	if _seed_button != null:
		_seed_button.disabled = not editable
	_host_only_hint.visible = not editable


# ------------------------------------------------------------------ editing ---

## Copy the current config, change one field, and push the whole thing. Sending
## the whole config rather than a delta is what `Net.update_config` expects, and
## with twenty-one primitives it is a few hundred bytes.
func _push(field: String, value: Variant) -> void:
	if _applying or not Net.is_host:
		return
	var next := Net.config.duplicate_config()
	next.set(field, value)
	Net.update_config(next)


# --------------------------------------------------------------------- rows ---

func _section(title: String) -> void:
	if _rows_root.get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size.y = 10
		_rows_root.add_child(gap)
	var label := Label.new()
	label.theme_type_variation = "SectionLabel"
	label.text = title.to_upper()
	_rows_root.add_child(label)
	_rows_root.add_child(HSeparator.new())


func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.custom_minimum_size.y = 28
	var label := Label.new()
	label.text = label_text
	label.theme_type_variation = "DimLabel"
	label.custom_minimum_size.x = 168
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	_rows_root.add_child(row)
	return row


func _slider(field: String, label_text: String, low: float, high: float, step: float,
		formatter: Callable) -> void:
	var row := _row(label_text)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size.y = 18
	row.add_child(slider)

	var readout := Label.new()
	readout.theme_type_variation = "AccentLabel"
	readout.custom_minimum_size.x = 92
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(readout)

	_fields[field] = {"row": row, "control": slider, "readout": readout,
		"format": formatter}
	slider.value_changed.connect(func(value: float) -> void:
		_write_readout(field, value)
		# Ints on the wire for int fields: `MatchConfig.apply_dict` will coerce
		# either way, but sending 14.999999 for a kill limit is asking for it.
		_push(field, int(value) if step >= 1.0 and absf(step - roundf(step)) < 0.001
			else value))


func _choice(field: String, label_text: String, options: Array,
		offset: int = 0) -> void:
	var row := _row(label_text)
	var picker := OptionButton.new()
	for i in options.size():
		picker.add_item(String(options[i]), i)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(picker)
	_fields[field] = {"row": row, "control": picker, "offset": offset,
		"format": func(_v: float) -> String: return ""}
	picker.item_selected.connect(func(index: int) -> void:
		_push(field, index + offset))


func _toggle(field: String, label_text: String) -> void:
	var row := _row(label_text)
	var toggle := CheckButton.new()
	toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(toggle)
	_fields[field] = {"row": row, "control": toggle,
		"format": func(_v: float) -> String: return ""}
	toggle.toggled.connect(func(on: bool) -> void: _push(field, on))


## The island is generated from this number and every client builds the same map
## from it (D-007), so it is worth showing rather than hiding: "we all got a bad
## map" and "reroll it" are the same conversation.
func _seed_row() -> void:
	var row := _row("Island seed")
	var value := Label.new()
	value.theme_type_variation = "AccentLabel"
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)

	var button := Button.new()
	button.theme_type_variation = "GhostButton"
	button.text = "Reroll"
	row.add_child(button)
	_seed_button = button

	_fields["map_seed"] = {"row": row, "control": value,
		"format": func(_v: float) -> String: return ""}
	button.pressed.connect(func() -> void:
		_push("map_seed", randi_range(1, 99999999)))
