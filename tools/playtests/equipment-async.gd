extends SceneTree
const Rules = preload("res://scripts/equipment_rules.gd")
var scene: Node
var work := ""
var failures := 0
var checks: Array = []
var action_done := false

func _initialize() -> void:
	work = OS.get_environment("XIUXIAN_EQUIPMENT_ASYNC_WORK")
	run.call_deferred()

func check(ok: bool, note: String) -> void:
	checks.append({"passed":ok,"note":note})
	if not ok: failures += 1
	print("EQUIPMENT_ASYNC ","PASS " if ok else "FAIL ",note)

func wait_for(predicate: Callable, seconds := 12.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while not predicate.call() and Time.get_ticks_msec() < end:
		await process_frame
	return predicate.call()

func mark(name: String) -> void:
	var f := FileAccess.open(work.path_join(name),FileAccess.WRITE)
	f.store_string("1")
	f.close()

func wear(panel: Control, item: Dictionary) -> void:
	action_done = false
	await panel.remote_wear(Rules.detail(item),false)
	action_done = true

func wish(panel: Control) -> void:
	action_done = false
	await panel.set_wish_school(1)
	action_done = true

func buy(panel: Control, listing_id: String) -> void:
	action_done = false
	await panel.mutate("buy",{"listing_id":listing_id},"已购入")
	action_done = true

func draw_once(panel: Control) -> void:
	action_done = false
	await panel.summon(1)
	action_done = true

func market_panel() -> Control:
	for node in scene.ui.treasure.find_children("*","VBoxContainer",true,false):
		if node.get_script() != null and node.get_script().resource_path == "res://scripts/equipment_market_panel.gd": return node
	return null

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = work.path_join("cache")
	scene.account_legacy_source_override = work.path_join("missing.json")
	root.add_child(scene)
	scene.account_api.allow_autostart = false
	scene.ui.open_login()
	var login = scene.ui.account_panel
	login.username_input.text = "async_buyer"
	login.password_input.text = "equipment-async-password"
	login.submit()
	if not await wait_for(func():return scene.account_ready and scene.state.is_remote()):
		check(false,"Login into explicit memory fixture")
		await finish();return
	scene.ui.close_modal(true)
	scene.ui.open_treasure("bag")
	var panel = scene.ui.treasure
	var item: Dictionary = scene.state.equipment.inventory[0]
	wear(panel,item)
	check(await wait_for(func():return FileAccess.file_exists(work.path_join("held-equip"))),"Equip response held after real server commit")
	panel.switch_tab("market")
	check(panel.tab == "bag","Pending wear prevents destructive tab switch")
	mark("advance-equip")
	check(await wait_for(func():return scene.state.equipment.qi == 1123),"Newer realtime wallet reaches active owner")
	mark("release-equip")
	check(await wait_for(func():return FileAccess.file_exists(work.path_join("held-equip-list"))),"Versioned refresh response held before a newer push")
	check(await wait_for(func():return scene.state.equipment.qi == 1154),"Newer wallet arrives while refresh is still in flight")
	mark("release-equip-list")
	check(await wait_for(func():return action_done),"Original equip response resolves")
	check(scene.state.equipment.qi == 1154,"Old equip and refresh responses cannot roll back newer wallet")
	await scene.account_api.sync_family(scene.family)
	panel.switch_tab("wish")
	wish(panel)
	check(await wait_for(func():return FileAccess.file_exists(work.path_join("held-wish"))),"Wish-focus response held after commit")
	mark("advance-wish")
	check(await wait_for(func():return scene.state.equipment.qi == 1277),"Second newer realtime wallet received")
	mark("release-wish")
	check(await wait_for(func():return action_done),"Wish focus resolves")
	check(scene.state.equipment.qi == 1277,"Old wish-focus response cannot roll back newer wallet")
	await scene.account_api.sync_family(scene.family)
	panel.switch_tab("market")
	check(await wait_for(func():return market_panel() != null and not market_panel().busy),"Loaded market")
	var market := market_panel()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(work.path_join("fixture.json")))
	buy(market,str(fixture.listing_id))
	check(await wait_for(func():return FileAccess.file_exists(work.path_join("held-buy"))),"Purchase response held after server commit")
	panel.switch_tab("wish")
	check(panel.tab == "market","Pending purchase preserves its response owner")
	scene.ui.close_modal()
	await process_frame
	check(is_instance_valid(scene.ui.treasure),"Pending purchase cannot free the receipt view")
	mark("release-buy")
	check(await wait_for(func():return action_done,3.0),"Held purchase completes without a freed-object callback")
	await scene.account_api.sync_family(scene.family)
	check(scene.state.equipment.qi == 1177 and scene.state.equipment.inventory.size() == 2,"One purchase has exact wallet and original item")
	panel.switch_tab("wish")
	draw_once(panel)
	check(await wait_for(func():return action_done),"Committed wish returns an uncertain HTTP failure")
	var pending: Dictionary = scene.state.equipment.get("pending_draw",{})
	check(int(pending.get("count",0)) == 1 and not str(pending.get("request_id","")).is_empty(),"Uncertain wish retains its original request")
	draw_once(panel)
	check(await wait_for(func():return action_done),"Retry of the original wish finishes")
	check(scene.state.equipment.get("pending_draw",{}).is_empty(),"Confirmed wish releases pending recovery state")
	check(scene.state.equipment.qi == 1107 and scene.state.equipment.inventory.size() == 3 and scene.state.equipment.draw_count == 1,"Wish recovery has one debit and one original item")
	await finish()

func finish() -> void:
	var file := FileAccess.open(work.path_join("result.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures":failures,"checks":checks}))
	file.close()
	scene.ui.close_modal(true)
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)
