extends SceneTree
var scene: Node
var role: String
var work: String
var output: String
var failures := 0
var saw_reconnect := false

func _initialize() -> void:
	root.position = Vector2i(-12000, -12000)
	root.size = Vector2i(1440, 900)
	role = OS.get_environment("XIUXIAN_DUEL_ROLE")
	work = OS.get_environment("XIUXIAN_DUEL_WORK")
	output = OS.get_environment("XIUXIAN_DUEL_OUTPUT")
	run.call_deferred()

func check(ok: bool, label: String) -> bool:
	print("DUEL_UI ", role, " ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
	return ok

func wait_for(predicate: Callable, milliseconds: int = 16000) -> bool:
	var deadline := Time.get_ticks_msec() + milliseconds
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func find_button(scope: Node, text: String, prefix := false) -> Button:
	for node in scope.find_children("*", "Button", true, false):
		if node.is_visible_in_tree() and not node.disabled and (node.text.begins_with(text) if prefix else node.text == text):
			return node
	return null

func click(scope: Node, text: String, prefix := false) -> bool:
	if not check(await wait_for(func(): return find_button(scope, text, prefix) != null), "Found " + text): return false
	await process_frame
	var button := find_button(scope, text, prefix)
	var received := [false]
	button.pressed.connect(func(): received[0] = true, CONNECT_ONE_SHOT)
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for down in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event,true)
	await process_frame
	return check(received[0],"Clicked " + text)

func key(code: int) -> void:
	for down in [true,false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await process_frame

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK,"Saved " + name)

func finish() -> void:
	print("DUEL_UI ",role," ",failures," failures")
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = work.path_join(role + "-cache")
	scene.account_legacy_source_override = work.path_join("missing-save.json")
	root.add_child(scene)
	current_scene = scene
	scene.account_api.allow_autostart = false
	scene.ui.open_login()
	var panel = scene.ui.account_panel
	panel.username_input.text = role
	panel.password_input.text = "duel-fixture-password"
	panel.submit()
	if not check(await wait_for(func():return scene.account_ready and scene.state.is_remote()),"Login"): await finish(); return
	scene.ui.close_modal()
	await process_frame
	if not await click(scene.ui,"论剑台 / 对战",true): await finish(); return
	await wait_for(func():return find_button(scene.ui.modal,"好友切磋")!=null or find_button(scene.ui.modal,"邀约")!=null or find_button(scene.ui.modal,"接受约战")!=null)
	if find_button(scene.ui.modal,"好友切磋")!=null:
		if not await click(scene.ui.modal,"好友切磋"): await finish(); return
	if role == "alpha":
		if not await click(scene.ui.modal,"邀约"): await finish(); return
	else:
		if not await click(scene.ui.modal,"接受约战"): await finish(); return
	if not await click(scene.ui.modal,"进入擂台"): await finish(); return
	if not check(await wait_for(func():
		return is_instance_valid(scene.ui.duel_view) and scene.ui.duel_view.state.get("phase") == "fighting"
	),"Both clients entered the same live fight"): await finish(); return
	var view = scene.ui.duel_view
	check(view.state.get("mode")=="friendly","Friend invitations remain separate from public rankings")
	if role == "alpha":
		scene.account_api.realtime.disconnect_stream()
		await create_timer(.45).timeout
		await scene.account_api.realtime.connect_stream(scene.account_api.api)
		check(await wait_for(func():return view.state.phase == "fighting" and Time.get_ticks_msec()-view.last_packet_ms<200),"Reconnected to the same fight")
	var photographed := false
	var guarded := false
	var healed := false
	var deadline := Time.get_ticks_msec() + 22000
	while view.state.get("result") == null and Time.get_ticks_msec() < deadline:
		var own: Dictionary = view.state.players[view.seat]
		var other: Dictionary = view.state.players[1-view.seat]
		saw_reconnect = saw_reconnect or view.state.phase == "reconnecting"
		if view.state.phase == "fighting":
			if role == "alpha":
				var diff: float = float(other.x) - float(own.x)
				if absf(diff) > 85:
					Input.action_press("move_right" if diff > 0 else "move_left")
				else:
					Input.action_release("move_right")
					Input.action_release("move_left")
					await key(KEY_J)
				if float(own.cd[2]) <= 0: await key(KEY_1)
				if not photographed and int(other.hp) < 80:
					await capture("duel-fight")
					photographed = true
			else:
				if not guarded:
					await key(KEY_3)
					guarded = true
				if int(own.hp) < 65 and not healed:
					await key(KEY_4)
					healed = true
		await create_timer(.07).timeout
	Input.action_release("move_right")
	Input.action_release("move_left")
	if not check(view.state.get("result") is Dictionary,"Fight reached an authoritative result"):
		await finish(); return
	check(int(view.state.result.winner) == 0 and view.state.result.reason == "knockout","Both clients agree on winner and knockout")
	if role == "beta":
		check(saw_reconnect,"Opponent observes reconnect grace")
	if role == "alpha":
		await capture("duel-result")
	if await click(view,"返回论剑台"):
		check(await wait_for(func():
			return scene.ui.modal.find_children("*","Label",true,false).any(func(label):return ("胜利" if role=="alpha" else "落败") in label.text)
		),"Result appears in lobby history")
	await finish()
