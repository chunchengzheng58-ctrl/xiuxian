extends Node
## Presentation-only audio. No gameplay state or server commands originate here.
signal cue_played(kind: String)
const SOUNDS = {
	"attack": "strike", "sword": "spell", "dash": "boss_rush", "guard": "boss_perfect",
	"heal": "chime", "hit": "boss_hit", "hurt": "boss_impact", "block": "boss_stagger",
	"warning": "boss_tell", "phase": "boss_phase", "victory": "boss_perfect", "defeat": "boss_stagger", "ui": "chime"
}
var unlocked := false
var battle_owner_id := 0
var current_context := "village"
var _music: AudioStreamPlayer
var _effects: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}
var _last_cue: Dictionary = {}
var _cursor := 0
var _focused := true

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for index in range(8):
		var player := AudioStreamPlayer.new()
		player.bus = "Effects"
		player.volume_db = -10
		add_child(player)
		_effects.append(player)
	unlocked = not OS.has_feature("web")
	if unlocked:
		_change_music()

func _input(event: InputEvent) -> void:
	if unlocked:
		return
	if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed) or (event is InputEventKey and event.pressed and not event.echo):
		unlock()

func unlock() -> void:
	if unlocked:
		return
	unlocked = true
	_change_music()

func play(kind: String) -> void:
	if not unlocked or not _focused or not SOUNDS.has(kind) or _effects.is_empty():
		return
	var options := get_node_or_null("/root/GameOptions")
	if options != null and (options.get_value("muted", false) or float(options.get_value("effects_volume", 0.75)) <= 0 or float(options.get_value("master_volume", 0.75)) <= 0):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_cue.get(kind, -10000)) < (160 if kind in ["warning", "phase"] else 70):
		return
	_last_cue[kind] = now
	if not _streams.has(kind):
		_streams[kind] = _load_audio("res://assets/combat/" + str(SOUNDS[kind]) + ".wav")
	if _streams[kind] == null:
		return
	var player := _effects[_cursor % _effects.size()]
	_cursor += 1
	player.stop()
	player.stream = _streams[kind]
	if AudioServer.get_driver_name() != "Dummy":
		player.play()
	cue_played.emit(kind)

func enter_battle(owner: Node) -> void:
	battle_owner_id = owner.get_instance_id()
	if current_context != "battle":
		current_context = "battle"
		_change_music()

func leave_battle(owner: Node) -> void:
	if owner.get_instance_id() != battle_owner_id:
		return
	battle_owner_id = 0
	current_context = "village"
	_change_music()

func _change_music() -> void:
	if not unlocked or not is_inside_tree():
		return
	var loaded := _load_audio("res://assets/audio/" + current_context + "_loop.wav")
	if loaded == null:
		return
	var stream = loaded.duplicate()
	if stream is AudioStreamWAV:
		var frames := int(round(stream.get_length() * stream.mix_rate))
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = frames
	var previous := _music
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	_music.volume_db = -60
	_music.stream = stream
	add_child(_music)
	# Dummy has no mixing callbacks to retire WAV playback references. Source
	# tests still load/inspect real streams, but never start inaudible playbacks.
	if AudioServer.get_driver_name() != "Dummy":
		_music.play()
	_music.stream_paused = not _focused
	create_tween().tween_property(_music, "volume_db", -2.0, 0.7)
	if is_instance_valid(previous):
		var fade := create_tween()
		fade.tween_property(previous, "volume_db", -60.0, 0.5)
		fade.tween_callback(previous.queue_free)

func _load_audio(path: String) -> AudioStream:
	# CLI source play can precede editor import. Exported resources always use
	# the importer, while new original WAVs can safely load their PCM directly.
	return load(path) if ResourceLoader.exists(path) else AudioStreamWAV.load_from_file(path)

func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
	_streams.clear()
	_music = null

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		for player in _effects:
			player.stop()
		if is_instance_valid(_music):
			_music.stream_paused = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true
		if is_instance_valid(_music):
			_music.stream_paused = false
