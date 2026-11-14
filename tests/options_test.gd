extends SceneTree
const Options = preload("res://scripts/game_options.gd")
const State = preload("res://scripts/game_state.gd")
var failures := 0
var checks := 0

class PendingStory extends Control:
	var busy := true

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, name: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("OPTIONS ", "PASS " if ok else "FAIL ", name)

func run() -> void:
	var options := root.get_node("GameOptions")
	var work := "res://work/options-tests/%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(work))
	options.storage_path = work.path_join("options.json")
	options.ephemeral = false
	check(options.update("music_volume", 0.22) and options.update("effects_volume", 0.48), "Volume updates atomically replace an existing settings file")
	check(not options.update("master_volume", INF) and not options.update("master_volume", -1) and not options.update("muted", 1), "Invalid numbers and types cannot enter audio preferences")
	check(options.update("muted", true) and AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")), "Mute covers the actual master bus")
	check(is_equal_approx(db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music"))), 0.22), "Music volume applies to its actual mixer bus")
	check(options.update("server_url", "https://example.test"), "Server preference is a device setting")
	var loaded := Options.new()
	loaded.storage_path = options.storage_path
	loaded.load_options()
	check(loaded.get_value("muted") and is_equal_approx(loaded.get_value("effects_volume"), 0.48), "Fresh options instance restores saved volume and mute")
	check(loaded.get_value("server_url") == "https://example.test", "Native server override survives restart")
	loaded.free()
	check(options.reset_defaults() and options.get_value("server_url") == "https://example.test" and not options.get_value("muted"), "Resetting presentation preserves the selected server")
	options.update("server_url", "")
	var first := Node.new()
	var second := Node.new()
	options.begin_settings(first)
	options.begin_settings(second)
	options.end_settings(first)
	check(options.settings_open, "Old overlay exit cannot clear a newer overlay owner")
	options.end_settings(second)
	check(not options.settings_open, "Settings state clears with its actual owner")
	first.free()
	second.free()
	var state := State.new()
	state.persist_enabled = false
	state.cultivator_id = "mine"
	state.adventure = {"level": 7}
	state.apply_remote({"cultivator_id": "another", "adventure": {"level": 30}})
	check(state.adventure.level == 7, "A different actor cannot overwrite adventure HUD projection")
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	scene.account_api.allow_autostart = false
	scene.account_ready = true
	scene.ui.close_modal(true)
	scene.ui.modal = ColorRect.new()
	scene.ui.add_child(scene.ui.modal)
	scene.ui.modal_open = true
	var original = scene.ui.modal
	var pending := PendingStory.new()
	scene.ui.add_child(pending)
	scene.ui.story_panel = pending
	scene.ui.open_treasure("forge")
	check(scene.ui.modal == original and not is_instance_valid(scene.ui.treasure), "Pending chapter save blocks forge navigation before touching the original modal")
	scene.ui.open_settings()
	await process_frame
	check(options.settings_open and scene.ui.modal == original and scene.ui.story_panel == pending, "Settings overlays a pending chapter without replacing its modal or request")
	scene.ui.settings_panel.close()
	await process_frame
	check(not options.settings_open and scene.ui.modal == original, "Closing settings restores the same pending chapter")
	pending.busy = false
	scene.ui.close_modal(true)
	scene.queue_free()
	await process_frame
	await create_timer(0.1).timeout
	print("OPTIONS_TEST: %d checks; %d failures" % [checks, failures])
	quit(1 if failures else 0)
