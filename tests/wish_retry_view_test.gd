extends SceneTree

var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("WISH_RETRY_VIEW ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func run() -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	scene.family.persist_enabled = false
	scene.state.persist_enabled = false
	scene.state.equipment.initial_score = 50
	scene.state.equipment.qi = 30
	scene.state.equipment.pending_draw = {"count": 1, "request_id": "lost-single-response"}
	scene.ui.close_modal(true)
	scene.ui.open_treasure("wish")
	await process_frame
	var panel = scene.ui.treasure
	check(not panel.single_button.disabled and panel.single_button.text == "继续上次单抽", "A pending single can recover after its fee left only thirty qi")
	check(panel.ten_button.disabled and panel.wish_focus.disabled, "The pending request locks other counts and focus")
	panel.finish_reveal()
	check(not panel.single_button.disabled and panel.ten_button.disabled, "Skipping presentation cannot reapply the wallet gate to a pending receipt")
	panel.submitting_draw = true
	panel.finish_reveal()
	check(panel.single_button.disabled and panel.ten_button.disabled and panel.wish_focus.disabled, "A running retry stays protected when presentation is skipped")
	panel.submitting_draw = false
	panel.finish_reveal()
	check(not panel.single_button.disabled, "The original count becomes available after the uncertain request ends")
	scene.state.equipment.qi = 0
	scene.state.equipment.pending_draw = {"count": 10, "request_id": "lost-ten-response"}
	panel.build()
	await process_frame
	check(not panel.ten_button.disabled and panel.ten_button.text == "继续上次十连", "A pending ten-pull can recover with an empty wallet")
	panel.finish_reveal()
	check(not panel.ten_button.disabled and panel.single_button.disabled, "The ten-pull recovery keeps its count after a presentation reset")
	panel.set_wish_school(2)
	check(scene.state.equipment.wish_school == -1, "A pending receipt cannot change its wish focus")
	scene.state.equipment.erase("pending_draw")
	panel.finish_reveal()
	check(panel.single_button.disabled and panel.ten_button.disabled, "Resolved requests restore normal insufficient-funds gates")
	check(not panel.wish_focus.disabled, "Resolved requests release focus selection")
	scene.state.equipment.qi = 70
	panel.finish_reveal()
	check(not panel.single_button.disabled and panel.ten_button.disabled, "New requests still need their actual fee")
	scene.state.equipment.qi = 0
	scene.state.equipment.initial_score = -1
	panel.build()
	check(panel.single_button.disabled, "An uninitialized new adventurer starts with the normal wish lock")
	scene.state.cultivator_id = "incoming-authoritative-character"
	scene.state.apply_remote({"cultivator_id": scene.state.cultivator_id, "initial_score": 50, "initial_profile_id": "adventurer-default-v1", "resources": {"spirit_stones": 100}, "equipment": []})
	scene.ui.refresh()
	await process_frame
	check(not panel.single_button.disabled and panel.market_balance.text == "100", "Incoming authoritative funds and support unlock an already-open wish page")
	var stable_button: Button = panel.single_button
	scene.ui.refresh()
	check(panel.single_button == stable_button, "An unchanged projection does not rebuild active wish controls")
	scene.ui.close_modal(true)
	scene.queue_free()
	await process_frame
	print("WISH_RETRY_VIEW_TEST: ", failures, " failures")
	quit(1 if failures else 0)
