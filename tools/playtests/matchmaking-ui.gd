extends SceneTree
var scene: Node
var role: String
var work: String
var output: String
var failures := 0
var alpha := false

func _initialize() -> void:
	root.position = Vector2i(-12000, -12000)
	root.size = Vector2i(1440, 900)
	role = OS.get_environment("XIUXIAN_MATCHMAKING_ROLE")
	work = OS.get_environment("XIUXIAN_MATCHMAKING_WORK")
	output = OS.get_environment("XIUXIAN_MATCHMAKING_OUTPUT")
	alpha = role == "queuealpha"
	run.call_deferred()

func check(ok: bool, label: String) -> bool:
	print("MATCHMAKING_UI ", role, " ", "PASS " if ok else "FAIL ", label)
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
	if not check(await wait_for(func():return find_button(scope,text,prefix)!=null),"Found "+text): return false
	await process_frame
	var button := find_button(scope,text,prefix)
	var received := [false]
	button.pressed.connect(func():received[0]=true,CONNECT_ONE_SHOT)
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion,true)
	for down in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event,true)
	await process_frame
	return check(received[0],"Clicked "+text)

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(output.path_join(name+".png"))==OK,"Saved "+name)

func finish() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	print("MATCHMAKING_UI ",role," ",failures," failures")
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = work.path_join(role+"-cache")
	scene.account_legacy_source_override = work.path_join("missing-save.json")
	root.add_child(scene)
	current_scene = scene
	scene.account_api.allow_autostart = false
	scene.ui.open_login()
	scene.ui.account_panel.username_input.text = role
	scene.ui.account_panel.password_input.text = "matchmaking-fixture-password"
	scene.ui.account_panel.submit()
	if not check(await wait_for(func():return scene.account_ready and scene.state.is_remote()),"Login"): await finish();return
	scene.ui.close_modal()
	if not await click(scene.ui,"论剑台 / 对战",true): await finish();return
	if not check(await wait_for(func():return not scene.ui.modal.find_children("*","LineEdit",true,false).is_empty()),"Public alias onboarding"): await finish();return
	var alias_input: LineEdit = scene.ui.modal.find_children("*","LineEdit",true,false)[0]
	alias_input.text = "松风" if alpha else "云栖"
	if not await click(scene.ui.modal,"保存论剑昵称"): await finish();return
	if not check(await wait_for(func():return find_button(scene.ui.modal,"开始匹配")!=null),"Alias enabled public matching"): await finish();return
	if alpha:
		if not await click(scene.ui.modal,"开始匹配"): await finish();return
		if not check(await wait_for(func():return find_button(scene.ui.modal,"取消匹配")!=null),"Waiting queue shown"): await finish();return
		await capture("matchmaking-queue")
		if not await click(scene.ui.modal,"取消匹配"): await finish();return
		if not check(await wait_for(func():return find_button(scene.ui.modal,"开始匹配")!=null),"Cancellation restored the entry button"): await finish();return
		if not await click(scene.ui.modal,"开始匹配"): await finish();return
		if not check(await wait_for(func():return find_button(scene.ui.modal,"取消匹配")!=null),"Rejoined queue"): await finish();return
		var marker := FileAccess.open(work.path_join("alpha-queued"),FileAccess.WRITE)
		marker.store_string("ready")
		marker.close()
	else:
		if not check(await wait_for(func():return FileAccess.file_exists(work.path_join("alpha-queued"))),"Other player queued without a friend invite"): await finish();return
		if not await click(scene.ui.modal,"开始匹配"): await finish();return
	if not check(await wait_for(func():return is_instance_valid(scene.ui.duel_view) and scene.ui.duel_view.state.get("phase")=="fighting"),"Matched players automatically entered the same fight"): await finish();return
	var view = scene.ui.duel_view
	check(view.state.mode=="ranked","Battle is ranked instead of a friendly invitation")
	if alpha:
		scene.account_api.realtime.disconnect_stream()
		await create_timer(.35).timeout
		await scene.account_api.realtime.connect_stream(scene.account_api.api)
		check(await wait_for(func():return view.state.phase=="fighting" and Time.get_ticks_msec()-view.last_packet_ms<200),"Ranked fight reconnected")
	var deadline := Time.get_ticks_msec()+25000
	var photographed := false
	while view.state.get("result")==null and Time.get_ticks_msec()<deadline:
		var own: Dictionary = view.state.players[view.seat]
		var other: Dictionary = view.state.players[1-view.seat]
		if view.state.phase=="fighting" and alpha:
			var dx := float(other.x)-float(own.x)
			Input.action_release("move_left")
			Input.action_release("move_right")
			if absf(dx)>85: Input.action_press("move_right" if dx>0 else "move_left")
			view.queue_action(1 if absf(dx)<120 and view.action_available(1) else 2)
			if not photographed and int(other.hp)<80:
				await capture("matchmaking-fight")
				photographed = true
		await create_timer(.07).timeout
	Input.action_release("move_left")
	Input.action_release("move_right")
	if not check(view.state.get("result") is Dictionary,"Authoritative result received"): await finish();return
	check(int(view.state.result.winner)==0 and view.state.result.reason=="knockout","Both clients agree on the ranked winner")
	check(view.state.get("rating_change") is Dictionary,"One-time rating change received")
	if alpha: await capture("matchmaking-result")
	if not await click(view,"返回论剑台"): await finish();return
	check(await wait_for(func():return scene.ui.modal.find_children("*","Label",true,false).any(func(label):return "积分 +" in label.text if alpha else "积分 -" in label.text)),"Match history shows the exact rating change")
	check(scene.ui.modal.find_children("*", "Label", true, false).any(func(label): return label.text.begins_with("Lv.") and "游玩" in label.text), "Leaderboard shows levels and play days")
	if alpha: await capture("matchmaking-leaderboard")
	await finish()
