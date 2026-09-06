class_name PFViewmodel
extends Node3D

## The first-person viewmodel: arms plus whatever is in them.
##
## Two scenes, one clip. The arms are the base rig and never change; the thing
## held is a proxy that swaps. A clip like `reload_empty` is a single Animation
## driving both skeletons, because the exporter merged the arms track and the
## weapon track under one NLA name - so there is no second player to keep in
## phase and no drift to debug.
##
## Everything this node knows comes out of the manifests. Adding a weapon, a
## socket or an event is a Blender-side edit plus an export; nothing here
## learns a new name.

signal clip_started(clip_id: String)
signal clip_finished(clip_id: String)
## `args` is whatever was typed into the event's Args field in Blender.
signal clip_event(event_name: String, args: Dictionary)
## Emitted where a part changes what it hangs off mid-clip. Acting on it is the
## game's business: most parts are proxy bones and need nothing.
signal attach_changed(part: String, socket_id: String, attached: bool)
signal equipped(asset_id: String)

@export var rig_id: String = "arms_base"
## Equip this on ready. Empty leaves the hands empty.
@export var start_asset: String = ""
@export var auto_advance: bool = true      ## follow each clip's `next`
@export var audio_voices: int = 8

var rig: PFAsset = null
var asset: PFAsset = null
var rig_manifest: PFManifest = null
var asset_manifest: PFManifest = null
var current_clip: String = ""

var _index: Dictionary = {}
var _player: AnimationPlayer = null
var _audio_root: Node3D = null
var _voices: Array[AudioStreamPlayer3D] = []
var _voice_next: int = 0

# Cue cursors for the clip being played. Kept as sorted arrays with an index
# rather than timers, so scrubbing and speed changes stay honest.
var _events: Array = []
var _sounds: Array = []
var _attach: Array = []
var _event_at: int = 0
var _sound_at: int = 0
var _attach_at: int = 0
var _last_position: float = 0.0


func _ready() -> void:
	_index = PFManifest.load_index()
	_player = AnimationPlayer.new()
	_player.name = "Anim"
	# ".." from the player is this node, which is what every track path in the
	# rebound library is measured from. Pointing it at the player itself makes
	# every path resolve to nothing and the skeletons sit in rest pose with no
	# error to show for it.
	_player.root_node = ^".."
	_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	add_child(_player)
	_player.animation_finished.connect(_on_finished)

	_audio_root = Node3D.new()
	_audio_root.name = "Audio"
	add_child(_audio_root)
	for i in audio_voices:
		var voice := AudioStreamPlayer3D.new()
		voice.name = "Voice%d" % i
		voice.unit_size = 3.0
		_audio_root.add_child(voice)
		_voices.append(voice)

	_load_rig()
	if not start_asset.is_empty():
		equip(start_asset)


# --- content --------------------------------------------------------------

func _manifest_path(asset_id: String) -> String:
	var row: Dictionary = _index.get(asset_id, {})
	return String(row.get("manifest", ""))


func _scene_path(asset_id: String) -> String:
	var row: Dictionary = _index.get(asset_id, {})
	var dir := String(row.get("dir", ""))
	return "" if dir.is_empty() else "%s/%s.tscn" % [dir, asset_id]


func available_assets() -> PackedStringArray:
	var out := PackedStringArray()
	for key: String in _index:
		if key != rig_id:
			out.append(key)
	out.sort()
	return out


func _load_rig() -> void:
	rig = _instance(rig_id, "Rig")
	rig_manifest = rig.manifest if rig != null else null


func _instance(asset_id: String, node_name: String) -> PFAsset:
	var path := _scene_path(asset_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("PFViewmodel: no scene for '%s' (looked for %s)" % [asset_id, path])
		return null
	var packed: PackedScene = load(path)
	var node := packed.instantiate()
	node.name = node_name
	add_child(node)
	if node is PFAsset:
		return node
	push_error("PFViewmodel: %s is not a PFAsset" % path)
	return null


## Put `asset_id` in the hands and bind its clips. Empty string unequips.
func equip(asset_id: String) -> bool:
	if asset != null:
		asset.queue_free()
		asset = null
		asset_manifest = null
	for library in _player.get_animation_library_list():
		_player.remove_animation_library(library)
	current_clip = ""

	if asset_id.is_empty():
		equipped.emit("")
		return true

	asset = _instance(asset_id, "Asset")
	if asset == null:
		return false
	asset_manifest = asset.manifest
	if asset_manifest == null or not asset_manifest.is_valid():
		push_error("PFViewmodel: '%s' has no usable manifest" % asset_id)
		return false

	# The rig half of every clip targets the arms skeleton, the asset half the
	# proxy. Both paths are relative to this node, which is the player's root.
	var library := PFClipBinder.build_library(
		asset_manifest,
		get_path_to(rig.skeleton) if rig != null and rig.skeleton != null else NodePath(),
		get_path_to(asset.skeleton) if asset.skeleton != null else NodePath())
	if library != null:
		_player.add_animation_library(&"", library)
	equipped.emit(asset_id)
	return true


# --- playback -------------------------------------------------------------

func clip_ids(include_stubs: bool = false) -> PackedStringArray:
	return asset_manifest.clip_ids(include_stubs) if asset_manifest != null else PackedStringArray()


func play(clip_id: String, from_start: bool = true) -> bool:
	if asset_manifest == null or not _player.has_animation(clip_id):
		return false
	var record := asset_manifest.clip(clip_id)
	var blend := float(record.get("blend_in", 0.0))
	if from_start:
		_player.stop()
	_player.play(clip_id, blend)
	current_clip = clip_id

	_events = record.get("events", []).duplicate()
	_sounds = record.get("sounds", []).duplicate()
	_attach = record.get("attach", []).duplicate()
	_event_at = 0
	_sound_at = 0
	_attach_at = 0
	_last_position = -1.0
	clip_started.emit(clip_id)
	return true


func stop() -> void:
	_player.stop()
	current_clip = ""


func is_playing() -> bool:
	return _player.is_playing()


func position() -> float:
	return _player.current_animation_position


func length() -> float:
	return _player.current_animation_length


func seek(seconds: float) -> void:
	_player.seek(seconds, true)
	_rewind_cursors(seconds)


func set_speed(scale: float) -> void:
	_player.speed_scale = scale


func _process(_delta: float) -> void:
	if current_clip.is_empty() or not _player.is_playing():
		return
	var now := _player.current_animation_position
	if now < _last_position:
		# The clip looped: everything is due again from the top.
		_rewind_cursors(0.0)
	_last_position = now
	_fire_due(now)


func _rewind_cursors(seconds: float) -> void:
	_event_at = _count_before(_events, seconds)
	_sound_at = _count_before(_sounds, seconds)
	_attach_at = _count_before(_attach, seconds)
	_last_position = seconds


func _count_before(cues: Array, seconds: float) -> int:
	var n := 0
	for cue: Dictionary in cues:
		if float(cue.get("t", 0.0)) <= seconds:
			n += 1
	return n


func _fire_due(now: float) -> void:
	while _event_at < _events.size() and float(_events[_event_at].get("t", 0.0)) <= now:
		var cue: Dictionary = _events[_event_at]
		_event_at += 1
		clip_event.emit(String(cue.get("name", "")), cue.get("args", {}))
	while _sound_at < _sounds.size() and float(_sounds[_sound_at].get("t", 0.0)) <= now:
		_play_sound(_sounds[_sound_at])
		_sound_at += 1
	while _attach_at < _attach.size() and float(_attach[_attach_at].get("t", 0.0)) <= now:
		var move: Dictionary = _attach[_attach_at]
		_attach_at += 1
		attach_changed.emit(String(move.get("part", "")), String(move.get("socket", "")),
			String(move.get("state", "")) == "attach")


func _on_finished(finished: StringName) -> void:
	var clip_id := String(finished)
	clip_finished.emit(clip_id)
	if clip_id != current_clip:
		return
	current_clip = ""
	if not auto_advance or asset_manifest == null:
		return
	var next := String(asset_manifest.clip(clip_id).get("next", ""))
	if not next.is_empty() and _player.has_animation(next):
		play(next)


# --- sockets and audio ----------------------------------------------------

## Look the socket up on the held asset first, then on the arms.
func socket(socket_id: String) -> Node3D:
	if asset != null:
		var found := asset.socket(socket_id)
		if found != null:
			return found
	if rig != null:
		return rig.socket(socket_id)
	return null


func _play_sound(cue: Dictionary) -> void:
	var path := String(cue.get("file", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("PFViewmodel: missing sound %s" % path)
		return
	var stream: AudioStream = load(path)
	if stream == null:
		return
	var voice := _voices[_voice_next]
	_voice_next = (_voice_next + 1) % _voices.size()

	var where := socket(String(cue.get("socket", "")))
	voice.global_transform = where.global_transform if where != null else global_transform
	voice.stream = stream
	voice.volume_db = linear_to_db(maxf(float(cue.get("volume", 1.0)), 0.0001))
	voice.pitch_scale = float(cue.get("pitch", 1.0))
	var bus := String(cue.get("bus", "SFX"))
	# A bus that does not exist would silence the cue with no explanation.
	voice.bus = bus if AudioServer.get_bus_index(bus) >= 0 else &"Master"
	voice.play()
