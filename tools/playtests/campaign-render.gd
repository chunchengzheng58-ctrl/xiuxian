extends SceneTree
## Visual inspection of real engine packets. The numeric fixture is deliberately
## separate from the earned-resource campaign playthrough and proves no victories.
var scene: Node
var failures := 0
var output := ""

func _initialize() -> void:
	root.position = Vector2i(-12000, -12000)
	root.size = Vector2i(1440, 900)
	output = ProjectSettings.globalize_path("res://outputs/playtests/campaign-render")
	DirAccess.make_dir_recursive_absolute(output)
	run.call_deferred()

func run() -> void:
	var fixture: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://work/campaign/render-states.json"))
	if not fixture is Dictionary or fixture.get("states", []).size() != 20:
		printerr("Missing twenty current engine render packets")
		quit(1)
		return
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	scene.account_api.allow_autostart = false
	await process_frame
	for state in fixture.states:
		scene.ui.close_modal(true)
		await process_frame
		scene.ui.open_expedition_battle(str(state.run_id))
		var view = scene.ui.expedition_view
		view.receive_state(state)
		view._process(1.0)
		view.set_process(false)
		await process_frame
		await RenderingServer.frame_post_draw
		var ok: bool = view.boss.texture != null and not view.entry.is_empty() and view.entry.id == state.boss_id
		ok = ok and root.get_texture().get_image().save_png(output.path_join(str(state.boss_id) + ".png")) == OK
		if not ok:
			failures += 1
		print("CAMPAIGN_RENDER ", "PASS " if ok else "FAIL ", state.boss_id, " ", view.mechanic_hint.text)
	scene.ui.close_modal(true)
	scene.queue_free()
	await process_frame
	print("CAMPAIGN_RENDER_TEST: 20 packets; ", failures, " failures; visual fixture only")
	quit(1 if failures else 0)
