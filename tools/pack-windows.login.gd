extends Node
var scene: Node

func _ready() -> void:
	get_tree().root.position = Vector2i(-12000, -12000)
	get_tree().root.size = Vector2i(1440, 900)
	run.call_deferred()

func wait_for(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 16000
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return predicate.call()

func click_text(parent: Node, text: String) -> bool:
	await get_tree().process_frame
	await get_tree().process_frame
	for button in parent.find_children("*", "Button", true, false):
		if not button.is_visible_in_tree() or button.disabled or button.text != text:
			continue
		var point: Vector2 = button.get_global_rect().get_center()
		var root := get_tree().root
		var motion := InputEventMouseMotion.new()
		motion.position = point
		root.push_input(motion, true)
		for down in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = point
			event.button_index = MOUSE_BUTTON_LEFT
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
			event.pressed = down
			root.push_input(event, true)
			await get_tree().process_frame
		return true
	return false

func campaign_check(registering: bool) -> bool:
	scene.ui.open_story()
	if not await wait_for(func(): return is_instance_valid(scene.ui.story_panel) and not scene.ui.story_panel.current.is_empty()):
		return false
	var panel = scene.ui.story_panel
	panel.show_chapter("wood")
	var chapter: Dictionary = panel.selected_chapter()
	var node: Dictionary = chapter.nodes.filter(func(row): return row.id == "wood.intro")[0]
	if not registering:
		return node.completed and int(panel.current.adventure.level) == 1
	panel.begin_dialogue(node.id)
	for index in range(node.dialogue.size() - 1):
		if not await click_text(panel, "继续"):
			return false
	if not await click_text(panel, "记下线索"):
		return false
	return await wait_for(func(): return not panel.busy and panel.selected_chapter().nodes.any(func(row): return row.id == "wood.intro" and row.completed))

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = OS.get_environment("XIUXIAN_PACK_TEST_WORK").path_join("cache")
	scene.account_legacy_source_override = OS.get_environment("XIUXIAN_PACK_TEST_WORK").path_join("no-legacy.json")
	get_tree().root.add_child(scene)
	scene.account_api.allow_autostart = false
	scene.ui.open_login()
	var panel = scene.ui.account_panel
	var registering := OS.get_environment("XIUXIAN_PACK_REGISTER") == "1"
	if registering:
		panel.switch_mode(true)
	panel.username_input.text = "desktop_player"
	panel.password_input.text = "desktop-fixture-password"
	if registering:
		panel.repeat_input.text = "desktop-fixture-password"
		panel.display_input.text = "桌面修士"
	panel.submit()
	var logged_in := await wait_for(func(): return scene.account_ready and scene.state.is_remote())
	var saved: bool = logged_in and scene.family.save_game()
	var campaign := false
	if logged_in and OS.get_environment("XIUXIAN_PACK_CAMPAIGN") == "1":
		campaign = await campaign_check(registering)
	if logged_in:
		scene.ui.close_modal(true)
		await RenderingServer.frame_post_draw
		get_tree().root.get_texture().get_image().save_png(OS.get_environment("XIUXIAN_PACK_TEST_CAPTURE"))
	var result := {"ok": logged_in and saved and (campaign or OS.get_environment("XIUXIAN_PACK_CAMPAIGN") != "1"), "cultivator_id": scene.state.cultivator_id, "remote": scene.state.is_remote(), "saved": saved, "campaign": campaign}
	var file := FileAccess.open(OS.get_environment("XIUXIAN_PACK_TEST_WORK").path_join("login-result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	print("WINDOWS_RELEASE_LOGIN ", JSON.stringify(result))
	scene.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if result.ok else 1)
