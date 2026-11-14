extends Node
## Attached only to an isolated probe scene; audits the unchanged release PCK.
var failures: Array = []
var files: Array = []
var methods: Dictionary = {}

func _ready() -> void:
	run.call_deferred()

func check(ok: bool, title: String) -> void:
	print("WINDOWS_PCK ", "PASS " if ok else "FAIL ", title)
	if not ok:
		failures.append(title)

func has_methods(path: String, required: Array) -> void:
	var script = load(path)
	check(script is Script, "Packed script loads: " + path)
	if not script is Script:
		return
	var names: Array = []
	for method in script.get_script_method_list():
		names.append(str(method.name))
	methods[path] = names
	for method in required:
		check(method in names, "Packed method: " + path + " :: " + method)

func scan(directory: String) -> void:
	for filename in DirAccess.get_files_at(directory):
		var path := directory.path_join(filename)
		files.append(path)
	for child in DirAccess.get_directories_at(directory):
		scan(directory.path_join(child))

func run() -> void:
	check(not ProjectSettings.has_setting("autoload/_mcp_game_helper"), "Editor helper autoload is excluded")
	has_methods("res://scripts/treasure_panel.gd", ["refresh_wish_controls", "wish_projection_signature"])
	has_methods("res://scripts/gameplay_interface.gd", ["open_story", "open_expedition_lobby", "open_expedition_battle"])
	has_methods("res://scripts/story_panel.gd", ["render", "begin_dialogue", "render_dialogue", "advance", "refresh"])
	has_methods("res://scripts/expedition_lobby.gd", ["render", "refresh"])
	has_methods("res://scripts/expedition_view.gd", ["receive_state", "show_result"])
	has_methods("res://scripts/systems/story/module.gd", ["execute", "on_backend_changed"])
	var campaign = load("res://data/adventure-campaign.v1.json")
	check(campaign != null and campaign.data.version == "adventure-campaign-v1", "Campaign rule version is packed")
	if campaign != null:
		check(campaign.data.stages.size() == 20, "All twenty formal stages are packed")
		check(campaign.data.progression.thresholds.size() == 30, "Thirty adventure levels are packed")
		check(campaign.data.stages[-1].battle.life == 9000, "Final boss has the verified campaign pacing profile")
		check(campaign.data.chapters.size() >= 8, "Regional chapters and optional stories are packed")
	var rules_hash := FileAccess.get_sha256("res://data/adventure-campaign.v1.json")
	check(rules_hash == OS.get_environment("XIUXIAN_CAMPAIGN_RULES_SHA"), "Packed campaign rules match the current tested source")
	var contract = JSON.parse_string(FileAccess.get_file_as_string("res://data/kernel/contracts.json"))
	check(contract is Dictionary and str(contract).contains("story.snapshot") and str(contract).contains("story.advance"), "Authoritative story contracts are packed")
	scan("res://")
	var leaked: Array = []
	for path in files:
		for prefix in ["res://server/", "res://addons/godot_ai/", "res://tests/", "res://tools/", "res://work/", "res://output/", "res://outputs/", "res://health-entry/"]:
			if str(path).begins_with(prefix):
				leaked.append(path)
	check(leaked.is_empty(), "Private and development resources excluded: " + str(leaked))
	var pck_hash := FileAccess.get_sha256(OS.get_environment("XIUXIAN_PACK_PATH"))
	check(pck_hash.length() == 64, "Audited PCK identified by SHA256")
	var file := FileAccess.open(OS.get_environment("XIUXIAN_PACK_AUDIT"), FileAccess.WRITE)
	var report := {"passed": failures.is_empty(), "failures": failures, "pckSha256": pck_hash, "campaignRulesSha256": rules_hash,
		"methods": methods, "fileCount": files.size(), "scope": "Unchanged native release PCK; loose probe scene only in isolated audit directory."}
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("WINDOWS_PCK ", failures.size(), " failures; ", files.size(), " packed resources")
	get_tree().quit(0 if failures.is_empty() else 1)
