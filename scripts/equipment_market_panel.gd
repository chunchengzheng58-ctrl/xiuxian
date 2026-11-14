extends VBoxContainer

const Rules = preload("res://scripts/equipment_rules.gd")
const Icon = preload("res://scripts/equipment_icon.gd")
var host: Control
var offer: Dictionary = {}
var scope: String = "browse"
var slot: String = "all"
var cursors: Array[int] = [0]
var next_cursor: int = 0
var listings: Array = []
var message: String = ""
var price_text: String = "70"
var busy: bool = false
var submitting := false

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 9)
	if host.market_available():
		reload()
	else:
		render()

func render() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	host.text(self, "万宝集", 27, host.GOLD_TEXT)
	if not host.market_available():
		host.paragraph_text(self, "登录游戏账号并切换到本人角色，即可与其他玩家交易。", 18)
		return
	if not offer.is_empty():
		build_offer()
	var tabs := HBoxContainer.new()
	add_child(tabs)
	host.action(tabs, "在售装备", choose_scope.bind("browse"), scope == "browse").disabled = busy
	host.action(tabs, "我的交易", choose_scope.bind("mine"), scope == "mine").disabled = busy
	host.action(tabs, "刷新", reload).disabled = busy
	var filters := HBoxContainer.new()
	add_child(filters)
	for value in ["all"] + Rules.SLOTS:
		host.action(filters, "全部" if value == "all" else Rules.SLOT_NAMES[value], choose_slot.bind(value), slot == value).disabled = busy
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 226
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)
	for listing in listings:
		build_listing(rows, listing)
	if listings.is_empty() and not busy:
		host.paragraph_text(rows, "这一页没有装备。" if scope == "browse" else "这里会显示你的挂单、购买和售出记录。", 18)
	var footer := HBoxContainer.new()
	add_child(footer)
	host.action(footer, "上一页", previous_page).disabled = busy or cursors.size() == 1
	host.action(footer, "下一页", next_page).disabled = busy or next_cursor == 0
	host.paragraph_text(footer, "正在联系万宝集…" if busy else message, 16).size_flags_horizontal = Control.SIZE_EXPAND_FILL

func build_offer() -> void:
	var info := Rules.detail(offer)
	host.text(self, "上架 · %s · %s" % [info.name, info.quality], 18, info.color)
	var form := HBoxContainer.new()
	add_child(form)
	var price := LineEdit.new()
	price.custom_minimum_size.x = 180
	price.max_length = 7
	price.placeholder_text = "售价（灵气）"
	price.text = price_text
	price.editable = not busy
	price.text_changed.connect(func(value): price_text = value)
	form.add_child(price)
	host.action(form, "确认上架", post, true).disabled = busy
	host.action(form, "取消", func(): offer.clear(); render()).disabled = busy
	host.text(form, "售价 1–1,000,000 灵气", 15, host.MUTED_TEXT)

func build_listing(parent: Control, listing: Dictionary) -> void:
	var template := int(listing.get("template", -1))
	var rarity := int(listing.get("rarity_index", -1))
	if template < 0 or template >= Rules.TEMPLATES.size() or rarity < 0 or rarity >= Rules.RARITIES.size():
		return
	var item := {"id": str(listing.listing_id), "template": template, "rarity": rarity}
	item["school"] = int(listing.get("school", -1))
	item["upgrade_level"] = int(listing.get("upgrade_level", 0))
	var info := Rules.detail(item)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var icon := Icon.new()
	icon.setup(item)
	icon.custom_minimum_size = Vector2(52, 52)
	row.add_child(icon)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(details)
	host.text(details, "%s · %s" % [info.name, info.quality], 18, info.color)
	host.text(details, "%s · %s" % [Rules.SLOT_NAMES[info.slot], Rules.bonus_text(item)], 15, host.MUTED_TEXT)
	host.text(row, "%d 灵气" % int(listing.price), 17, host.GOLD_TEXT)
	if listing.status == "active":
		if listing.selling:
			host.action(row, "撤下挂单", mutate.bind("cancel", {"listing_id": listing.listing_id}, "挂单已撤下")).disabled = busy
		else:
			host.action(row, "购买", confirm_buy.bind(listing, info.name), true).disabled = busy
	else:
		var status: String = "已撤下" if listing.status == "cancelled" else ("已购入" if listing.purchased else "已售出")
		host.text(row, status, 16, host.MUTED_TEXT)

func choose_scope(value: String) -> void:
	scope = value
	cursors = [0]
	reload()

func choose_slot(value: String) -> void:
	slot = value
	cursors = [0]
	reload()

func previous_page() -> void:
	cursors.pop_back()
	reload()

func next_page() -> void:
	cursors.append(next_cursor)
	reload()

func reload() -> void:
	if busy:
		return
	busy = true
	render()
	await fetch()
	if is_queued_for_deletion() or not is_inside_tree():
		return
	busy = false
	render()

func fetch() -> void:
	var result := await command("list", {"scope": scope, "slot": slot, "cursor": cursors.back()})
	if is_queued_for_deletion() or not is_inside_tree():
		return
	listings = result.data.get("listings", [])
	next_cursor = int(result.data.get("next_cursor", 0))
	if not result.ok:
		message = result.message

func post() -> void:
	if not price_text.is_valid_int() or int(price_text) < 1 or int(price_text) > 1000000:
		message = "请输入 1 至 1,000,000 之间的整数价格。"
		render()
		return
	mutate("post", {"equipment_id": offer.id, "price": int(price_text)}, "装备已上架")

func confirm_buy(listing: Dictionary, item_name: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "确认购买"
	dialog.dialog_text = "花费 %d 灵气购买「%s」？" % [int(listing.price), item_name]
	dialog.ok_button_text = "确认购买"
	dialog.cancel_button_text = "取消"
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		mutate("buy", {"listing_id": listing.listing_id}, "购买成功，装备已送入行囊")
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func mutate(kind: String, fields: Dictionary, success: String) -> void:
	if busy:
		return
	busy = true
	submitting = true
	render()
	var result := await command(kind, fields)
	if is_queued_for_deletion() or not is_inside_tree():
		return
	message = success if result.ok else result.message
	if result.ok:
		if kind == "post":
			offer.clear()
			cursors = [0]
		if not await host.sync_market_character():
			message += "，钱包与行囊将在同步后更新"
	await fetch()
	if is_queued_for_deletion() or not is_inside_tree():
		return
	submitting = false
	busy = false
	render()

func command(kind: String, fields: Dictionary) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	return await core.dispatch("growth.market_" + kind, fields.merged({"cultivator_id": host.game.state.cultivator_id}))
