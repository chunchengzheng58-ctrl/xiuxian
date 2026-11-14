extends Node
## 仅保存此设备的显示、声音与连接偏好；不保存账号、令牌或角色进度。
signal changed
signal settings_requested
const DEFAULTS = {"master_volume": 0.75, "music_volume": 0.35, "effects_volume": 0.75, "muted": false,
	"reduced_flash": false, "show_damage_numbers": true, "server_url": ""}
var values: Dictionary = DEFAULTS.duplicate(true)
var storage_path := ""
var last_error := ""
var ephemeral := false
var _settings_owner: WeakRef
var settings_open: bool:
	get:
		var owner: Variant = _settings_owner.get_ref() if _settings_owner != null else null
		return is_instance_valid(owner) and not owner.is_queued_for_deletion()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ephemeral = "--kernel-ephemeral" in OS.get_cmdline_user_args() and not OS.has_environment("XIUXIAN_SETTINGS_PATH")
	storage_path = OS.get_environment("XIUXIAN_SETTINGS_PATH") if OS.has_environment("XIUXIAN_SETTINGS_PATH") else ("res://work/preferences/game-options.json" if OS.has_feature("editor") else "user://game-options.json")
	load_options()
	apply_audio()

func get_value(key: String, fallback: Variant = null) -> Variant:
	return values.get(key, fallback)

func update(key: String, value: Variant) -> bool:
	if not valid_value(key, value):
		last_error = "设置值无效。"
		return false
	var previous: Variant = values.get(key)
	values[key] = value
	if not save_options():
		values[key] = previous
		return false
	apply_audio()
	changed.emit()
	return true

func reset_defaults() -> bool:
	var previous := values.duplicate(true)
	var endpoint: String = str(values.get("server_url", ""))
	values = DEFAULTS.duplicate(true)
	values.server_url = endpoint
	if not save_options():
		values = previous
		return false
	apply_audio()
	changed.emit()
	return true

func valid_value(key: String, value: Variant) -> bool:
	if not DEFAULTS.has(key):
		return false
	if key.ends_with("_volume"):
		return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 1.0
	if key == "server_url":
		return value is String and value.length() <= 250 and "\n" not in value and "\r" not in value
	return value is bool

func load_options() -> void:
	if ephemeral or not FileAccess.file_exists(storage_path):
		return
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(storage_path))
	if not saved is Dictionary or saved.get("version") != 1 or not saved.get("values") is Dictionary:
		last_error = "设置文件无法读取，暂用默认设置。"
		return
	for key in DEFAULTS:
		if valid_value(key, saved["values"].get(key)):
			values[key] = saved["values"][key]

func save_options() -> bool:
	last_error = ""
	if ephemeral:
		return true
	var path := ProjectSettings.globalize_path(storage_path)
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		last_error = "无法创建设置目录。"
		return false
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		last_error = "无法保存设置，请检查目录是否可写。"
		return false
	file.store_string(JSON.stringify({"version": 1, "values": values}))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
		last_error = "设置保存失败，原文件保留。"
		return false
	return true

func apply_audio() -> void:
	for bus in ["Music", "Effects"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	for entry in [["Master", "master_volume"], ["Music", "music_volume"], ["Effects", "effects_volume"]]:
		var index := AudioServer.get_bus_index(entry[0])
		var volume := float(values[entry[1]])
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(0.0001, volume)))
		AudioServer.set_bus_mute(index, volume <= 0 or (entry[0] == "Master" and values.muted))

func begin_settings(owner: Node) -> void:
	_settings_owner = weakref(owner)

func end_settings(owner: Node) -> void:
	if _settings_owner != null and _settings_owner.get_ref() == owner:
		_settings_owner = null

func toggle_fullscreen() -> void:
	var full := DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F9: settings_requested.emit()
		KEY_F10: update("muted", not bool(get_value("muted")))
		KEY_F11: toggle_fullscreen()
		_: return
	get_viewport().set_input_as_handled()
