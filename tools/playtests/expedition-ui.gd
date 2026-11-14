extends SceneTree
var scene: Node
var work: String
var output: String
var failures := 0

func _initialize() -> void:
	root.position = Vector2i(-12000, -12000)
	root.size = Vector2i(1440, 900)
	work = OS.get_environment("XIUXIAN_EXPEDITION_WORK")
	output = OS.get_environment("XIUXIAN_EXPEDITION_OUTPUT")
	run.call_deferred()

func check(ok: bool, label: String) -> bool:
	print("EXPEDITION_UI ", "PASS " if ok else "FAIL ", label)
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

func move(direction: Vector2) -> void:
	for action in ["move_left","move_right","move_forward","move_back"]:
		Input.action_release(action)
	if direction.x < -0.1: Input.action_press("move_left", minf(1, -direction.x))
	if direction.x > 0.1: Input.action_press("move_right", minf(1, direction.x))
	if direction.y < -0.1: Input.action_press("move_forward", minf(1, -direction.y))
	if direction.y > 0.1: Input.action_press("move_back", minf(1, direction.y))

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK,"Saved " + name)

func current_expedition_lobby() -> Node:
	if not is_instance_valid(scene.ui.modal): return null
	for node in scene.ui.modal.find_children("*", "", true, false):
		if node.get_script()!=null and node.get_script().resource_path=="res://scripts/expedition_lobby.gd": return node
	return null

func finish() -> void:
	move(Vector2.ZERO)
	print("EXPEDITION_UI ",failures," failures")
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = work.path_join("cache")
	scene.account_legacy_source_override = work.path_join("missing-save.json")
	root.add_child(scene)
	current_scene = scene
	scene.account_api.allow_autostart = false
	scene.ui.open_login()
	var panel = scene.ui.account_panel
	panel.username_input.text = "explorer"
	panel.password_input.text = "explorer-fixture-password"
	panel.submit()
	if not check(await wait_for(func(): return scene.account_ready and scene.state.is_remote()),"Fresh player logged in"): await finish(); return
	check(scene.state.equipment.initial_score < 0,"No health baseline or artificial stats fixture")
	scene.ui.close_modal()
	await process_frame
	if not await click(scene.ui,"五域游历 / 主线"): await finish(); return
	if not await click(scene.ui.modal,"前往本章秘境"): await finish(); return
	if not await click(scene.ui.modal,"进入秘境"): await finish(); return
	if not check(await wait_for(func(): return is_instance_valid(scene.ui.expedition_view) and scene.ui.expedition_view.state.get("phase") == "fighting"),"Entered authoritative boss fight"): await finish(); return
	var view = scene.ui.expedition_view
	var photographed := false
	var saw_telegraph := false
	var reconnected := false
	var deadline := Time.get_ticks_msec() + 80000
	while view.state.get("result") == null and Time.get_ticks_msec() < deadline:
		var own: Dictionary = view.state.player
		var enemy: Dictionary = view.state.enemy
		var position := Vector2(own.x, own.y)
		var difference := Vector2(enemy.x, enemy.y) - position
		var direction := difference.normalized() if difference.length() > 85 else Vector2.ZERO
		var danger := false
		for zone in view.state.get("telegraphs", []):
			saw_telegraph = true
			if zone.kind == "circle" and position.distance_to(Vector2(zone.x,zone.y)) < float(zone.radius) + 32:
				direction = Vector2(0, -1 if position.y > 555 else 1)
				danger = true
			elif zone.kind == "line":
				var start := Vector2(zone.x,zone.y)
				var end := Vector2(zone.x2,zone.y2)
				var point := Geometry2D.get_closest_point_to_segment(position,start,end)
				if position.distance_to(point) < float(zone.width) * 0.5 + 32:
					direction = (position-point).normalized()
					if direction.length() < 0.1: direction = (end-start).orthogonal().normalized()
					danger = true
		if view.state.phase == "fighting":
			move(direction)
			if danger:
				view.queue_action(3)
			elif float(own.hp) < float(own.max_hp)*0.55 and view.action_available(5):
				view.queue_action(5)
			elif difference.length() < 105 and view.action_available(1):
				view.queue_action(1)
			elif view.action_available(2):
				view.queue_action(2)
			if not photographed and not view.state.get("telegraphs",[]).is_empty():
				await capture("expedition-fight")
				photographed = true
			if not reconnected and int(enemy.hp) < int(enemy.max_hp)*0.75:
				move(Vector2.ZERO)
				scene.account_api.realtime.disconnect_stream()
				await create_timer(0.35).timeout
				await scene.account_api.realtime.connect_stream(scene.account_api.api)
				check(await wait_for(func():return view.state.phase=="fighting" and Time.get_ticks_msec()-view.last_packet_ms<200),"Rejoined the same running boss fight")
				reconnected = true
		await create_timer(.07).timeout
	move(Vector2.ZERO)
	if not check(view.state.get("result") is Dictionary,"Authoritative boss result received"): await finish(); return
	check(saw_telegraph,"Boss telegraphed damaging attacks")
	if not check(view.state.result.won,"Fresh unequipped player can defeat first boss"): await capture("expedition-loss"); await finish(); return
	check(view.state.result.reward.first_clear,"First victory granted first-clear rewards")
	check(view.state.result.reward.equipment is Dictionary,"Victory granted real equipment")
	await capture("expedition-result")
	if not await click(view,"返回秘境"): await finish(); return
	if not check(await wait_for(func():
		var stage_panel = current_expedition_lobby()
		if stage_panel==null or stage_panel.current.get("stages",[]).size()!=20: return false
		var stages: Array=stage_panel.current.stages
		return stages.any(func(stage):return stage.stage_id=="b02" and stage.unlocked) and stages.any(func(stage):return stage.stage_id=="b03" and not stage.unlocked)
	),"Next wood stage unlocked while its finale remains locked among twenty stages"): await finish(); return
	await capture("expedition-lobby")
	scene.ui.open_treasure("wish")
	if not check(await wait_for(func():return scene.state.equipment.initial_score==50),"Adventure enabled game wish rules without a health report"): await finish(); return
	if not await click(scene.ui.treasure,"祈愿一次",true): await finish(); return
	check(await wait_for(func():return scene.state.equipment.draw_count>=1),"Combat earnings fund an authoritative wish")
	await finish()
