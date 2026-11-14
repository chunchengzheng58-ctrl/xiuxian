extends CanvasLayer

const Forms = preload("res://scripts/family_panel.gd")
var game: Node
var ui: Control
var options: Node
var body: VBoxContainer
var status: Label
var page := "声音与显示"
var was_blocked := false
var touch := false
var connection_mode: OptionButton
var endpoint: LineEdit
var checking := false
var checker: HTTPRequest

func _ready() -> void:
	layer = 110
	options = get_node("/root/GameOptions")
	options.begin_settings(self)
	was_blocked = game.player.blocked
	game.player.blocked = true
	game.player.route.clear()
	game.player.destination_site = ""
	touch = Forms.uses_touch_layout()
	var shade := ColorRect.new()
	shade.color = Color(0.04, 0.04, 0.06, 0.86)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.theme = ui.theme
	add_child(shade)
	var column: VBoxContainer = ui.card(Rect2(195, 38, 1050, 820) if touch else Rect2(295, 95, 850, 710), shade)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	label(heading, "游戏设置", 30).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button(heading, "返回游戏 ×", close, true)
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	for name in ["声音与显示", "连接与账号", "操作说明"]:
		button(tabs, name, select_page.bind(name)).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 330
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	scroll.add_child(body)
	status = label(column, "联机战斗会继续进行。" if is_instance_valid(ui.duel_view) or is_instance_valid(ui.expedition_view) else "设置仅保存在此设备。", 17)
	if not options.last_error.is_empty():
		status.text = options.last_error
	select_page(page)

func label(parent: Node, text: String, size: int = 19) -> Label:
	return ui.paragraph(parent, text, maxi(26, size) if touch else size)

func button(parent: Node, text: String, callback: Callable, primary := false) -> Button:
	var result: Button = ui.button(parent, text, callback, primary)
	if touch:
		result.custom_minimum_size.y = 84
		result.add_theme_font_size_override("font_size", 28)
	return result

func select_page(name: String) -> void:
	if checking:
		return
	page = name
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()
	match name:
		"声音与显示": build_options()
		"连接与账号": build_connection()
		_: build_help()

func build_options() -> void:
	for spec in [["master_volume", "总音量"], ["music_volume", "背景音乐"], ["effects_volume", "音效"]]:
		var row := HBoxContainer.new()
		body.add_child(row)
		label(row, spec[1]).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var value := label(row, "%d%%" % roundi(float(options.get_value(spec[0])) * 100))
		var slider := HSlider.new()
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 1
		slider.value = float(options.get_value(spec[0])) * 100
		slider.custom_minimum_size.y = 76 if touch else 32
		slider.tooltip_text = str(spec[1])
		body.add_child(slider)
		var key := str(spec[0])
		slider.value_changed.connect(func(amount):
			value.text = "%d%%" % roundi(amount)
			save_value(key, amount / 100.0))
	for spec in [["muted", "全部静音 · F10"], ["reduced_flash", "减弱受击闪光"], ["show_damage_numbers", "显示战斗伤害数字"]]:
		var check := CheckBox.new()
		check.text = spec[1]
		check.button_pressed = bool(options.get_value(spec[0]))
		check.custom_minimum_size.y = 76 if touch else 38
		check.add_theme_font_size_override("font_size", 28 if touch else 19)
		check.add_theme_color_override("font_color", Color("422e24"))
		check.add_theme_color_override("font_hover_color", Color("715035"))
		check.add_theme_color_override("font_pressed_color", Color("422e24"))
		body.add_child(check)
		var key := str(spec[0])
		check.toggled.connect(func(value): save_value(key, value))
	button(body, "切换全屏 / 窗口 · F11", options.toggle_fullscreen)
	button(body, "恢复声音与显示默认值", func():
		status.text = "已恢复默认设置。" if options.reset_defaults() else options.last_error
		select_page(page))
	label(body, "浏览器需要先点击或触摸页面才能播放声音。", 17)

func save_value(key: String, value: Variant) -> void:
	status.text = "设置已保存。" if options.update(key, value) else options.last_error

func build_connection() -> void:
	label(body, "当前服务：" + str(game.account_api.service_url), 18)
	label(body, "好友、交易和匹配需要连接同一个服务。不同服务器的账号和存档分别保存。", 18)
	if OS.has_feature("web"):
		label(body, "网页版连接当前网站的游戏服务。将同一网址分享给朋友即可进入同一个世界。", 19)
		return
	var authenticated: bool = game.account_api.is_authenticated() or game.pending_account_roster != null
	if authenticated:
		label(body, "更换服务器前请先退出账号，已保存的角色与装备仍留在原服务器。", 19)
		button(body, "退出账号，返回登录页", func():
			if game.account_api.busy or not ui.can_change_family():
				status.text = "请先完成当前操作，再退出账号。"
				return
			close()
			ui.logout_account())
		return
	connection_mode = OptionButton.new()
	connection_mode.add_item("本机试玩")
	connection_mode.add_item("共享服务器")
	connection_mode.custom_minimum_size.y = 84 if touch else 46
	connection_mode.add_theme_font_size_override("font_size", 28 if touch else 19)
	connection_mode.select(0 if str(options.get_value("server_url", "")).is_empty() else 1)
	body.add_child(connection_mode)
	endpoint = LineEdit.new()
	endpoint.placeholder_text = "https://你的游戏服务地址"
	endpoint.text = str(options.get_value("server_url", ""))
	endpoint.max_length = 250
	endpoint.custom_minimum_size.y = 84 if touch else 46
	endpoint.add_theme_font_size_override("font_size", 28 if touch else 19)
	endpoint.editable = connection_mode.selected == 1
	body.add_child(endpoint)
	connection_mode.item_selected.connect(func(index): endpoint.editable = index == 1)
	button(body, "检查并连接", connect_server, true)
	label(body, "共享服务使用 HTTPS 根地址；本机开发服务也可使用 http://127.0.0.1:端口。切换连接不会复制或覆盖其他服务器的存档。", 17)

func connect_server() -> void:
	if checking:
		return
	if game.account_api.busy or game.account_api.is_authenticated() or game.pending_account_roster != null:
		status.text = "请先退出账号并完成当前操作。"
		return
	var override := endpoint.text.strip_edges().trim_suffix("/") if connection_mode.selected == 1 else ""
	var address: String = override if not override.is_empty() else game.account_api.local_service_url
	if (connection_mode.selected == 1 and override.is_empty()) or not game.account_api.endpoint_allowed(address):
		status.text = "请输入有效的 HTTPS 根地址，或本机 HTTP 地址。"
		return
	checking = true
	connection_mode.disabled = true
	endpoint.editable = false
	status.text = "正在检查游戏服务…"
	checker = HTTPRequest.new()
	checker.timeout = 8
	add_child(checker)
	var error := checker.request(address + "/healthz")
	var ok := false
	if error == OK:
		var response: Array = await checker.request_completed
		if is_queued_for_deletion():
			return
		var data: Variant = JSON.parse_string(response[3].get_string_from_utf8())
		ok = response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200 and data is Dictionary and data.get("ok", false) and data.get("data") is Dictionary and data.data.get("service") == "xiuxian"
	checker.queue_free()
	checker = null
	checking = false
	if not ok:
		status.text = "暂时无法连接该游戏服务，请检查地址和网络。原连接已保留。"
	elif game.account_api.busy or game.account_api.is_authenticated() or game.pending_account_roster != null:
		status.text = "账号状态已变化，原连接已保留。"
	elif not options.update("server_url", override):
		status.text = options.last_error
	else:
		game.account_api.service_url = address
		if is_instance_valid(ui.account_panel):
			ui.account_panel.clear_passwords()
		status.text = "连接已保存，请返回注册或登录。"
	connection_mode.disabled = false
	endpoint.editable = connection_mode.selected == 1

func build_help() -> void:
	label(body, "移动：WASD / 方向键\n普攻：J\n听风剑诀：1\n踏云步：2 / 空格\n云罡护体：3 / K\n饕餮归元：4 / R\n设置：F9 · 静音：F10 · 全屏：F11", 21)
	label(body, "触屏：左侧摇杆移动，右侧按键施法。菜单中的列表可以上下滑动。", 19)
	label(body, "本地演武可按 P 暂停；正式秘境与论剑由服务端持续推进。设置打开时角色停止操作，战斗仍会继续。", 18)
	label(body, "主线从「五域游历」听取线索开始。章节目标完成后，返回归衡对白领取奖励；装备在聚宝阁穿戴与强化。", 18)

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ESCAPE, KEY_F9: close()
		KEY_F10:
			save_value("muted", not bool(options.get_value("muted")))
			if page == "声音与显示": select_page(page)
		KEY_F11: options.toggle_fullscreen()
		_: return
	get_viewport().set_input_as_handled()

func close() -> void:
	queue_free()

func _exit_tree() -> void:
	if is_instance_valid(checker):
		checker.cancel_request()
	if is_instance_valid(options):
		options.end_settings(self)
	if is_instance_valid(game) and is_instance_valid(game.player) and is_instance_valid(ui):
		game.player.blocked = was_blocked or ui.modal_open
