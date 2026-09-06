extends Node3D

## The viewmodel lab: press a clip, watch it play, see what fires.
##
## Its only job is to prove the round trip. If a clip looks in Godot exactly
## the way it looked in Blender, and its events, sounds and magnets land on
## the same frames, the pipeline is honest. When something is off, this scene
## is where you find out which of the three it was.
##
## No player, no shooting, no game logic - that comes later, once there is
## animation worth driving.

## Roughly where the hands hold a weapon, in Godot axes: Blender +Y forward
## becomes -Z, Blender +Z up becomes +Y.
const ORBIT_FOCUS := Vector3(0.0, -0.12, -0.45)
const STUB_COLOR := Color(0.55, 0.55, 0.6)
const LIVE_COLOR := Color(0.95, 0.95, 1.0)

@onready var viewmodel: PFViewmodel = $Viewmodel
@onready var camera: Camera3D = $Camera3D

var _asset_picker: OptionButton
var _clip_list: ItemList
var _log: RichTextLabel
var _scrub: HSlider
var _time_label: Label
var _status: Label
var _loop_toggle: CheckBox
var _stub_toggle: CheckBox
var _sockets_toggle: CheckBox
var _speed: HSlider

var _clips: PackedStringArray = []
var _scrubbing := false
var _cam_socket: Node3D = null
var _cam_toggle: CheckBox
var _orbit_yaw := 0.35
var _orbit_pitch := 0.25
var _orbit_distance := 0.85
var _paused := false


func _ready() -> void:
	_build_ui()
	_place_orbit()
	viewmodel.clip_event.connect(_on_event)
	viewmodel.attach_changed.connect(_on_attach)
	viewmodel.clip_started.connect(func(c: String) -> void: _say("[b]play[/b] %s" % c, Color.SKY_BLUE))
	viewmodel.clip_finished.connect(func(c: String) -> void: _say("end  %s" % c, Color.DIM_GRAY))
	viewmodel.equipped.connect(_on_equipped)
	_refresh_assets()


# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var left := PanelContainer.new()
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.custom_minimum_size = Vector2(280, 0)
	left.offset_right = 280
	layer.add_child(left)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	left.add_child(column)

	column.add_child(_heading("Asset"))
	_asset_picker = OptionButton.new()
	_asset_picker.item_selected.connect(_on_asset_picked)
	column.add_child(_asset_picker)

	_stub_toggle = CheckBox.new()
	_stub_toggle.text = "Show stubs (not animated yet)"
	_stub_toggle.toggled.connect(func(_v: bool) -> void: _refresh_clips())
	column.add_child(_stub_toggle)

	_sockets_toggle = CheckBox.new()
	_sockets_toggle.text = "Show sockets"
	_sockets_toggle.toggled.connect(_on_sockets_toggled)
	column.add_child(_sockets_toggle)

	_loop_toggle = CheckBox.new()
	_loop_toggle.text = "Repeat clip"
	column.add_child(_loop_toggle)

	_cam_toggle = CheckBox.new()
	_cam_toggle.text = "Look through SK.cam"
	_cam_toggle.toggled.connect(func(_v: bool) -> void: _apply_camera_mode())
	column.add_child(_cam_toggle)

	column.add_child(_label("RMB orbit, wheel zoom"))
	column.add_child(_label("Space pause, . and , step a frame"))

	column.add_child(_heading("Clips"))
	_clip_list = ItemList.new()
	_clip_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_clip_list.custom_minimum_size = Vector2(0, 380)
	_clip_list.item_activated.connect(_on_clip_chosen)
	_clip_list.item_selected.connect(_on_clip_chosen)
	column.add_child(_clip_list)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 48)
	column.add_child(_status)

	# transport
	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 290
	bottom.offset_top = -78
	layer.add_child(bottom)

	var bar := VBoxContainer.new()
	bottom.add_child(bar)
	var row := HBoxContainer.new()
	bar.add_child(row)

	var play := Button.new()
	play.text = "Play"
	play.pressed.connect(_on_play)
	row.add_child(play)

	var pause := Button.new()
	pause.text = "Pause"
	pause.pressed.connect(func() -> void: _set_paused(not _paused))
	row.add_child(pause)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(150, 0)
	row.add_child(_time_label)

	row.add_child(_label("speed"))
	_speed = HSlider.new()
	_speed.min_value = 0.05
	_speed.max_value = 2.0
	_speed.step = 0.05
	_speed.value = 1.0
	_speed.custom_minimum_size = Vector2(140, 0)
	_speed.value_changed.connect(func(v: float) -> void:
		if not _paused:
			viewmodel.set_speed(v))
	row.add_child(_speed)

	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.001
	_scrub.drag_started.connect(func() -> void: _scrubbing = true)
	_scrub.drag_ended.connect(func(_c: bool) -> void: _scrubbing = false)
	_scrub.value_changed.connect(_on_scrub)
	bar.add_child(_scrub)

	# event log
	var right := PanelContainer.new()
	right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right.offset_left = -340
	right.offset_bottom = -80
	layer.add_child(right)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	right.add_child(_log)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	return label


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


# --- content --------------------------------------------------------------

func _refresh_assets() -> void:
	_asset_picker.clear()
	var ids := viewmodel.available_assets()
	if ids.is_empty():
		_say("[color=red]content/fps_contract.json has no assets. "
			+ "Export from Blender first.[/color]")
		return
	for id in ids:
		_asset_picker.add_item(id)
	_asset_picker.select(0)
	_on_asset_picked(0)


func _on_asset_picked(index: int) -> void:
	var id := _asset_picker.get_item_text(index)
	_say("equip %s" % id, Color.WEB_GREEN)
	viewmodel.equip(id)


func _on_equipped(_id: String) -> void:
	_refresh_clips()
	_attach_camera()
	_on_sockets_toggled(_sockets_toggle.button_pressed)
	var manifest := viewmodel.asset_manifest
	if manifest != null:
		_status.text = manifest.describe()
		for warning in manifest.warnings:
			_say("[color=orange]%s[/color]" % warning)


func _refresh_clips() -> void:
	_clip_list.clear()
	var manifest := viewmodel.asset_manifest
	if manifest == null:
		return
	_clips = manifest.clip_ids(_stub_toggle.button_pressed)
	for clip_id in _clips:
		var record := manifest.clip(clip_id)
		var stub := bool(record.get("stub", false))
		var text := "%s   %.2fs" % [clip_id, float(record.get("length", 0.0))]
		var marks := ""
		if not record.get("events", []).is_empty():
			marks += " e%d" % record["events"].size()
		if not record.get("sounds", []).is_empty():
			marks += " s%d" % record["sounds"].size()
		if not record.get("attach", []).is_empty():
			marks += " m%d" % record["attach"].size()
		var index := _clip_list.add_item(text + marks)
		_clip_list.set_item_custom_fg_color(index, STUB_COLOR if stub else LIVE_COLOR)
		_clip_list.set_item_disabled(index, stub)
		_clip_list.set_item_tooltip(index, String(record.get("notes", "")))
	# Land on something playable so the lab is never a blank screen: the first
	# clip that actually has keys.
	for index in _clip_list.item_count:
		if not _clip_list.is_item_disabled(index):
			_clip_list.select(index)
			_on_clip_chosen(index)
			_set_paused(true)
			viewmodel.seek(0.0)
			break


func _on_clip_chosen(index: int) -> void:
	if index < 0 or index >= _clips.size():
		return
	viewmodel.auto_advance = not _loop_toggle.button_pressed
	if not viewmodel.play(_clips[index]):
		_say("[color=orange]no animation bound for %s - it is still a stub[/color]"
			% _clips[index])


func _on_play() -> void:
	var selected := _clip_list.get_selected_items()
	if selected.is_empty():
		return
	_on_clip_chosen(selected[0])


func _on_scrub(value: float) -> void:
	if _scrubbing and viewmodel.is_playing():
		viewmodel.seek(value * viewmodel.length())


func _on_sockets_toggled(shown: bool) -> void:
	if viewmodel.rig != null:
		viewmodel.rig.debug_sockets = shown
	if viewmodel.asset != null:
		viewmodel.asset.debug_sockets = shown


func _attach_camera() -> void:
	_cam_socket = viewmodel.socket("cam")
	if _cam_toggle != null:
		_cam_toggle.disabled = _cam_socket == null
	_apply_camera_mode()


## Two ways to look at the viewmodel, and both are worth having.
##
## Free orbit is the lab camera: it exists to inspect, so it has to get behind
## the hands and under the magazine. SK.cam is the *shipping* framing - the
## bone the animator moves - and it is the only view that answers "is this what
## the player will see".
func _apply_camera_mode() -> void:
	var through_socket := _cam_toggle != null and _cam_toggle.button_pressed 		and _cam_socket != null
	var wanted: Node = _cam_socket if through_socket else self
	if camera.get_parent() != wanted:
		camera.get_parent().remove_child(camera)
		wanted.add_child(camera)
	if through_socket:
		# The socket bone points along its own +Y, the way Blender bones do.
		# A camera looks down -Z, so it needs a quarter turn to agree.
		camera.transform = Transform3D.IDENTITY
		camera.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	else:
		_place_orbit()


func _place_orbit() -> void:
	var offset := Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		sin(_orbit_pitch),
		cos(_orbit_yaw) * cos(_orbit_pitch)) * _orbit_distance
	camera.position = ORBIT_FOCUS + offset
	camera.look_at(ORBIT_FOCUS, Vector3.UP)


## Space pauses, comma and period step one 60 Hz frame. Stepping matters more
## than it sounds: comparing a Godot frame against the same Blender frame is
## the only way to tell "the export is wrong" from "the animation is wrong".
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			_set_paused(not _paused)
		KEY_COMMA:
			_step(-1.0 / 60.0)
		KEY_PERIOD:
			_step(1.0 / 60.0)
		KEY_HOME:
			_step(-viewmodel.position())


func _set_paused(paused: bool) -> void:
	_paused = paused
	viewmodel.set_speed(0.0 if paused else _speed.value)


func _step(seconds: float) -> void:
	_set_paused(true)
	viewmodel.seek(clampf(viewmodel.position() + seconds, 0.0, viewmodel.length()))


func _unhandled_input(event: InputEvent) -> void:
	if _cam_toggle != null and _cam_toggle.button_pressed:
		return
	if event is InputEventMouseMotion 			and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		_orbit_yaw -= event.relative.x * 0.008
		_orbit_pitch = clampf(_orbit_pitch + event.relative.y * 0.008, -1.4, 1.4)
		_place_orbit()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_distance = maxf(0.08, _orbit_distance * 0.9)
			_place_orbit()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_distance = minf(4.0, _orbit_distance * 1.1)
			_place_orbit()


func _process(_delta: float) -> void:
	if not viewmodel.current_clip.is_empty():
		var length := maxf(viewmodel.length(), 0.0001)
		if not _scrubbing:
			_scrub.set_value_no_signal(viewmodel.position() / length)
		_time_label.text = "%.2f / %.2f s" % [viewmodel.position(), length]
	if _loop_toggle.button_pressed and not viewmodel.is_playing() \
			and not viewmodel.current_clip.is_empty():
		viewmodel.play(viewmodel.current_clip)


func _on_event(event_name: String, args: Dictionary) -> void:
	var extra := "" if args.is_empty() else "  %s" % args
	_say("  [color=yellow]%s[/color]%s   @%.3f" % [event_name, extra, viewmodel.position()])


func _on_attach(part: String, socket_id: String, attached: bool) -> void:
	_say("  [color=aqua]%s[/color] %s %s   @%.3f"
		% [part, "->" if attached else "-x", socket_id, viewmodel.position()])


func _say(text: String, _color: Color = Color.WHITE) -> void:
	if _log != null:
		_log.append_text(text + "\n")
	print("[lab] " + text)
