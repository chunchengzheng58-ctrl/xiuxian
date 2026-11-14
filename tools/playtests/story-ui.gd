extends "res://tools/playtests/expedition-ui.gd"

const Adventure = preload("res://scripts/adventure_catalogue.gd")
var records: Array = []
var claimed: Dictionary = {}

func _initialize() -> void:
	root.position = Vector2i(-12000, -12000)
	root.size = Vector2i(1440, 900)
	work = OS.get_environment("XIUXIAN_STORY_WORK")
	output = OS.get_environment("XIUXIAN_STORY_OUTPUT")
	run.call_deferred()

func check(ok: bool, label: String) -> bool:
	print("STORY_UI ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
	return ok

func finish() -> void:
	move(Vector2.ZERO)
	var file := FileAccess.open(work.path_join("client-result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": failures, "records": records, "claimed": claimed, "adventure": scene.state.adventure, "equipment": scene.state.equipment}, "  "))
	file.close()
	print("STORY_UI ", failures, " failures")
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func click_control(button: Button) -> bool:
	var scroll: Node = button.get_parent()
	while scroll != null and not scroll is ScrollContainer: scroll = scroll.get_parent()
	if scroll is ScrollContainer:
		scroll.ensure_control_visible(button)
	await process_frame
	await process_frame
	if not is_instance_valid(button): return false
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
	return check(received[0], "Real mouse click " + button.text if is_instance_valid(button) else "Real mouse click before page transition")

func find_script(script_path: String) -> Node:
	if not is_instance_valid(scene.ui.modal): return null
	for node in scene.ui.modal.find_children("*", "", true, false):
		if node.get_script() != null and node.get_script().resource_path == script_path: return node
	return null

func lobby() -> Node:
	return find_script("res://scripts/expedition_lobby.gd")

func chapter(id: String) -> Dictionary:
	for row in scene.ui.story_panel.current.get("chapters", []):
		if row.id == id: return row
	return {}

func story_ready() -> bool:
	return is_instance_valid(scene.ui.story_panel) and not scene.ui.story_panel.current.is_empty() and not scene.ui.story_panel.fetching

func read_node(id: String, claim := true) -> bool:
	if not check(await wait_for(story_ready), "Story snapshot ready for " + id): return false
	var panel = scene.ui.story_panel
	var row: Dictionary = chapter(panel.chapter_id)
	var node: Dictionary = row.nodes.filter(func(value):return value.id==id)[0]
	var caption: String = ("回看 · " if node.completed else "") + str(node.title)
	if not await click(panel,caption): return false
	check(panel.reading_node_id==id,"Dialogue opens the selected persisted node")
	for index in range(node.dialogue.size()):
		check(panel.dialogue_index==index,"Dialogue line " + str(index+1) + " is shown in order")
		check(panel.content.find_children("*","Label",true,false).any(func(label):return label.text==str(node.dialogue[index].text)),"Authored dialogue text is rendered")
		if index+1<node.dialogue.size():
			if not await click(panel,"继续"): return false
	if node.kind=="closure":
		check(panel.content.find_children("*","Label",true,false).any(func(label):return label.text.contains(Adventure.reward_text(row.reward))),"Closure displays the chapter reward before confirmation")
	if claim and not node.completed:
		if not await click(panel,"领取章节奖励" if node.kind=="closure" else "记下线索"): return false
		return check(await wait_for(func():return story_ready() and chapter(row.id).nodes.any(func(value):return value.id==id and value.completed)),"Confirmed dialogue persists: " + id)
	return true

func sync_equipment(template: int, slot: String) -> bool:
	if not check(await wait_for(func():return scene.state.equipment.inventory.any(func(item):return int(item.template)==template)),"Earned equipment reached authoritative inventory"): return false
	var item: Dictionary = scene.state.equipment.inventory.filter(func(gear):return int(gear.template)==template)[0]
	var core := root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("growth.equip", {"cultivator_id": scene.state.cultivator_id,"equipment_id": item.id,"slot": slot})
	if not check(result.ok,"Equip an actual first-clear drop through the production API"): return false
	if not check(await wait_for(func():return scene.state.equipment.equipped.get(slot)==item.id),"Equipped drop syncs into the client"): return false
	result = await core.dispatch("growth.upgrade", {"cultivator_id": scene.state.cultivator_id,"equipment_id": item.id,"expected_level": 0})
	if not check(result.ok,"Pay the published resource cost for gear +1"): return false
	return check(await wait_for(func():return scene.state.equipment.inventory.any(func(gear):return gear.id==item.id and int(gear.get("upgrade_level",0))==1)),"Paid upgrade syncs into the client")

func unsafe_zone(zone: Dictionary, point: Vector2) -> bool:
	if zone.kind=="polygon":
		for polygon in zone.get("polygons", []):
			var shape := PackedVector2Array()
			for vertex in polygon: shape.append(Vector2(vertex[0],vertex[1]))
			if Geometry2D.is_point_in_polygon(point,shape): return true
		return false
	if zone.kind=="circle": return point.distance_to(Vector2(zone.x,zone.y))<float(zone.radius)+10
	var start := Vector2(zone.x,zone.y)
	var end := Vector2(zone.get("x2",zone.x),zone.get("y2",zone.y))
	return point.distance_to(Geometry2D.get_closest_point_to_segment(point,start,end))<float(zone.get("width",0))*0.5+10

func point_score(point: Vector2, position: Vector2, enemy: Vector2, snapshot: Dictionary) -> float:
	var travel := position.distance_to(point)
	var score := travel*0.8+absf(point.distance_to(enemy)-96)*1.6
	for zone in snapshot.get("telegraphs",[])+snapshot.get("hazards",[]):
		if unsafe_zone(zone,point): score+=10000
	for shot in snapshot.get("enemy_projectiles",[]):
		if point.distance_to(Vector2(shot.x,shot.y))<float(shot.radius)+40: score+=5000
	for warning in snapshot.get("telegraphs",[]):
		var fraction := minf(1,maxf(0,float(warning.get("remaining",0))-0.12)*210/maxf(1,travel))
		if unsafe_zone(warning,position.lerp(point,fraction)): score+=3000
	return score

func intentions(snapshot: Dictionary) -> Dictionary:
	var own: Dictionary = snapshot.player
	var target := Vector2(snapshot.enemy.x,snapshot.enemy.y)
	var position := Vector2(own.x,own.y)
	var candidates: Array[Vector2] = [position]
	for angle in range(16):
		for radius in [96,190]:
			var point: Vector2 = target+Vector2(cos(angle*PI/8),sin(angle*PI/8))*radius
			candidates.append(Vector2(clampf(point.x,235,1205),clampf(point.y,405,700)))
	for x in range(245,1220,120):
		for y in range(410,715,70): candidates.append(Vector2(x,y))
	var destination := position
	var score := point_score(position,position,target,snapshot)
	for point in candidates:
		var value := point_score(point,position,target,snapshot)
		if value<score: score=value; destination=point
	var moving := position.distance_to(destination)>5
	var direction := (destination-position if moving else target-position).normalized()
	var danger := false
	var heal_safe := true
	for zone in snapshot.get("telegraphs",[]):
		if unsafe_zone(zone,position):
			if float(zone.get("remaining",10))<0.32: danger=true
			if float(zone.get("remaining",10))<1.2: heal_safe=false
	for zone in snapshot.get("hazards",[]):
		if unsafe_zone(zone,position): heal_safe=false
	for shot in snapshot.get("enemy_projectiles",[]):
		if position.distance_to(Vector2(shot.x,shot.y))<150: heal_safe=false
	var action := 1 if position.distance_to(target)<126 and direction.dot(target-position)>0 else 0
	if own.hp<float(own.max_hp)*0.64 and int(own.cd[5])==0 and own.mp>=40 and heal_safe: action=5
	elif danger and int(own.cd[3])==0 and own.stamina>=24 and moving: action=3
	elif danger and int(own.cd[4])==0 and own.mp>=24: action=4
	elif position.distance_to(target)>145 and position.distance_to(target)<520 and direction.dot(target-position)>0 and int(own.cd[2])==0 and own.mp>65: action=2
	return {"direction": direction*(1.0 if moving else 0.75), "action": action}

func choose_stage(id: String) -> bool:
	if not check(await wait_for(func():return lobby()!=null and lobby().current.get("stages",[]).size()==20),"Twenty formal stages loaded"): return false
	var stage: Dictionary = Adventure.stage(id)
	var row: Node
	for label in lobby().content.find_children("*","Label",true,false):
		if label.text==stage.name or label.text==stage.name+" · 已首通": row=label.get_parent().get_parent(); break
	if not check(row!=null,"Selected stage card exists: " + id): return false
	var button := find_button(row,"进入秘境")
	if not check(button!=null,"Selected stage is available: " + id): return false
	return await click_control(button)

func fight(id: String, just_preview := false) -> bool:
	if not check(await wait_for(func():return is_instance_valid(scene.ui.expedition_view) and scene.ui.expedition_view.state.get("phase")=="fighting"),"Entered live authoritative " + id): return false
	var view = scene.ui.expedition_view
	check(view.state.boss_id==id,"Actual server boss matches the chosen stage")
	var photographed := false
	var deadline := Time.get_ticks_msec()+120000
	while view.state.get("result")==null and Time.get_ticks_msec()<deadline:
		if view.state.phase=="fighting":
			var input := intentions(view.state)
			move(input.direction)
			if input.action>0: view.queue_action(input.action)
			if not photographed and (not view.state.get("telegraphs",[]).is_empty() or not view.state.get("enemy_projectiles",[]).is_empty()):
				await capture("story-"+id+"-fight")
				photographed=true
				if just_preview: break
		await create_timer(0.07).timeout
	move(Vector2.ZERO)
	if just_preview:
		if not await click(view,"退出挑战"): return false
		var dialogs: Array = view.find_children("*","ConfirmationDialog",true,false)
		if not check(not dialogs.is_empty(),"Non-wood preview exits through confirmation"): return false
		dialogs[0].get_ok_button().pressed.emit()
		return check(await wait_for(func():return not is_instance_valid(scene.ui.expedition_view)),"Preview leaves the real fire battle without claiming a victory")
	if not check(view.state.get("result") is Dictionary and view.state.result.won,"Actual player inputs defeated " + id):
		await capture("story-"+id+"-failure"); return false
	check(view.state.result.reward.first_clear,"Real first-clear reward: " + id)
	records.append({"stage":id,"result":view.state.result.duplicate(true)})
	await capture("story-"+id+"-result")
	return await click(view,"查看本章剧情")

func run() -> void:
	scene=load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override=work.path_join("cache")
	scene.account_legacy_source_override=work.path_join("missing-save.json")
	root.add_child(scene)
	current_scene=scene
	scene.account_api.allow_autostart=false
	scene.ui.open_login()
	if not await click(scene.ui.account_panel,"注册"): await finish(); return
	var registration=scene.ui.account_panel
	registration.username_input.text="story_runner"
	registration.password_input.text="story-ui-fixture-password"
	registration.repeat_input.text=registration.password_input.text
	registration.display_input.text="守灯旅人"
	registration.register_avatar.select(1)
	if not await click(registration,"注册并登录"): await finish(); return
	if not check(await wait_for(func():return scene.account_ready and scene.state.is_remote()),"Real registration and login created a fresh remote self"): await finish(); return
	check(scene.state.equipment.inventory.is_empty() and scene.state.equipment.qi==0,"No test resources or gear were injected")
	scene.ui.close_modal()
	await process_frame
	if not await click(scene.ui,"五域游历 / 主线"): await finish(); return
	if not check(await wait_for(story_ready),"Default mainline snapshot loaded"): await finish(); return
	check(scene.ui.story_panel.chapter_id=="wood","New account defaults to the wood main chapter")
	check(scene.ui.story_panel.objective_label.text.contains("朽梁"),"Current objective names the actual first boss")
	await capture("story-first-objective")
	if not await read_node("wood.intro"): await finish(); return
	if not await click(scene.ui.story_panel,"刷新进度"): await finish(); return
	check(await wait_for(func():return story_ready() and chapter("wood").nodes[0].completed),"Intro persists after an explicit server refresh")
	scene.ui.close_modal()
	await process_frame
	if not await click(scene.ui,"五域游历 / 主线"): await finish(); return
	check(await wait_for(func():return story_ready() and chapter("wood").nodes[0].completed),"Intro persists after closing and reopening mainline")
	for id in ["b01","b02","b03"]:
		if not await click(scene.ui.story_panel,"前往本章秘境"): await finish(); return
		if not await choose_stage(id): await finish(); return
		if not await fight(id): await finish(); return
		if not check(await wait_for(story_ready),"Story restored after battle"): await finish(); return
		if id=="b01" and not await sync_equipment(0,"weapon"): await finish(); return
		if id=="b02" and not await sync_equipment(1,"robe"): await finish(); return
	check(await wait_for(func():return scene.state.adventure.get("cleared_count")==3 and scene.state.adventure.get("seal_count")==1),"HUD data syncs three formal clears and one wood seal")
	check(scene.ui.counters[0].text.begins_with("冒险等级 ") and scene.ui.counters[2].text=="秘境首通 3" and scene.ui.counters[3].text=="归衡印 1","HUD renders adventure level, formal clears and seals")
	var before := {"qi":scene.state.equipment.qi,"materials":scene.state.equipment.materials,"xp":scene.state.adventure.xp}
	if not await read_node("wood.closure"): await finish(); return
	var reward: Dictionary=Adventure.chapter("wood").reward
	if not check(await wait_for(func():return scene.state.equipment.qi==before.qi+int(reward.spirit_stones) and scene.state.equipment.materials==before.materials+int(reward.materials) and scene.state.adventure.xp==before.xp+int(reward.adventure_xp)),"Chapter reward and experience arrive exactly once in the live client"): await finish(); return
	claimed={"qi":scene.state.equipment.qi,"materials":scene.state.equipment.materials,"xp":scene.state.adventure.xp}
	await capture("story-wood-completed")
	if not await read_node("wood.closure",false): await finish(); return
	check(find_button(scene.ui.story_panel,"领取章节奖励")==null,"Revisited closure has no second claim action")
	if not await click(scene.ui.story_panel,"返回章节"): await finish(); return
	if not await click(scene.ui.story_panel,"刷新进度"): await finish(); return
	check(await wait_for(func():return story_ready() and chapter("wood").status=="completed"),"Claimed chapter persists after refresh")
	check(scene.state.equipment.qi==claimed.qi and scene.state.equipment.materials==claimed.materials and scene.state.adventure.xp==claimed.xp,"Replay and refresh cannot change the reward")
	var next_button := find_button(scene.ui.story_panel,"继续主线",true)
	if not check(next_button!=null,"Completed chapter exposes its next mainline action"): await finish(); return
	if not await click_control(next_button): await finish(); return
	check(await wait_for(func():return story_ready() and scene.ui.story_panel.chapter_id=="fire"),"Completed chapter action opens the next fire chapter")
	scene.ui.close_modal()
	await process_frame
	if not await click(scene.ui,"五域游历 / 主线"): await finish(); return
	if not check(await wait_for(func():return story_ready() and scene.ui.story_panel.chapter_id=="fire"),"Reopening resumes the next unlocked fire chapter"): await finish(); return
	if not await read_node("fire.intro"): await finish(); return
	if not await click(scene.ui.story_panel,"前往本章秘境"): await finish(); return
	if not check(await wait_for(func():return lobby()!=null and lobby().chapter_id=="fire" and not lobby().fetching and lobby().current.get("stages",[]).size()==20),"Chapter action selects the loaded fire filter"): await finish(); return
	var labels: Array=lobby().content.find_children("*","Label",true,false).map(func(label):return label.text)
	check(labels.any(func(text):return text==Adventure.stage("b04").name) and labels.any(func(text):return text==Adventure.stage("b05").name) and labels.any(func(text):return text==Adventure.stage("b06").name) and not labels.any(func(text):return text==Adventure.stage("b01").name+" · 已首通"),"Fire filter shows its three stages instead of wood cards")
	await capture("story-fire-lobby")
	if not await choose_stage("b04"): await finish(); return
	if not await fight("b04",true): await finish(); return
	check(scene.state.equipment.qi==claimed.qi and scene.state.equipment.materials==claimed.materials,"Leaving a previewed fire fight does not award resources")
	await finish()
