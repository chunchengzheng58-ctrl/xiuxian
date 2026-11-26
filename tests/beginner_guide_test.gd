extends SceneTree

var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	print("GUIDE ", "PASS " if value else "FAIL ", message)
	if not value:
		failures += 1

func find_button(scope: Node, title: String) -> Button:
	for button in scope.find_children("*", "Button", true, false):
		if button.text == title and button.is_visible_in_tree():
			return button
	return null

func run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.account_ready = true
	game.family.persist_enabled = false
	game.state.persist_enabled = false
	game.ui.close_modal(true)
	game.state.equipment.starter_ten_pulls = 1
	game.ui.open_beginner_guide()
	var first = find_button(game.ui.modal, "去聚宝阁 →")
	check(first != null, "New character starts at equipment draw")
	if first != null:
		first.pressed.emit()
	check(is_instance_valid(game.ui.treasure), "First action opens treasure")
	game.ui.close_modal()
	game.state.equipment.starter_ten_pulls = 0
	game.state.equipment.inventory = [{"id": "guide-item", "template": 0, "rarity": 0}]
	game.ui.open_beginner_guide()
	var bag = find_button(game.ui.modal, "打开行囊 →")
	check(bag != null, "Equipment ownership advances the guide")
	if bag != null:
		bag.pressed.emit()
	check(is_instance_valid(game.ui.treasure) and game.ui.treasure.tab == "bag", "Bag action selects the bag")
	game.ui.close_modal()
	game.state.equipment.equipped = {"weapon": "guide-item"}
	game.ui.open_beginner_guide()
	check(find_button(game.ui.modal, "进入主线 →") != null, "Equipped character advances to first challenge")
	game.ui.close_modal()
	game.state.cleared_stages.append("b00")
	game.ui.open_beginner_guide()
	check(find_button(game.ui.modal, "查看今日计划 →") != null, "First clear exposes the optional daily plan")
	game.ui.close_modal()
	game.ui.open_boss()
	game.ui.corridor.focus_boss(2)
	check("目标第 01 关" in game.ui.corridor.focus_label.text, "Corridor points toward the first available challenge")
	check(find_button(game.ui.corridor, "回到可挑战入口") != null, "Corridor has a return-to-challenge action")
	game.queue_free()
	await process_frame
	print("BEGINNER_GUIDE_TEST failures=", failures)
	quit(1 if failures else 0)
