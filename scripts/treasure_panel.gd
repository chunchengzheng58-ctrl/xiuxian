extends Control
const Rules = preload("res://scripts/equipment_rules.gd")
const Icon = preload("res://scripts/equipment_icon.gd")
const Market = preload("res://scripts/equipment_market_panel.gd")
const Forge = preload("res://scripts/equipment_forge_panel.gd")
const CREAM = Color("f5e8d0")
const MUTED_TEXT = Color("b7b0a8")
const GOLD_TEXT = Color("edd096")
const SURFACE = Color("232830")
var game: Node
var ui: Control
var tab = "wish"
var selected_id = ""
var selected_slot = "all"
var busy = false
var submitting_draw := false
var submitting_wish := false
var submitting_equipment := false
var forge_panel: Control
var market_panel: Control
var reveal_tween: Tween
var result_cards: Array[Control] = []
var single_button: Button
var ten_button: Button
var wish_focus: OptionButton
var skip_button: Button
var result_grid: GridContainer
var status_label: Label
var market_offer: Dictionary = {}
var market_scope: String = "browse"
var market_balance: Label
var bag_tab: Button
var wish_projection: String = ""

class GachaRevealFX extends Control:
	var rarity: int = 0
	var state: String = "idle"
	var clock: float = 0.0
	var progress: float = 0.0
	var _tween: Tween

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		z_index = 3

	func _process(delta: float) -> void:
		if state == "idle":
			return
		clock += delta
		queue_redraw()

	func begin_reveal(delay: float = 0.0) -> void:
		if is_instance_valid(_tween) and _tween.is_running():
			_tween.kill()
		state = "queued"
		progress = 0.0
		queue_redraw()
		_tween = create_tween()
		if delay > 0.0:
			_tween.tween_interval(delay)
		_tween.tween_callback(_start_reveal)

	func _start_reveal() -> void:
		state = "revealing"
		clock = 0.0
		_tween = create_tween()
		_tween.tween_method(_set_progress, 0.0, 1.0, 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_tween.tween_callback(_finish_reveal)

	func _set_progress(value: float) -> void:
		progress = value
		queue_redraw()

	func _finish_reveal() -> void:
		progress = 1.0
		state = "revealed"
		queue_redraw()

	func complete_reveal() -> void:
		if is_instance_valid(_tween) and _tween.is_running():
			_tween.kill()
		_finish_reveal()

	func _palette() -> Array[Color]:
		if rarity >= 4:
			return [Color("ff697b"), Color("fff2b0"), Color("ff9cdb")]
		if rarity >= 3:
			return [Color("ffd36b"), Color("fff7ce"), Color("ffb548")]
		if rarity >= 2:
			return [Color("b68aff"), Color("f0dcff"), Color("7bd9ff")]
		if rarity == 1:
			return [Color("66b8ff"), Color("d8f4ff"), Color("56d6ce")]
		return [Color("e5e4df"), Color("ffffff"), Color("9fa7b2")]

	func _draw() -> void:
		if state == "idle":
			return
		var palette = _palette()
		var center = size * 0.5
		var max_radius = minf(size.x, size.y) * 0.62
		var pulse = sin(clock * 8.0) * 0.08 + 0.92
		var alpha = (0.18 + progress * 0.22) * pulse
		# A restrained glow for every result keeps common items readable.
		draw_circle(center, max_radius * (0.24 + progress * 0.24), Color(palette[0], alpha * 0.22))
		draw_arc(center, max_radius * (0.35 + progress * 0.28), -clock * 1.6, TAU - clock * 1.6, 32, Color(palette[0], alpha), 2.0)
		if rarity >= 1:
			# Blue/teal sparkles mirror the small flash used by common premium banners.
			for index in range(8):
				var angle = float(index) * TAU / 8.0 + clock * 0.9
				var distance = max_radius * (0.30 + fmod(float(index) * 0.07 + progress * 0.45, 0.44))
				var point = center + Vector2(cos(angle), sin(angle)) * distance
				var spark = 2.0 + (1.5 if rarity >= 2 else 0.0)
				draw_circle(point, spark, Color(palette[index % 3], alpha * 1.8))
		if rarity >= 2:
			# Purple and above get a short radial burst when the card turns face up.
			for index in range(12):
				var angle = float(index) * TAU / 12.0 + clock * 0.35
				var inner = max_radius * (0.18 + progress * 0.18)
				var outer = max_radius * (0.35 + progress * 0.52)
				draw_line(center + Vector2(cos(angle), sin(angle)) * inner,
					center + Vector2(cos(angle), sin(angle)) * outer,
					Color(palette[index % 3], alpha * 0.78), 2.0)
		if rarity >= 3:
			# Gold/red results use a rotating diamond and crossing ribbons.
			var diamond = max_radius * (0.22 + progress * 0.16)
			var diamond_points = PackedVector2Array([
				center + Vector2(0, -diamond), center + Vector2(diamond, 0),
				center + Vector2(0, diamond), center + Vector2(-diamond, 0)
			])
			draw_polyline(diamond_points, Color(palette[1], alpha * 1.25), 2.5)
			draw_polyline(PackedVector2Array([center + Vector2(-max_radius, max_radius * 0.42),
			center + Vector2(max_radius, -max_radius * 0.42)]), Color(palette[0], alpha * 0.45), 3.0)
			draw_polyline(PackedVector2Array([center + Vector2(-max_radius, -max_radius * 0.42),
			center + Vector2(max_radius, max_radius * 0.42)]), Color(palette[2], alpha * 0.45), 3.0)
		if rarity >= 4:
			# Mythic results finish with a white-hot ring and four-point star.
			draw_arc(center, max_radius * (0.48 + progress * 0.12), clock * 1.8, TAU + clock * 1.8, 48, Color(palette[1], alpha * 1.5), 4.0)
			var star = max_radius * (0.18 + progress * 0.10)
			draw_line(center - Vector2(star, 0), center + Vector2(star, 0), Color(palette[1], alpha * 1.6), 3.0)
			draw_line(center - Vector2(0, star), center + Vector2(0, star), Color(palette[1], alpha * 1.6), 3.0)

class WishSeal extends Control:
	var clock = 0.0
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _process(delta: float) -> void:
		clock += delta
		queue_redraw()
	func _draw() -> void:
		var center = size / 2
		draw_circle(center, 83, Color(0.9, 0.65, 0.3, 0.05))
		draw_circle(center, 62, Color(0.9, 0.65, 0.3, 0.07))
		draw_arc(center, 78, clock * 0.15, TAU + clock * 0.15, 64, Color("94764d"), 1.0)
		draw_arc(center, 65, -clock * 0.2, TAU - clock * 0.2, 48, Color("d4b779"), 1.0)
		for i in range(8):
			var angle = i * TAU / 8 + clock * 0.15
			var point = center + Vector2(cos(angle), sin(angle)) * 78
			draw_rect(Rect2(point - Vector2(3, 3), Vector2(6, 6)), Color("edce8b"))
		draw_colored_polygon(PackedVector2Array([center + Vector2(0, -40), center + Vector2(29, 0), center + Vector2(0, 40), center + Vector2(-29, 0)]), Color("9c8051"))
		draw_colored_polygon(PackedVector2Array([center + Vector2(0, -29), center + Vector2(19, 0), center + Vector2(0, 29), center + Vector2(-19, 0)]), Color("f0d79b"))

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	build()

func box(color: Color = SURFACE, border: Color = Color("514837"), width: int = 1) -> StyleBoxFlat:
	var result = StyleBoxFlat.new()
	result.bg_color = color
	result.border_color = border
	result.set_border_width_all(width)
	result.content_margin_left = 18
	result.content_margin_right = 18
	result.content_margin_top = 14
	result.content_margin_bottom = 14
	return result

func panel_at(rect: Rect2, color: Color = SURFACE, scroll_content: bool = false) -> VBoxContainer:
	var panel = PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", box(color))
	add_child(panel)
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	if scroll_content:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		panel.add_child(scroll)
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(column)
	else:
		panel.add_child(column)
	return column

func text(parent: Node, value: String, font_size: int = 18, color: Color = CREAM) -> Label:
	var label = Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func paragraph_text(parent: Node, value: String, font_size: int = 16, color: Color = MUTED_TEXT) -> Label:
	var label = text(parent, value, font_size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func action(parent: Node, value: String, callback: Callable, primary: bool = false) -> Button:
	var button = Button.new()
	button.text = value
	button.custom_minimum_size.y = 44
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var color = Color("735735") if primary else Color("303640")
		if state == "hover":
			color = color.lightened(0.12)
		if state == "pressed":
			color = color.darkened(0.12)
		if state == "disabled":
			color = Color("303036")
		button.add_theme_stylebox_override(state, box(color, Color("a38350") if primary else Color("54565d")))
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", CREAM)
	button.add_theme_color_override("font_disabled_color", Color("797b81"))
	button.add_theme_font_size_override("font_size", 17)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func build() -> void:
	wish_projection = wish_projection_signature()
	forge_panel = null
	market_panel = null
	for child in get_children():
		remove_child(child)
		child.queue_free()
	result_cards.clear()
	var shade = ColorRect.new()
	shade.color = Color(0.035, 0.04, 0.06, 0.86)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var backdrop = Panel.new()
	backdrop.position = Vector2(70, 35)
	backdrop.size = Vector2(1300, 830)
	backdrop.add_theme_stylebox_override("panel", box(Color("191d25"), Color("a18351"), 2))
	add_child(backdrop)
	var header = panel_at(Rect2(90, 52, 1260, 68), Color("191d25"))
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	header.add_child(row)
	text(row, "聚 宝 阁", 30, GOLD_TEXT)
	var subtitle = text(row, game.state.member_label() + " · " + game.state.player_name, 17, MUTED_TEXT)
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle.clip_text = true
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	action(row, "祈愿装备", func(): switch_tab("wish"), tab == "wish")
	bag_tab = action(row, "我的行囊 · %d" % game.state.equipment.inventory.size(), func(): switch_tab("bag"), tab == "bag")
	action(row, "万宝集", open_market, tab == "market")
	action(row, "锻造台", func(): switch_tab("forge"), tab == "forge")
	action(row, "返回仙村 ×", ui.close_modal)
	var left = panel_at(Rect2(90, 138, 320, 696), SURFACE, true)
	text(left, "灵气", 17, MUTED_TEXT)
	var balance = text(left, str(game.state.equipment.qi), 44, GOLD_TEXT)
	market_balance = balance
	if tab in ["market", "forge"]:
		paragraph_text(left, "用灵气向其他玩家购买装备。\n在行囊选择未穿戴的装备即可定价上架。" if tab == "market" else "分解闲置装备可以获得锻材。\n强化最高 +10，铭刻可以组成 2 件与 4 件套装。", 17)
		paragraph_text(left, "挂单期间装备无法穿戴。售出后灵气进入卖方钱包，装备进入买方行囊。" if tab == "market" else "三种流派分别偏重生存、剑诀和踏云。装备加成在下一场 PvE 战斗生效。", 16)
		action(left, "打开我的行囊", func(): switch_tab("bag"))
		if tab == "forge":
			var forge = Forge.new()
			forge.host = self
			forge.selected_id = selected_id
			forge_panel = forge
			panel_at(Rect2(428, 138, 922, 696)).add_child(forge)
			return
		var market = Market.new()
		market_panel = market
		market.host = self
		market.offer = market_offer
		market.scope = market_scope
		market_offer = {}
		panel_at(Rect2(428, 138, 922, 696)).add_child(market)
		return
	var progress = ProgressBar.new()
	progress.custom_minimum_size.y = 9
	progress.max_value = Rules.TEN_COST
	progress.value = mini(int(game.state.equipment.qi), Rules.TEN_COST)
	progress.show_percentage = false
	progress.add_theme_stylebox_override("background", box(Color("35383f")))
	progress.add_theme_stylebox_override("fill", box(Color("c6a162")))
	left.add_child(progress)
	var remaining = maxi(0, Rules.TEN_COST - int(game.state.equipment.qi))
	text(left, "新手赠送 · 免费十连" if int(game.state.equipment.get("starter_ten_pulls", 0)) > 0 else ("十连已备齐" if remaining == 0 else "距十连还差 %d 灵气" % remaining), 16, MUTED_TEXT)
	paragraph_text(left, "每日有效习惯记录 +100\n单抽 70 · 十连 700\n积攒七天，即可十连。漏记不清零。", 16)
	action(left, "查看今日习惯", ui.open_record)
	var separator = HSeparator.new()
	left.add_child(separator)
	text(left, "本角色基础概率", 18, GOLD_TEXT)
	# Keep long probability explanations inside the left column at the base viewport size.
	left.add_theme_constant_override("separation", 8)
	var locked = float(game.state.equipment.initial_score) >= 0
	if locked:
		var odds = Rules.probabilities(float(game.state.equipment.initial_score))
		for i in range(5):
			var odds_row = HBoxContainer.new()
			left.add_child(odds_row)
			var name_label = text(odds_row, "◆ " + Rules.RARITIES[i], 16, Rules.COLORS[i])
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			text(odds_row, "%.2f%%" % odds[i], 16)
		paragraph_text(left, "初始基础属性参与成长扶持。概率已固定，后续属性改善不会降低待遇。", 14)
	else:
		if market_available():
			paragraph_text(left, "首次进入秘境即可启用游戏基础规则并开启祈愿，无需体检。也可以先确认基础档案。", 16)
			action(left, "前往秘境开启修行", ui.open_expedition_lobby, true)
		else:
			paragraph_text(left, "确认基础档案后显示概率。初始基础属性越低，优质装备的基础概率越高。", 16)
		action(left, "建立基础档案", ui.open_home, true)
	paragraph_text(left, "十连至少一件史诗或以上。\n以上为保底前概率；保底只提升品质。", 14, GOLD_TEXT)
	paragraph_text(left, "新版累计祈愿最多 50 抽获得传说或以上，第 31 抽起逐步提高传说获得机会。", 14, GOLD_TEXT)
	text(left, "累计祈愿  %d 次" % game.state.equipment.draw_count, 15, MUTED_TEXT)
	if tab == "wish":
		build_wish()
	else:
		build_bag()

func switch_tab(next_tab: String) -> void:
	if is_submitting():
		ui.toast("装备操作正在保存，请稍候。")
		return
	finish_reveal()
	tab = next_tab
	build()

func is_submitting() -> bool:
	return submitting_draw or submitting_wish or submitting_equipment or (is_instance_valid(forge_panel) and forge_panel.busy) or (is_instance_valid(market_panel) and market_panel.submitting)

## 写回执可能早于另一端的交易或奖励。读取带账号版本的完整快照，
## 再从内核的单调投影取当前角色，避免迟到的回执/读请求回滚钱包。
func sync_authoritative_character(state) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	var listed: Dictionary = await core.dispatch("growth.list", {})
	if not listed.ok:
		return listed
	if not is_inside_tree() or is_queued_for_deletion():
		return {"ok": false, "code": "SESSION_CHANGED", "message": "界面已关闭"}
	var latest: Dictionary = core.snapshot("growth")
	for character in latest.get("cultivators", []):
		if str(character.get("cultivator_id", "")) == state.cultivator_id:
			state.apply_remote(character)
			return {"ok": true}
	return {"ok": false, "code": "INVALID_RESPONSE", "message": "尚未同步当前角色"}

func market_available() -> bool:
	return game.state.family_member_id == "self" and game.state.is_remote() and game.account_api.is_authenticated()

func open_market(offer: Dictionary = {}, scope: String = "browse") -> void:
	if is_submitting():
		ui.toast("装备操作正在保存，请稍候。")
		return
	market_offer = offer.duplicate()
	market_scope = scope
	switch_tab("market")

func sync_market_character() -> bool:
	var session = game.account_api
	var synced: Dictionary = await session.sync_family(game.family)
	if not synced.ok or not is_inside_tree():
		return false
	game.state = game.family.active_state()
	ui.refresh()
	return true

func refresh_market_wallet() -> void:
	if is_instance_valid(market_balance):
		market_balance.text = str(game.state.equipment.qi)
	if is_instance_valid(bag_tab):
		bag_tab.text = "我的行囊 · %d" % game.state.equipment.inventory.size()
	if tab == "wish" and not busy and not is_submitting() and wish_projection != wish_projection_signature():
		build()
	if tab == "forge" and is_instance_valid(forge_panel):
		forge_panel.refresh_projection()

func wish_projection_signature() -> String:
	var equipment: Dictionary = game.state.equipment
	return JSON.stringify([game.state.get_instance_id(), equipment.qi, equipment.initial_score, equipment.get("initial_profile_id", ""), equipment.get("legendary_pity", 0), equipment.get("wish_school", -1), equipment.draw_count, equipment.last_request, equipment.get("pending_draw", {})])

func last_receipt() -> Dictionary:
	return game.state.equipment.receipts.get(game.state.equipment.last_request, {})

func build_wish() -> void:
	var right = panel_at(Rect2(428, 138, 922, 696))
	var title = HBoxContainer.new()
	right.add_child(title)
	var title_label = text(title, "灵器祈愿", 27, GOLD_TEXT)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var focus := OptionButton.new()
	wish_focus = focus
	focus.add_item("流派随机")
	for school in Rules.GROWTH.schools:
		focus.add_item(school.name)
	focus.select(int(game.state.equipment.get("wish_school", -1)) + 1)
	focus.add_theme_font_size_override("font_size", 17)
	focus.disabled = busy or submitting_draw or not game.state.equipment.get("pending_draw", {}).is_empty()
	focus.item_selected.connect(func(index): set_wish_school(index - 1))
	title.add_child(focus)
	text(right, "累计传说保障 %d / 50 · 最多再 %d 抽获得传说或以上" % [int(game.state.equipment.get("legendary_pity", 0)), 50 - int(game.state.equipment.get("legendary_pity", 0))], 16, GOLD_TEXT)
	var receipt = last_receipt()
	if receipt.is_empty():
		var seal = WishSeal.new()
		seal.custom_minimum_size.y = 120
		right.add_child(seal)
		var introduction = text(right, "每一份坚持，都有回响", 26, GOLD_TEXT)
		introduction.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var row = HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 16)
		right.add_child(row)
		for template_id in [0, 1, 3, 4]:
			var showcase = {"id": "showcase", "template": template_id, "rarity": 4}
			var info = Rules.detail(showcase)
			var column = VBoxContainer.new()
			column.custom_minimum_size.x = 178
			row.add_child(column)
			var icon = Icon.new()
			icon.setup(showcase)
			icon.custom_minimum_size = Vector2(150, 112)
			column.add_child(icon)
			var label = text(column, info.name, 18, info.color)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			var kind = text(column, "神话 · " + Rules.SLOT_NAMES[info.slot], 14, MUTED_TEXT)
			kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var preview_note = text(right, "神话灵器外观预览 · 实际获得品质以祈愿结果为准", 14, MUTED_TEXT)
		preview_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var guidance = paragraph_text(right, "装备收入行囊后可查看与穿戴。加成独立于健康基础属性，下一场战斗生效。", 17)
		guidance.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		text(right, "最近一次祈愿 · %d 抽 · 消耗 %d 灵气" % [receipt.count, receipt.cost], 17, MUTED_TEXT)
		result_grid = GridContainer.new()
		result_grid.columns = 5
		result_grid.add_theme_constant_override("h_separation", 10)
		result_grid.add_theme_constant_override("v_separation", 10)
		right.add_child(result_grid)
		for item in receipt.items:
			result_cards.append(item_card(result_grid, item, Vector2(165, 196)))
		if receipt.guaranteed:
			text(right, "十连保底已生效 · 至少一件史诗", 16, Rules.COLORS[2])
	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(spacer)
	status_label = paragraph_text(right, "十连至少一件史诗或以上 · 所有结果均已存入行囊", 16)
	var actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	right.add_child(actions)
	single_button = action(actions, "祈愿一次 · 70", func(): summon(1))
	ten_button = action(actions, "新手赠送 · 免费十连" if int(game.state.equipment.get("starter_ten_pulls", 0)) > 0 else "十连祈愿 · 700", func(): summon(10), true)
	single_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ten_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skip_button = action(actions, "跳过动画", finish_reveal)
	skip_button.visible = busy
	refresh_wish_controls()
	var pending: Dictionary = game.state.equipment.get("pending_draw", {})
	if not pending.is_empty():
		status_label.text = "上次祈愿尚待确认，请继续原次数。已结算的结果不会再次扣费。"

func refresh_wish_controls() -> void:
	var pending: Dictionary = game.state.equipment.get("pending_draw", {})
	var count := int(pending.get("count", 0))
	var blocked: bool = busy or is_submitting()
	var single_ready: bool = count == 1 if count > 0 else int(game.state.equipment.qi) >= Rules.SINGLE_COST and float(game.state.equipment.initial_score) >= 0
	var ten_ready: bool = count == 10 if count > 0 else (int(game.state.equipment.get("starter_ten_pulls", 0)) > 0 or int(game.state.equipment.qi) >= Rules.TEN_COST) and float(game.state.equipment.initial_score) >= 0
	if is_instance_valid(wish_focus):
		wish_focus.disabled = blocked or count > 0
	if is_instance_valid(single_button):
		single_button.text = "继续上次单抽" if count == 1 else "祈愿一次 · 70"
		single_button.disabled = blocked or not single_ready
	if is_instance_valid(ten_button):
		ten_button.text = "继续上次十连" if count == 10 else ("新手赠送 · 免费十连" if int(game.state.equipment.get("starter_ten_pulls", 0)) > 0 else "十连祈愿 · 700")
		ten_button.disabled = blocked or not ten_ready

func set_wish_school(school: int) -> void:
	if is_submitting() or busy:
		return
	if not game.state.equipment.get("pending_draw", {}).is_empty():
		ui.toast("请先确认上次祈愿结果，再更换流派。")
		return
	busy = true
	submitting_wish = true
	if game.state.is_remote():
		var core := get_tree().root.get_node("GameKernel")
		var result: Dictionary = await core.dispatch("growth.set_wish", {"cultivator_id": game.state.cultivator_id, "school": school})
		if not result.ok:
			busy = false
			submitting_wish = false
			ui.toast(result.message)
			build()
			return
		var synced := await sync_authoritative_character(game.state)
		if not synced.ok:
			busy = false
			submitting_wish = false
			ui.toast("铭刻流派已保存，刷新后确认最新行囊。")
			if is_inside_tree():
				build()
			return
	else:
		game.state.equipment.wish_school = school
	game.state.save_game()
	busy = false
	submitting_wish = false
	if is_inside_tree():
		build()

func item_card(parent: Node, item: Dictionary, dimensions: Vector2) -> Button:
	var info = Rules.detail(item)
	var card = Button.new()
	card.custom_minimum_size = dimensions
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = "%s · %s\n%s\n点击查看与穿戴" % [info.quality, info.name, Rules.bonus_text(item)]
	var background = box(Color("262a35").lerp(info.color.darkened(0.7), 0.25), info.color, 2)
	background.shadow_color = Color(info.color, 0.12)
	background.shadow_size = 5
	card.add_theme_stylebox_override("normal", background)
	card.add_theme_stylebox_override("hover", box(info.color.darkened(0.72), info.color, 3))
	card.add_theme_stylebox_override("pressed", box(info.color.darkened(0.8), info.color, 3))
	card.add_theme_stylebox_override("focus", box(Color.TRANSPARENT, info.color, 2))
	parent.add_child(card)
	var column = VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 10
	column.offset_right = -10
	column.offset_top = 12
	column.offset_bottom = -10
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 3)
	card.add_child(column)
	var quality = text(column, info.quality, 15, info.color)
	quality.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var icon = Icon.new()
	icon.setup(item)
	icon.custom_minimum_size.y = 68
	column.add_child(icon)
	var name_label = text(column, info.name, 17)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var bonus = text(column, Rules.bonus_text(item), 15, GOLD_TEXT)
	bonus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var equipped = game.state.equipment.equipped.get(info.slot, "") == info.id
	var footnote: String = "已穿戴" if equipped else Rules.SLOT_NAMES[info.slot]
	if item.has("market_listing_id"):
		footnote = "在售"
	var foot = text(column, footnote, 13, Color("9cceb4") if equipped else MUTED_TEXT)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for child in column.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var reveal_fx = GachaRevealFX.new()
	reveal_fx.name = "GachaRevealFX"
	reveal_fx.rarity = info.rarity
	card.add_child(reveal_fx)
	card.pressed.connect(func():
		if is_submitting():
			return
		finish_reveal()
		selected_id = info.id
		tab = "bag"
		build()
	)
	return card

func summon(count: int) -> void:
	if busy or is_submitting():
		return
	busy = true
	submitting_draw = true
	# A receipt is committed before presentation. Reopening always shows that same result.
	var pending: Dictionary = game.state.equipment.get("pending_draw", {})
	if not pending.is_empty() and int(pending.count) != count:
		busy = false
		submitting_draw = false
		return
	var request_id: String = str(pending.get("request_id", "wish_" + Crypto.new().generate_random_bytes(16).hex_encode()))
	game.state.equipment["pending_draw"] = {"count": count, "request_id": request_id}
	refresh_wish_controls()
	if not game.state.save_game():
		busy = false
		submitting_draw = false
		refresh_wish_controls()
		ui.toast("保存祈愿请求失败，请稍后重试。")
		return
	var receipt = await remote_draw(count, request_id) if game.state.is_remote() else game.state.draw_equipment(count, request_id)
	submitting_draw = false
	if receipt.ok or receipt.get("code", "") not in ["NETWORK_ERROR", "INTERNAL_ERROR", "INVALID_RESPONSE", "HTTP_ERROR", "BACKEND_UNAVAILABLE"]:
		game.state.equipment.erase("pending_draw")
		game.state.save_game()
	if not receipt.ok:
		busy = false
		refresh_wish_controls()
		refresh_market_wallet()
		if is_instance_valid(status_label):
			status_label.text = receipt.message
		ui.toast(receipt.message)
		return
	ui.refresh()
	if tab != "wish":
		busy = false
		build()
		return
	build()
	for card in result_cards:
		card.modulate.a = 0
	reveal_tween = create_tween().set_parallel(true)
	for i in range(result_cards.size()):
		reveal_tween.tween_property(result_cards[i], "modulate:a", 1.0, 0.3).set_delay(i * 0.08)
		var reveal_fx = result_cards[i].get_node_or_null("GachaRevealFX") as GachaRevealFX
		if reveal_fx != null:
			reveal_fx.begin_reveal(i * 0.08)
	reveal_tween.chain().tween_callback(finish_reveal)

## 由 C 扣费并生成装备；成功后刷新本角色读模型，并按原卡片样式展示同一回执。
func remote_draw(count: int, request_id: String) -> Dictionary:
	var state = game.state
	var core = get_tree().root.get_node("GameKernel")
	var result = await core.dispatch("growth.draw", {"cultivator_id": state.cultivator_id, "count": count, "request_id": request_id})
	if not result.ok:
		return {"ok": false, "code": result.code, "message": str(result.message)}
	var latest := await sync_authoritative_character(state)
	if not latest.ok:
		return {"ok": false, "code": latest.get("code", "BACKEND_UNAVAILABLE"), "message": "祈愿结果已保存，点击原次数找回结果并同步行囊。"}
	var items = []
	for item in result.data.items:
		items.append({"id": str(item.equipment_id), "template": int(item.template), "rarity": int(item.rarity_index), "school": int(item.get("school", -1)), "upgrade_level": int(item.get("upgrade_level", 0))})
	var receipt = {"ok": true, "request_id": request_id, "count": count, "cost": int(result.data.cost), "items": items, "guaranteed": result.data.guaranteed == true}
	state.equipment.receipts[request_id] = receipt
	state.equipment.last_request = request_id
	state.save_game()
	return receipt

func remote_wear(info: Dictionary, equipped: bool) -> Dictionary:
	if is_submitting():
		return {"ok": false, "message": "装备操作正在保存，请稍候。"}
	submitting_equipment = true
	var state = game.state
	var core = get_tree().root.get_node("GameKernel")
	var result: Dictionary
	if equipped:
		result = await core.dispatch("growth.unequip", {"cultivator_id": state.cultivator_id, "slot": info.slot, "request_id": "off-%s-%d" % [info.id, Time.get_ticks_usec()]})
	else:
		result = await core.dispatch("growth.equip", {"cultivator_id": state.cultivator_id, "equipment_id": info.id, "slot": info.slot})
	if not result.ok:
		submitting_equipment = false
		return {"ok": false, "message": str(result.message)}
	var latest := await sync_authoritative_character(state)
	submitting_equipment = false
	if not latest.ok:
		return {"ok": false, "message": "装备操作已保存，刷新后确认最新行囊。"}
	state.save_game()
	return {"ok": true, "message": ("已卸下装备" if equipped else "已穿戴「%s」" % info.name) + "，下一场战斗生效。"}

func finish_reveal() -> void:
	if is_instance_valid(reveal_tween) and reveal_tween.is_running():
		reveal_tween.kill()
	busy = is_submitting()
	for card in result_cards:
		if is_instance_valid(card):
			card.modulate.a = 1
			var reveal_fx = card.get_node_or_null("GachaRevealFX") as GachaRevealFX
			if reveal_fx != null:
				reveal_fx.complete_reveal()
	if is_instance_valid(skip_button):
		skip_button.hide()
	refresh_wish_controls()
	refresh_market_wallet()

func build_bag() -> void:
	var right = panel_at(Rect2(428, 138, 922, 696))
	text(right, "我的行囊", 27, GOLD_TEXT)
	var slots = HBoxContainer.new()
	slots.add_theme_constant_override("separation", 8)
	right.add_child(slots)
	for slot in Rules.SLOTS:
		var name_text = "未穿戴"
		var color = MUTED_TEXT
		for item in game.state.equipment.inventory:
			var info = Rules.detail(item)
			if game.state.equipment.equipped.get(slot, "") == info.id:
				name_text = info.name
				color = info.color
		var current_slot = slot
		var slot_button = action(slots, Rules.SLOT_NAMES[slot] + "\n" + name_text, func(): select_equipped(current_slot))
		slot_button.custom_minimum_size.y = 65
		slot_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot_button.add_theme_stylebox_override("normal", box(Color("2b2e36"), color, 2))
	var totals = Rules.bonuses(game.state.equipment)
	text(right, "总加成  生命 +%d  攻击 +%d  防御 +%d  灵力 +%d  体力 +%d" % [totals.life, totals.attack, totals.defense, totals.spirit, totals.stamina], 16, GOLD_TEXT)
	var filter_row = HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 8)
	right.add_child(filter_row)
	for slot in ["all"] + Rules.SLOTS:
		var current = slot
		action(filter_row, "全部" if slot == "all" else Rules.SLOT_NAMES[slot], func(): selected_slot = current; build(), selected_slot == slot)
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size.y = 258
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var grid = GridContainer.new()
	grid.columns = 5
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(grid)
	var items = game.state.equipment.inventory.duplicate()
	items.reverse()
	items.sort_custom(func(a, b): return int(a.rarity) > int(b.rarity))
	for item in items:
		if selected_slot == "all" or Rules.detail(item).slot == selected_slot:
			item_card(grid, item, Vector2(160, 190))
	if grid.get_child_count() == 0:
		paragraph_text(grid, "这里还没有装备。\n完成每日习惯、积攒灵气后，前往祈愿。", 18)
	build_detail(right)

func select_equipped(slot: String) -> void:
	if is_submitting():
		return
	selected_slot = slot
	selected_id = str(game.state.equipment.equipped.get(slot, ""))
	build()

func build_detail(parent: Node) -> void:
	var selected = {}
	for item in game.state.equipment.inventory:
		if item.id == selected_id:
			selected = item
	if selected.is_empty():
		paragraph_text(parent, "点击装备查看详情与穿戴。相同装备会分别保留，每个槽位只能穿戴一件。", 16)
		return
	var info = Rules.detail(selected)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	var preview = Icon.new()
	preview.name = "EquipmentDetailPreview"
	preview.setup(selected)
	preview.custom_minimum_size = Vector2(112, 112)
	row.add_child(preview)
	var description = VBoxContainer.new()
	description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(description)
	text(description, "%s · %s" % [info.name, info.quality], 21, info.color)
	text(description, Rules.bonus_text(selected) + " · " + Rules.SLOT_NAMES[info.slot], 17)
	var currently = {}
	for item in game.state.equipment.inventory:
		if game.state.equipment.equipped.get(info.slot, "") == item.id:
			currently = item
	var comparison = "此槽位尚未穿戴"
	if not currently.is_empty():
		var other = Rules.detail(currently)
		comparison = "当前：%s（%s）" % [other.name, Rules.bonus_text(currently)]
	text(description, comparison, 15, MUTED_TEXT)
	var equipped = game.state.equipment.equipped.get(info.slot, "") == info.id
	if selected.has("market_listing_id"):
		action(row, "查看挂单", func(): open_market({}, "mine"))
		return
	var actions := VBoxContainer.new()
	row.add_child(actions)
	action(actions, "卸下装备" if equipped else "穿戴装备", func():
		if is_submitting():
			return
		for button in actions.get_children():
			if button is Button:
				button.disabled = true
		var result = await remote_wear(info, equipped) if game.state.is_remote() else (game.state.unequip_item(info.slot) if equipped else game.state.equip_item(info.id))
		if not is_inside_tree() or is_queued_for_deletion():
			return
		ui.toast(result.message)
		ui.refresh()
		build()
	, true)
	if not equipped and market_available():
		action(actions, "定价上架", func(): open_market(selected, "mine"))
	if game.state.is_remote():
		action(actions, "前往锻造", func(): switch_tab("forge"))
