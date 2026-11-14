extends SceneTree

var files: Array[Dictionary] = []
var failed := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failed += 1
	print("PACK_CHECK: ", "PASS " if ok else "FAIL ", label)

func scan(directory: String) -> void:
	for filename in DirAccess.get_files_at(directory):
		var path := directory.path_join(filename)
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			files.append({"path": path, "bytes": file.get_length()})
	for child in DirAccess.get_directories_at(directory):
		scan(directory.path_join(child))

func run() -> void:
	check(not ProjectSettings.has_setting("autoload/_mcp_game_helper"), "editor helper autoload is stripped")
	for path in ["res://scripts/matchmaking_lobby.gd", "res://scripts/expedition_view.gd", "res://scripts/expedition_lobby.gd", "res://scripts/duel_view.gd", "res://scripts/equipment_forge_panel.gd", "res://scripts/equipment_market_panel.gd", "res://scripts/social_panel.gd", "res://scripts/story_panel.gd", "res://scripts/adventure_catalogue.gd", "res://scripts/game_options.gd", "res://scripts/settings_panel.gd", "res://scripts/game_audio.gd", "res://scripts/battle_feedback.gd"]:
		check(ResourceLoader.exists(path) and load(path) != null, "runtime resource loads: " + path)
	var contract = JSON.parse_string(FileAccess.get_file_as_string("res://data/kernel/contracts.json"))
	check(contract is Dictionary and str(contract).contains("combat.expedition_start"), "shared contract contains expedition commands")
	check(contract is Dictionary and str(contract).contains("combat.matchmaking_join"), "shared contract contains public matchmaking commands")
	check(contract is Dictionary and str(contract).contains("story.advance"), "shared contract contains persistent story commands")
	var campaign = load("res://data/adventure-campaign.v1.json")
	check(campaign != null and campaign.data.stages.size() == 20, "shared campaign contains all 20 stages")
	for path in ["res://assets/audio/village_loop.wav", "res://assets/audio/battle_loop.wav"]:
		check(ResourceLoader.exists(path) and load(path) != null, "original music resource loads: " + path)
	var growth = load("res://data/equipment-growth.v2.json")
	check(growth != null and growth.data.version == "equipment-growth-v2", "shared equipment growth configuration loads")
	scan("res://")
	var leaked: Array[String] = []
	for file in files:
		for prefix in ["res://health-entry/", "res://addons/godot_ai/", "res://server/", "res://work/", "res://output/", "res://outputs/", "res://tests/", "res://tools/", "res://docs/"]:
			if str(file.path).begins_with(prefix):
				leaked.append(str(file.path))
		for sample in ["样本体检报告", "手写既往病史记录", "四款药品包装展示"]:
			if sample in str(file.path):
				leaked.append(str(file.path))
	check(leaked.is_empty(), "development directories and health sample resources excluded: " + str(leaked))
	files.sort_custom(func(a, b): return a.bytes > b.bytes)
	var destination := OS.get_environment("XIUXIAN_PACK_AUDIT")
	var pack_path := OS.get_environment("XIUXIAN_PACK_PATH")
	var pack_hash := FileAccess.get_sha256(pack_path) if not pack_path.is_empty() else ""
	check(pack_hash.length() == 64, "audited PCK is identified by SHA-256")
	var output := FileAccess.open(destination, FileAccess.WRITE)
	check(output != null, "audit output writable")
	if output != null:
		output.store_string(JSON.stringify({"failures": failed, "file_count": files.size(), "pck_sha256": pack_hash, "files": files}, "  "))
	print("WEB_PACK_AUDIT: ", failed, " failures; ", files.size(), " resource entries")
	quit(0 if failed == 0 else 1)
