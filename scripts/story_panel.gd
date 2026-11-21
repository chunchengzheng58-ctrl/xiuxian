extends VBoxContainer

const Adventure = preload("res://scripts/adventure_catalogue.gd")
const StoryScenePlayer = preload("res://scripts/story_scene_player.gd")
const STATUSES = {"locked": "未开启", "available": "线索待听", "active": "正在游历", "claimable": "章节奖励待领", "completed": "已归衡"}
var game: Node
var ui: Control
var cultivator_id: String
var chapter_id := ""
var current: Dictionary = {}
var busy := false
var fetching := false
var refresh_again := false
var reading_node_id := ""
var dialogue_index := 0
var selector: OptionButton
var content: VBoxContainer
var status_label: Label
var summary_label: Label
var objective_label: Label
var scene_player: Control
var home_after_refresh := false
var resume_checked := false

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var toolbar := HBoxContainer.new()
	add_child(toolbar)
	ui.button(toolbar, "全部秘境", ui.open_expedition_lobby)
	ui.button(toolbar, "装备与锻造", ui.open_treasure.bind("forge"))
	ui.button(toolbar, "刷新进度", refresh)
	summary_label = ui.paragraph(self, "正在读取游历进度…", 18)
	objective_label = ui.paragraph(self, "", 19)
	selector = OptionButton.new()
	var touch := preload("res://scripts/family_panel.gd").uses_touch_layout()
	selector.custom_minimum_size.y = 96 if touch else 44
	if touch:
		selector.add_theme_font_size_override("font_size", 28)
	selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selector.item_selected.connect(select_chapter)
	add_child(selector)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 286
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)
	status_label = ui.paragraph(self, "", 17)
	game.account_api.realtime.snapshot_received.connect(func(_snapshot): refresh())
	refresh()

func refresh() -> void:
	if is_queued_for_deletion():
		return
	if fetching or busy:
		refresh_again = true
		return
	fetching = true
	refresh_again = false
	var result := await command("snapshot")
	if is_queued_for_deletion():
		return
	fetching = false
	if result.ok:
		current = result.data
		if chapter_id.is_empty():
			chapter_id = str(current.get("current_chapter_id") if current.get("current_chapter_id") != null else "finale")
		render()
		var resumed := false
		if not resume_checked:
			resume_checked = true
			var pending: Variant = current.get("pending_scene")
			if pending is Dictionary:
				resumed = true
				home_after_refresh = false
				play_scene(pending, true)
		if home_after_refresh and not resumed:
			home_after_refresh = false
			var home: Dictionary = current.get("home", {})
			if home.get("available", false) and not home.get("completed", false) and home.get("scene") is Dictionary:
				play_scene(home.scene, true)

	if refresh_again:
		refresh.call_deferred()

func select_chapter(index: int) -> void:
	if busy:
		return
	chapter_id = str(selector.get_item_metadata(index))
	reading_node_id = ""
	dialogue_index = 0
	status_label.text = ""
	render()

func selected_chapter() -> Dictionary:
	for row in current.get("chapters", []):
		if row.id == chapter_id:
			return row
	return {}

func render() -> void:
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var adventure: Dictionary = current.get("adventure", {})
	summary_label.text = Adventure.level_text(adventure) + "   ·   " + Adventure.progress_text(adventure)
	objective_label.text = "当前主线：" + str(current.get("current_objective", ""))
	selector.clear()
	for row in current.get("chapters", []):
		var index := selector.item_count
		selector.add_item(("旁篇 · " if row.optional else "") + str(row.title) + " · " + str(STATUSES.get(row.status, "")))
		selector.set_item_metadata(index, row.id)
		if row.id == chapter_id:
			selector.select(index)
	selector.disabled = busy
	var chapter := selected_chapter()
	if chapter.is_empty():
		return
	if not reading_node_id.is_empty():
		render_dialogue(chapter)
		return
	ui.label_into(content, str(chapter.title), 25)
	ui.paragraph(content, str(chapter.get("lock_reason", "")) if chapter.status == "locked" else str(chapter.objective), 19)
	ui.paragraph(content, "正式秘境 %d / %d · %s" % [int(chapter.cleared_count), chapter.stage_ids.size(), str(STATUSES.get(chapter.status, ""))], 17)
	ui.paragraph(content, ("已领取：" if chapter.status == "completed" else "章节奖励（限领一次）：") + Adventure.reward_text(chapter.reward), 17)
	var pending: Variant = current.get("pending_scene")
	if pending is Dictionary:
		ui.button(content, "继续未看完 · " + str(pending.get("title", "灯下旧事")), play_scene.bind(pending, true), true).disabled = busy
	var variants: Dictionary = current.get("variants", {})
	var companion_name := "男" if str(variants.get("companion", "female")) == "male" else "女"
	ui.button(content, "同行者外观：阿宁（%s） · 男女剧情完全相同" % companion_name, change_companion).disabled = busy
	var actions := HBoxContainer.new()
	content.add_child(actions)
	for node in chapter.nodes:
		var button: Button = ui.button(actions, "回看 · " + str(node.title) if node.completed else str(node.title), begin_dialogue.bind(str(node.id)), node.available and not node.completed)
		button.disabled = busy or not node.available
		button.tooltip_text = str(node.lock_reason)
		if not node.available:
			ui.paragraph(content, str(node.lock_reason), 16)
	ui.button(content, "前往本章秘境", ui.open_expedition_lobby.bind(chapter_id), chapter.status in ["active", "available"]).disabled = busy
	var scene_actions := HBoxContainer.new()
	content.add_child(scene_actions)
	for scene in current.get("scenes", []):
		if str(scene.get("stage_id", "")) not in chapter.stage_ids:
			continue
		var prefix := "战前" if scene.kind == "prelude" else "战后"
		var caption := ("回看 · " if scene.get("completed", false) else "") + prefix + " · " + str(scene.get("title", ""))
		var scene_button: Button = ui.button(scene_actions, caption, play_scene.bind(scene, not scene.get("completed", false)))
		scene_button.disabled = busy or not scene.get("replayable", false)
	if chapter_id == "finale":
		var home: Dictionary = current.get("home", {})
		if home.get("available", false) and home.get("scene") is Dictionary:
			ui.button(content, "回村 · 按时吃饭" if not home.get("completed", false) else "回看 · 锅里还有", play_scene.bind(home.scene, not home.get("completed", false)), true).disabled = busy
	if chapter.status == "completed":
		var next_id: Variant = current.get("current_chapter_id")
		if next_id is String and next_id != chapter_id:
			ui.button(content, "继续主线 · " + str(Adventure.chapter(next_id).get("title", "")), show_chapter.bind(next_id), true)
		for id in chapter.stage_ids:
			ui.paragraph(content, Adventure.stage(str(id)).get("world_change", ""), 16)
	var ending: Dictionary = current.get("ending", {})
	if chapter_id == "finale" and ending.get("completed", false):
		ui.label_into(content, str(ending.title), 25)
		ui.paragraph(content, "二十秘境全部归衡" if ending.get("all_twenty_cleared", false) else "主线已完成。照生乡、玄泽与灵舟旁篇仍可随时重访。", 18)
	ui.line(content)
	ui.paragraph(content, "五行归衡印 %d / 5 · 正式秘境 %d / 20" % [current.get("seals", []).size(), int(current.get("cleared_count", 0))], 18)
	ui.paragraph(content, "冒险基础属性（穿戴装备与套装另计）\n" + Adventure.stats_text(adventure.get("base_stats", {})), 17)
	var next: Variant = adventure.get("next_level_stats")
	if next is Dictionary:
		ui.paragraph(content, "下一级基础属性\n" + Adventure.stats_text(next), 16)
	ui.paragraph(content, "正式秘境首通、再战及章节奖励增加历练，提升冒险等级。装备强化和流派在下一场秘境生效；论剑使用统一数值。", 16)

func begin_dialogue(id: String) -> void:
	reading_node_id = id
	dialogue_index = 0
	status_label.text = ""
	render()

func render_dialogue(chapter: Dictionary) -> void:
	var node: Dictionary = {}
	for row in chapter.nodes:
		if row.id == reading_node_id:
			node = row
	if node.is_empty():
		reading_node_id = ""
		render()
		return
	var dialogue: Array = node.dialogue
	dialogue_index = clampi(dialogue_index, 0, maxi(0, dialogue.size() - 1))
	ui.label_into(content, str(chapter.title) + " · " + str(node.title), 24)
	if not dialogue.is_empty():
		ui.label_into(content, str(dialogue[dialogue_index].speaker), 23)
		ui.paragraph(content, str(dialogue[dialogue_index].text), 21)
		ui.paragraph(content, "%d / %d" % [dialogue_index + 1, dialogue.size()], 16)
	if node.kind == "closure":
		ui.paragraph(content, ("已领取：" if node.completed else "本次领取：") + Adventure.reward_text(chapter.reward), 18)
	var actions := HBoxContainer.new()
	content.add_child(actions)
	ui.button(actions, "返回章节", end_dialogue).disabled = busy
	if dialogue_index > 0:
		ui.button(actions, "上一句", change_line.bind(-1)).disabled = busy
	if dialogue_index + 1 < dialogue.size():
		ui.button(actions, "继续", change_line.bind(1), true).disabled = busy
	elif not node.completed:
		ui.button(actions, "领取章节奖励" if node.kind == "closure" else "记下线索", advance.bind(reading_node_id), true).disabled = busy or not node.available or not game.state.allows_battle()
	else:
		ui.paragraph(content, "已读 · 可随时回看", 17)
	if not node.available:
		ui.paragraph(content, str(node.lock_reason), 17)
	if not game.state.allows_battle() and not node.completed:
		ui.paragraph(content, "当前角色仅可回看剧情，返回修行状态后可继续主线。", 17)

func show_chapter(id: String) -> void:
	chapter_id = id
	reading_node_id = ""
	dialogue_index = 0
	render()

func change_line(delta: int) -> void:
	dialogue_index += delta
	render()

func end_dialogue() -> void:
	reading_node_id = ""
	render()

func advance(id: String) -> void:
	if busy:
		return
	busy = true
	status_label.text = "正在保存章节进度…"
	render()
	var result := await command("advance", {"node_id": id})
	if is_queued_for_deletion():
		return
	busy = false
	if result.ok:
		reading_node_id = ""
		status_label.text = "章节进度已保存。"
		home_after_refresh = id == "finale.closure"
		# 幂等重试回执可能早于后续战斗；重新读取服务端当前进度。
		refresh()
	else:
		status_label.text = result.message + "，可刷新确认或重试。"
		render()
		if refresh_again:
			refresh.call_deferred()

func change_companion() -> void:
	if busy:
		return
	busy = true
	var variants: Dictionary = current.get("variants", {})
	var next_variant := "male" if str(variants.get("companion", "female")) == "female" else "female"
	var result := await command("variant", {"companion_variant": next_variant})
	busy = false
	if result.ok:
		current = result.data
		status_label.text = "同行者外观已保存；剧情、奖励与旗标不变。"
		render()
	else:
		status_label.text = result.message

func play_scene(scene: Dictionary, save_marker: bool = true) -> void:
	if is_instance_valid(scene_player) or scene.is_empty():
		return
	var player := StoryScenePlayer.new()
	player.scene_data = scene.duplicate(true)
	player.kernel = get_tree().root.get_node("GameKernel")
	player.cultivator_id = cultivator_id
	player.variants = current.get("variants", {})
	player.persist_marker = save_marker and not scene.get("completed", false)
	scene_player = player
	StoryScenePlayer.mount(player, get_tree().root)
	player.finished.connect(scene_finished)

func scene_finished(scene_id: String, _skipped: bool, saved: bool) -> void:
	scene_player = null
	status_label.text = "场景已保存。" if saved else "场景已播放，但标记未同步；可从本章重试。"
	await refresh()
	if saved and scene_id.begins_with("stage.") and scene_id.ends_with(".prelude"):
		var run: Variant = current.get("active_run")
		if run is Dictionary and not run.get("result") is Dictionary and scene_id == "stage.%s.prelude" % str(run.get("stage_id", "")):
			ui.open_expedition_battle(str(run.run_id))

func command(kind: String, payload: Dictionary = {}) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	return await core.dispatch("story." + kind, payload.merged({"cultivator_id": cultivator_id}))
