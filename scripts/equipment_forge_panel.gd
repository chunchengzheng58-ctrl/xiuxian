extends VBoxContainer

const Rules = preload("res://scripts/equipment_rules.gd")
const Icon = preload("res://scripts/equipment_icon.gd")
var host: Control
var selected_id: String = ""
var busy := false
var message: String = ""
var rendered_signature: String = ""

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	render()

func projection_signature() -> String:
	var equipment: Dictionary = host.game.state.equipment
	return JSON.stringify({"cultivator_id": host.game.state.cultivator_id, "inventory": equipment.inventory, "equipped": equipment.equipped, "qi": equipment.qi, "materials": equipment.get("materials", 0)}, "", true)

func refresh_projection() -> void:
	if busy or not is_inside_tree() or is_queued_for_deletion():
		return
	if projection_signature() != rendered_signature:
		render()

func render() -> void:
	if not busy:
		rendered_signature = projection_signature()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	host.text(self, "锻造台", 27, host.GOLD_TEXT)
	if not host.game.state.is_remote():
		host.paragraph_text(self, "登录游戏账号后，可以强化、铭刻和分解装备。", 18)
		return
	host.text(self, "锻材 %d  ·  灵气 %d" % [int(host.game.state.equipment.get("materials", 0)), int(host.game.state.equipment.qi)], 19, host.GOLD_TEXT)
	var selector := OptionButton.new()
	selector.custom_minimum_size.y = 42
	selector.add_theme_font_size_override("font_size", 19)
	selector.disabled = busy
	add_child(selector)
	var inventory: Array = host.game.state.equipment.inventory
	var selected: Dictionary = {}
	for index in range(inventory.size()):
		var item: Dictionary = inventory[index]
		selector.add_item(Rules.detail(item).name)
		if item.id == selected_id:
			selector.select(index)
			selected = item
	if selected.is_empty() and not inventory.is_empty():
		selected = inventory[0]
		selected_id = selected.id
	selector.item_selected.connect(func(index): selected_id = inventory[index].id; host.selected_id = selected_id; render())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 420
	add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)
	if selected.is_empty():
		host.paragraph_text(content, "行囊里还没有装备。祈愿或在万宝集购买后，就可以开始锻造。", 18)
	else:
		build_item(content, selected)
	host.paragraph_text(self, "正在锻造…" if busy else message, 16, host.GOLD_TEXT)

func build_item(content: VBoxContainer, item: Dictionary) -> void:
	var info := Rules.detail(item)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	content.add_child(header)
	var icon := Icon.new()
	icon.setup(item)
	icon.custom_minimum_size = Vector2(120, 120)
	header.add_child(icon)
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(detail)
	host.paragraph_text(detail, "%s · %s" % [info.name, info.quality], 22, info.color)
	host.text(detail, Rules.bonus_text(item), 19)
	host.paragraph_text(detail, "同流派 2 件与 4 件装备可激活额外加成。强化提升这件装备的基础加成。", 16)
	if item.has("market_listing_id"):
		host.paragraph_text(content, "这件装备正在万宝集出售，撤单后可以锻造。", 18)
		return
	var upgrade := HBoxContainer.new()
	content.add_child(upgrade)
	var cost := Rules.upgrade_cost(info.level)
	var next := item.duplicate()
	next["upgrade_level"] = mini(info.level + 1, int(Rules.GROWTH.max_level))
	var maxed: bool = info.level >= int(Rules.GROWTH.max_level)
	host.text(upgrade, "已达强化上限 +%d" % info.level if maxed else "强化 +%d → +%d  ·  %s" % [info.level, next.upgrade_level, Rules.bonus_text(next)], 18).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.action(upgrade, "强化 · %d 锻材 / %d 灵气" % [cost.materials, cost.qi], mutate.bind("upgrade", {"equipment_id": info.id, "expected_level": info.level}, "强化成功"), true).disabled = busy or maxed or not can_afford(cost.materials, cost.qi)
	var attune := HBoxContainer.new()
	content.add_child(attune)
	var school := OptionButton.new()
	school.custom_minimum_size.y = 44
	school.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	school.add_theme_font_size_override("font_size", 18)
	school.disabled = busy
	for config in Rules.GROWTH.schools:
		school.add_item(config.name)
	school.select(maxi(0, info.school))
	attune.add_child(school)
	var attune_button: Button = host.action(attune, "铭刻 · %d 锻材 / %d 灵气" % [int(Rules.GROWTH.attune_materials), int(Rules.GROWTH.attune_qi)], func():
		mutate("attune", {"equipment_id": info.id, "school": school.selected, "expected_school": info.school}, "铭刻完成")
	)
	var attune_unavailable: bool = busy or not can_afford(int(Rules.GROWTH.attune_materials), int(Rules.GROWTH.attune_qi))
	attune_button.disabled = attune_unavailable or school.selected == info.school
	school.item_selected.connect(func(index): attune_button.disabled = attune_unavailable or index == info.school)
	for config in Rules.GROWTH.schools:
		host.paragraph_text(content, "%s    2 件 %s  ·  4 件 %s" % [config.name, bonuses_text(config.two), bonuses_text(config.four)], 17, Color(config.color))
	var salvage := HBoxContainer.new()
	content.add_child(salvage)
	host.paragraph_text(salvage, "分解将消耗这件装备，获得 %d 锻材。" % Rules.salvage_yield(item), 17).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var equipped: bool = host.game.state.equipment.equipped.get(info.slot, "") == info.id
	var salvage_button: Button = host.action(salvage, "分解装备", confirm_salvage.bind(item))
	salvage_button.disabled = busy or equipped
	if equipped:
		salvage_button.tooltip_text = "先在行囊卸下装备，再分解。"

func can_afford(materials: int, qi: int) -> bool:
	return int(host.game.state.equipment.get("materials", 0)) >= materials and int(host.game.state.equipment.qi) >= qi

func bonuses_text(bonuses: Dictionary) -> String:
	var parts := PackedStringArray()
	for stat in bonuses:
		parts.append("%s +%d" % [Rules.STAT_NAMES[stat], int(bonuses[stat])])
	return "、".join(parts)

func confirm_salvage(item: Dictionary) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "分解装备"
	dialog.dialog_text = "消耗「%s」并获得 %d 锻材？" % [Rules.detail(item).name, Rules.salvage_yield(item)]
	dialog.ok_button_text = "确认分解"
	dialog.cancel_button_text = "保留装备"
	add_child(dialog)
	dialog.confirmed.connect(func(): dialog.queue_free(); mutate("salvage", {"equipment_id": item.id}, "装备已分解"))
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func mutate(kind: String, payload: Dictionary, note: String) -> void:
	if busy:
		return
	busy = true
	render()
	var state = host.game.state
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("growth." + kind, payload.merged({"cultivator_id": state.cultivator_id}))
	if not is_inside_tree():
		return
	message = note if result.ok else result.message
	if result.ok:
		if not await host.sync_market_character():
			message += "，行囊将在下次同步后更新。"
	busy = false
	render()
