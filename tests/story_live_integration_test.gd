extends SceneTree
## Real village + real HUD + modal story integration. Run with --preview only;
## all account mutations below are in-memory test doubles, never a real save.
const Player = preload("res://scripts/story_scene_player.gd")
var checks := 0
var failures: Array[String] = []

func expect(value: bool, title: String) -> void:
	checks += 1
	if value:
		print("PASS: ", title)
	else:
		failures.append(title)
		printerr("FAIL: ", title)

func _initialize() -> void:
	expect("--preview" in OS.get_cmdline_user_args(), "integration test runs in nonpersistent preview mode")
	_run.call_deferred()

func capture(path: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	expect(image != null and not image.is_empty(), "real OpenGL image: " + path)
	if image != null:
		expect(image.save_png(path) == OK, "save " + path)

func _run() -> void:
	root.size = Vector2i(1440, 900)
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.ui.start_guest_demo()
	game.ui.close_modal(true)
	game.ui.refresh()
	await process_frame
	expect(game.ui.demo_reset_allowed(), "explicit guest demo may reset its disposable data")
	expect(game.ui.reset_demo_button.visible, "guest demo reset button is visible")

	# Simulate the authenticated state in memory only. No account API call and no
	# reset is allowed to write a save because preview persistence is disabled.
	game.family.account = {"id": "account_00000000-0000-0000-0000-000000000001", "name": "正式账号测试替身"}
	game.family.account_bound = true
	game.state.cultivator_id = "cultivator_formal_test_double"
	game.family.owner_state.cultivator_id = "cultivator_formal_test_double"
	var before := {
		"cultivation": game.state.cultivation,
		"qi": game.state.equipment.qi,
		"inventory": game.state.equipment.inventory.duplicate(true),
		"cleared": game.state.cleared_bosses.duplicate(),
	}
	game.ui.refresh()
	expect(not game.ui.demo_reset_allowed(), "authenticated server-backed account is not a demo")
	expect(not game.ui.reset_demo_button.visible, "authenticated account cannot see reset-demo button")
	game.ui.reset_demo()
	expect(game.state.cultivation == before.cultivation and game.state.equipment.qi == before.qi, "UI reset attempt preserves formal-account resources")
	expect(game.state.equipment.inventory == before.inventory and game.state.cleared_bosses == before.cleared, "UI reset attempt preserves equipment and clears")
	expect(not game.state.reset_demo(), "domain reset rejects server-backed state even when called directly")
	expect(game.state.cultivation == before.cultivation and game.state.equipment.qi == before.qi, "direct domain attempt cannot alter formal-account resources")
	game.ui.close_modal(true)

	var campaign: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/adventure-campaign.v1.json"))
	var row: Dictionary = {}
	for stage in campaign.get("stages", []):
		if stage.get("stage_id", "") == "b01":
			row = stage
			break
	expect(not row.is_empty(), "b01 story fixture exists")
	var player := Player.new()
	player.scene_data = {"scene_id": "stage.b01.resolution", "title": row.get("name", "新绳与旧树"), "kind": "resolution", "stage_id": "b01", "art": "marks", "dialogue": row.get("resolution", [])}
	player.variants = {"protagonist": "female", "companion": "male"}
	player.persist_marker = false
	var village_layer := game.ui.get_parent() as CanvasLayer
	var story_layer := Player.mount(player, root)
	await process_frame
	await process_frame
	expect(story_layer.layer == Player.MODAL_LAYER, "story uses the shared modal layer")
	expect(village_layer == null or story_layer.layer > village_layer.layer, "story modal outranks the real village HUD")
	expect(player.get_parent() == story_layer, "story player is parented to its modal layer")
	expect(player.previous_button.get_global_rect().intersects(player.next_button.get_global_rect()) == false, "previous and next buttons do not overlap")
	expect(player.body_label.get_global_rect().intersects(player.next_button.get_global_rect()) == false, "dialogue body does not overlap action buttons")
	expect(player.next_button.get_global_rect().end.x <= root.size.x - 20, "primary action stays inside the viewport")
	await capture("res://output/story-live-village-fixed.png")

	var first_art: String = player.art_panel.art
	player.advance()
	await process_frame
	expect(player.art_panel.art == first_art and is_equal_approx(player.art_panel.modulate.a, 1.0), "same-art dialogue advance does not flash the whole scene")
	await capture("res://output/story-live-village-next.png")

	var draws := [0]
	player.art_panel.draw.connect(func(): draws[0] += 1)
	await create_timer(0.70).timeout
	print("STORY_VISIBLE_REDRAWS_0_7S=", draws[0])
	expect(draws[0] >= 10, "visible micro-animation redraws smoothly rather than at the old 12 fps")
	player.art_panel.hide()
	await process_frame
	draws[0] = 0
	await create_timer(0.25).timeout
	expect(draws[0] == 0, "hidden story prop performs zero redraws")
	player.art_panel.show()

	var layer_id := story_layer.get_instance_id()
	player.queue_free()
	await process_frame
	await process_frame
	expect(instance_from_id(layer_id) == null, "closing story also destroys its modal layer")
	game.queue_free()
	await process_frame
	var report := {"checks": checks, "failures": failures, "captures": ["output/story-live-village-fixed.png", "output/story-live-village-next.png"]}
	var file := FileAccess.open("res://output/story-live-integration-report.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
	print("STORY_LIVE_INTEGRATION: ", checks, " checks, ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
