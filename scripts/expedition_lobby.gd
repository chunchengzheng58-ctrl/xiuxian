extends VBoxContainer

const Catalogue = preload("res://scripts/trial_catalogue.gd")
const Adventure = preload("res://scripts/adventure_catalogue.gd")
var game: Node
var ui: Control
var cultivator_id: String
var chapter_id := ""
var chapter_selector: OptionButton
var level_label: Label
var content: VBoxContainer
var status_label: Label
var current: Dictionary = {}
var busy := false
var fetching := false
var refresh_again := false

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var toolbar := HBoxContainer.new()
	add_child(toolbar)
	ui.button(toolbar, "当前主线", ui.open_story)
	ui.button(toolbar, "装备与锻造", ui.open_treasure.bind("forge"))
	ui.button(toolbar, "刷新", refresh)
	level_label = ui.paragraph(self, "", 17)
	chapter_selector = OptionButton.new()
	var touch := preload("res://scripts/family_panel.gd").uses_touch_layout()
	chapter_selector.custom_minimum_size.y = 96 if touch else 42
	if touch:
		chapter_selector.add_theme_font_size_override("font_size", 28)
	chapter_selector.add_item("全部区域 · 二十秘境")
	chapter_selector.set_item_metadata(0, "")
	for chapter in Adventure.DATA.data.chapters:
		var index := chapter_selector.item_count
		chapter_selector.add_item(("旁篇 · " if chapter.optional else "") + str(chapter.title))
		chapter_selector.set_item_metadata(index, chapter.id)
		if chapter.id == chapter_id:
			chapter_selector.select(index)
	chapter_selector.item_selected.connect(func(index):
		chapter_id = str(chapter_selector.get_item_metadata(index))
		render())
	add_child(chapter_selector)
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
	status_label = ui.paragraph(self, "正在读取秘境…", 17)
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
	var result := await command("lobby")
	if is_queued_for_deletion():
		return
	fetching = false
	if result.ok:
		if status_label.text == "正在读取秘境…":
			status_label.text = ""
		if current != result.data:
			current = result.data
			render()
	else:
		status_label.text = result.message
	if refresh_again:
		refresh.call_deferred()

func render() -> void:
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var adventure: Dictionary = current.get("adventure", {})
	level_label.text = Adventure.level_text(adventure) + " · " + Adventure.progress_text(adventure)
	chapter_selector.disabled = busy
	var active: Variant = current.get("active")
	if active is Dictionary and not active.is_empty():
		ui.label_into(content, "上次探索尚未结束", 22)
		ui.button(content, "继续探索", ui.open_expedition_battle.bind(str(active.run_id)), true)
		ui.line(content)
	var region := ""
	for stage in current.get("stages", []):
		if not chapter_id.is_empty() and stage.get("chapter_id", "") != chapter_id:
			continue
		if str(stage.get("region", "")) != region:
			region = str(stage.get("region", ""))
			ui.label_into(content, str(Adventure.chapter(str(stage.get("chapter_id", ""))).get("title", region + "域")), 24)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		content.add_child(row)
		var portrait := TextureRect.new()
		portrait.texture = Catalogue.boss_texture(str(stage.boss_id))
		portrait.custom_minimum_size = Vector2(104, 112)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(portrait)
		var details := VBoxContainer.new()
		details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(details)
		ui.label_into(details, str(stage.name) + (" · 已首通" if stage.get("cleared", false) else ""), 22)
		ui.paragraph(details, str(stage.get("subtitle", "")), 16)
		ui.paragraph(details, str(stage.get("recommendation", "")) + "\n" + str(stage.get("tactics", "")), 16)
		ui.paragraph(details, "首通：" + reward_text(stage.get("first_reward", {})) + "\n再战：" + reward_text(stage.get("repeat_reward", {})), 16)
		if not stage.get("unlocked", false):
			ui.paragraph(details, str(stage.get("unlock_reason", "尚未解锁")), 16)
		var enter: Button = ui.button(row, "再次挑战" if stage.get("cleared", false) else "进入秘境", start.bind(str(stage.stage_id)), true)
		enter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		enter.disabled = busy or not stage.get("unlocked", false) or (active is Dictionary and not active.is_empty())
		if not stage.get("unlocked", false):
			enter.text = "尚未解锁"
		ui.line(content)
	ui.paragraph(content, "穿戴装备、强化和流派套装均在入场时生效。避开红色预警，抓住收招时机。失败可以重试。", 17)
	var recent: Array = current.get("recent", [])
	if not recent.is_empty():
		ui.line(content)
		ui.label_into(content, "近期探索", 21)
		for index in range(mini(3, recent.size())):
			var record: Dictionary = recent[index]
			var stage := Catalogue.entry(str(record.stage_id))
			var note: String = str(stage.get("name", "秘境")) + " · "
			if record.won:
				note += ("首通" if record.reward.get("first_clear", false) else "再战通关") + " · " + reward_text(record.reward)
			else:
				note += str(preload("res://scripts/expedition_view.gd").END_REASONS.get(record.reason, "本场结束"))
			ui.paragraph(content, note, 16)

static func reward_text(reward: Dictionary) -> String:
	var text := Adventure.reward_text(reward)
	if reward.get("equipment", false):
		text += " · 装备"
	return text

func start(stage_id: String) -> void:
	if busy:
		return
	busy = true
	status_label.text = "正在进入秘境…"
	render()
	var result := await command("start", {"stage_id": stage_id})
	if is_queued_for_deletion():
		return
	busy = false
	if result.ok:
		ui.open_expedition_battle(str(result.data.run_id))
	else:
		status_label.text = result.message
		render()
		refresh()

func command(kind: String, payload: Dictionary = {}) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	return await core.dispatch("combat.expedition_" + kind, payload.merged({"cultivator_id": cultivator_id}))
