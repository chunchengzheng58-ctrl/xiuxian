extends VBoxContainer

var game: Node
var ui: Control
var cultivator_id: String
var home: Dictionary = {}
var view: String = "friends"
var status: Label
var tab_buttons: Dictionary = {}
var requests_tab: Button
var body: VBoxContainer
var scroll: ScrollContainer
var rows: VBoxContainer
var invite_form: HBoxContainer
var alias_input: LineEdit
var code_row: HBoxContainer
var code_field: LineEdit
var save_profile_button: Button
var chat_title: Label
var composer: LineEdit
var earlier_button: Button
var latest_button: Button
var relation_id: String = ""
var before: int = 0
var next_before: int = 0
var messages: Array = []
var refreshing: bool = false
var mutating: bool = false
var refresh_again: bool = false
var view_epoch: int = 0
var community_request_keys: Dictionary = {}

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	var tabs := HBoxContainer.new()
	add_child(tabs)
	for item in [["friends", "好友"], ["requests", "好友申请"], ["profile", "我的名片"], ["blocked", "屏蔽列表"], ["communities", "社群"], ["world", "世界频道"]]:
		var tab: Button = ui.button(tabs, item[1], show_view.bind(item[0]))
		tab.toggle_mode = true
		tab.add_theme_color_override("font_pressed_color", Color("fff0cb"))
		tab_buttons[item[0]] = tab
	requests_tab = tab_buttons["requests"]
	ui.button(tabs, "刷新", refresh_current)
	body = VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	add_child(body)
	status = ui.paragraph(self, "正在读取同道录…", 16)
	show_view("friends")
	game.account_api.realtime.snapshot_received.connect(on_snapshot)
	refresh()

func show_view(next: String, selected: String = "") -> void:
	view = next
	relation_id = selected
	before = 0
	next_before = 0
	messages = []
	view_epoch += 1
	for key in tab_buttons:
		tab_buttons[key].set_pressed_no_signal(key == view or (key == "friends" and view == "chat"))
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()
	if view == "profile":
		build_profile()
		return
	if view in ["friends", "requests"]:
		build_invite()
	if view == "chat":
		build_chat_header()
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 212
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	body.add_child(scroll)
	rows = VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 7)
	scroll.add_child(rows)
	if view == "world":
		render_world()
		return
	if view == "communities":
		render_communities()
		return
	if view == "chat":
		var row := HBoxContainer.new()
		body.add_child(row)
		composer = line_edit(row, "给好友写一条消息", 240)
		composer.text_submitted.connect(func(_value): send_message())
		ui.button(row, "发送私信", send_message, true)
		refresh()
	else:
		render_home()

func render_world() -> void:
	var epoch := view_epoch
	clear_rows()
	status.text = "正在读取世界频道…"
	var result: Dictionary = await game.account_api.api.request_api("/api/v2/social/world?limit=30")
	if epoch != view_epoch or not is_instance_valid(rows):
		return
	if not result.ok:
		status.text = str(result.message)
		return
	status.text = ""
	clear_rows()
	var message := line_edit(rows, "写一条世界频道消息", 500)
	ui.button(rows, "发送", func(): community_write("/api/v2/social/world/messages", {"body": message.text.strip_edges()}))
	for item in result.data.messages:
		ui.paragraph(rows, "%s：%s" % [item.author.username, item.body], 18)

func refresh_current() -> void:
	match view:
		"world": render_world()
		"communities": render_communities()
		_: refresh()

func render_communities() -> void:
	var epoch := view_epoch
	clear_rows()
	status.text = "正在读取社群…"
	var result: Dictionary = await game.account_api.api.request_api("/api/v2/social/communities")
	if epoch != view_epoch or not is_instance_valid(rows):
		return
	if not result.ok:
		status.text = str(result.message)
		return
	status.text = ""
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	var name_input := line_edit(rows, "社群名称", 48)
	ui.button(rows, "创建公开社群", func(): community_write("/api/v2/social/communities", {"name": name_input.text.strip_edges(), "visibility": "public", "max_members": 50}))
	for community in result.data.communities:
		var path := "/api/v2/social/communities/" + str(community.community_id).uri_encode()
		ui.paragraph(rows, str(community.name), 20)
		ui.button(rows, "查看动态", community_feed.bind(path))
		if community.get("joined", false):
			ui.button(rows, "退出社群", community_write.bind(path + "/leave", {}))
		else:
			ui.button(rows, "加入社群", community_write.bind(path + "/join", {}))

func community_feed(path: String) -> void:
	var epoch := view_epoch
	var result: Dictionary = await game.account_api.api.request_api(path)
	if epoch != view_epoch or not is_instance_valid(rows):
		return
	if not result.ok:
		status.text = str(result.message)
		return
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	ui.button(rows, "返回社群列表", render_communities)
	if result.data.community.get("joined", false):
		var entry := line_edit(rows, "写一条社群动态", 1000)
		ui.button(rows, "发布动态", func(): community_write(path + "/posts", {"body": entry.text.strip_edges()}, path))
	for post in result.data.posts:
		ui.paragraph(rows, "%s：%s" % [post.author.username, post.body], 18)
		for comment in post.comments:
			ui.paragraph(rows, str(comment.body), 16)
		if result.data.community.get("joined", false):
			var post_path := path + "/posts/" + str(post.post_id).uri_encode()
			var comment_input := line_edit(rows, "写评论", 500)
			ui.button(rows, "发送评论", func(): community_write(post_path + "/comments", {"body": comment_input.text.strip_edges()}, path))
			ui.button(rows, "点赞", community_write.bind(post_path + "/reactions", {"kind": "like"}, path))

func community_write(path: String, payload: Dictionary, feed_path: String = "") -> void:
	if mutating:
		return
	mutating = true
	var epoch := view_epoch
	var data := payload.duplicate()
	var signature := path + JSON.stringify(payload, "", true).sha256_text()
	if not community_request_keys.has(signature):
		community_request_keys[signature] = Crypto.new().generate_random_bytes(16).hex_encode()
	data.request_id = community_request_keys[signature]
	var result: Dictionary = await game.account_api.api.request_api(path, HTTPClient.METHOD_POST, data)
	mutating = false
	if result.code not in ["NETWORK_ERROR", "INTERNAL_ERROR", "BACKEND_UNAVAILABLE", "INVALID_RESPONSE", "HTTP_ERROR"]:
		community_request_keys.erase(signature)
	if epoch != view_epoch:
		return
	if not result.ok:
		status.text = str(result.message)
	elif feed_path.is_empty():
		refresh_current()
	else:
		community_feed(feed_path)

func line_edit(parent: Control, hint: String, maximum: int) -> LineEdit:
	var entry := LineEdit.new()
	entry.placeholder_text = hint
	entry.max_length = maximum
	entry.custom_minimum_size.y = 42
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry.add_theme_font_size_override("font_size", 20)
	parent.add_child(entry)
	preload("res://scripts/mobile_ui.gd").configure_text_input(entry)
	return entry

func build_profile() -> void:
	ui.paragraph(body, "好友只会看到这里设置的昵称。邀请码可由你分享，需要时可换新。", 19)
	var row := HBoxContainer.new()
	body.add_child(row)
	alias_input = line_edit(row, "社交昵称 · 1–12 个字符", 12)
	alias_input.text = str((home.profile as Dictionary).alias) if home.get("profile") is Dictionary else ""
	save_profile_button = ui.button(row, "创建名片", save_profile.bind(false), true)
	code_row = HBoxContainer.new()
	body.add_child(code_row)
	ui.label_into(code_row, "我的邀请码", 18)
	code_field = line_edit(code_row, "", 0)
	code_field.editable = false
	ui.button(code_row, "复制邀请码", copy_code)
	ui.button(code_row, "换邀请码", save_profile.bind(true))
	render_profile()

func render_profile() -> void:
	var profile = home.get("profile")
	code_row.visible = profile is Dictionary
	save_profile_button.text = "保存昵称" if code_row.visible else "创建名片"
	if code_row.visible:
		var code: String = profile.invite_code
		code_field.text = "-".join([code.substr(0, 4), code.substr(4, 4), code.substr(8, 4), code.substr(12, 4)])

func copy_code() -> void:
	DisplayServer.clipboard_set(code_field.text)
	code_field.grab_focus()
	code_field.select_all()
	status.text = "邀请码已选中，可复制后分享。"

func save_profile(rotate: bool) -> void:
	var alias := alias_input.text.strip_edges()
	if alias.is_empty():
		status.text = "请先输入社交昵称。"
		return
	await mutate("profile", {"alias": alias, "rotate_code": rotate}, "邀请码已换新" if rotate else "名片已保存")

func build_invite() -> void:
	invite_form = HBoxContainer.new()
	body.add_child(invite_form)
	var code := line_edit(invite_form, "粘贴对方的邀请码", 24)
	var send_invite := func():
		if code.text.strip_edges().is_empty():
			status.text = "请输入好友的邀请码。"
			return
		if await mutate("invite", {"invite_code": code.text}, "好友申请已送出") and is_instance_valid(code):
			code.clear()
	code.text_submitted.connect(func(_value): send_invite.call())
	ui.button(invite_form, "添加好友", send_invite, true)

func build_chat_header() -> void:
	var header := HBoxContainer.new()
	body.add_child(header)
	ui.button(header, "返回好友", show_view.bind("friends"))
	chat_title = ui.label_into(header, "私信", 20)
	chat_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	earlier_button = ui.button(header, "更早消息", page_chat.bind(true))
	earlier_button.disabled = true
	latest_button = ui.button(header, "最新消息", page_chat.bind(false))
	latest_button.disabled = true

func render_home() -> void:
	requests_tab.text = "好友申请 · %d" % home.get("requests", []).filter(func(row): return row.incoming).size()
	if view == "profile":
		render_profile()
		return
	if view in ["friends", "requests"]:
		invite_form.visible = home.get("profile") is Dictionary
	if view in ["chat", "communities", "world"]:
		return
	clear_rows()
	if home.is_empty():
		return
	var entries: Array = home.get(view, [])
	if entries.is_empty():
		var empty: String = {"friends": "暂无好友。交换邀请码就能发送申请。", "requests": "暂无待处理的好友申请。", "blocked": "屏蔽列表为空。"}[view]
		ui.paragraph(rows, empty, 19)
	for item in entries:
		var row := HBoxContainer.new()
		rows.add_child(row)
		var alias_label := ui.label_into(row, item.alias, 19) as Label
		alias_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		match view:
			"friends":
				var caption := "私聊 · %d 未读" % int(item.unread) if item.unread > 0 else "私聊"
				ui.button(row, caption, show_view.bind("chat", item.relation_id), true)
				ui.button(row, "约战", ui.open_duel_lobby.bind(item.relation_id))
				ui.button(row, "移除", confirm_relation.bind(item, "remove"))
				ui.button(row, "屏蔽", confirm_relation.bind(item, "block"))
			"requests":
				ui.label_into(row, "收到申请" if item.incoming else "等待对方同意", 16)
				if item.incoming:
					ui.button(row, "接受", respond.bind(item.relation_id, "accept"), true)
					ui.button(row, "拒绝", respond.bind(item.relation_id, "decline"))
					ui.button(row, "屏蔽", confirm_relation.bind(item, "block"))
				else:
					ui.button(row, "撤回", respond.bind(item.relation_id, "cancel"))
			"blocked":
				ui.button(row, "解除屏蔽", mutate.bind("unblock", {"peer_id": item.peer_id}, "已解除屏蔽"))

func clear_rows() -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()

func confirm_relation(item: Dictionary, action: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "屏蔽同道" if action == "block" else "移除好友"
	dialog.dialog_text = "%s「%s」会结束这段关系，并清除双方在同道录内的私信。确认操作？" % ["屏蔽" if action == "block" else "移除", item.alias]
	dialog.ok_button_text = "确认"
	dialog.cancel_button_text = "返回"
	add_child(dialog)
	dialog.confirmed.connect(func(): dialog.queue_free(); respond(item.relation_id, action))
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func respond(id: String, action: String) -> void:
	var note: String = {"accept": "已成为好友", "decline": "已拒绝申请", "cancel": "申请已撤回", "remove": "好友已移除", "block": "已屏蔽同道"}[action]
	await mutate("respond", {"relation_id": id, "action": action}, note)

func send_message() -> void:
	var entry := composer
	var original := entry.text
	if original.strip_edges().is_empty():
		return
	if await mutate("send", {"relation_id": relation_id, "body": original}, "") and is_instance_valid(entry) and entry.text == original:
		entry.clear()

func page_chat(older: bool) -> void:
	if older and next_before == 0:
		return
	before = next_before if older else 0
	view_epoch += 1
	refresh()

func refresh_chat() -> void:
	var matches: Array = home.friends.filter(func(row): return row.relation_id == relation_id)
	if matches.is_empty():
		show_view("friends")
		status.text = "这段好友关系已结束。"
		return
	var peer: Dictionary = matches[0]
	chat_title.text = "与「%s」私聊" % peer.alias
	var epoch := view_epoch
	var result := await command("chat", {"relation_id": relation_id, "before": before})
	if epoch != view_epoch or is_queued_for_deletion():
		return
	if not result.ok:
		clear_rows()
		messages = []
		status.text = result.message
		return
	var incoming: Array = result.data.messages
	next_before = int(result.data.next_before)
	earlier_button.disabled = next_before == 0
	latest_button.disabled = before == 0
	if incoming != messages or rows.get_child_count() == 0:
		messages = incoming
		clear_rows()
		if messages.is_empty():
			ui.paragraph(rows, "还没有私信。发一句问候吧。", 18)
		for entry in messages:
			add_message(entry, peer.alias)
		if before == 0:
			scroll.set_deferred("scroll_vertical", int(scroll.get_v_scroll_bar().max_value))
	if before == 0 and peer.unread > 0 and not messages.is_empty():
		await command("read", {"relation_id": relation_id, "through": int(messages.back().sequence)})

func add_message(entry: Dictionary, peer_alias: String) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END if entry.mine else BoxContainer.ALIGNMENT_BEGIN
	rows.add_child(row)
	var card := PanelContainer.new()
	card.custom_minimum_size.x = 500
	var style: StyleBoxFlat = ui.style(Color("e8d3a7") if entry.mine else Color("f5e8ca"))
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	card.add_theme_stylebox_override("panel", style)
	row.add_child(card)
	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 2)
	card.add_child(text)
	var seconds := int(entry.sent_at) + int(Time.get_time_zone_from_system().bias) * 60
	var sent := Time.get_time_string_from_unix_time(seconds).left(5)
	ui.label_into(text, "%s  ·  %s" % ["我" if entry.mine else peer_alias, sent], 14, Color("8b6e47"))
	ui.paragraph(text, entry.body, 18, Color("372821"))

func on_snapshot(_snapshot: Dictionary) -> void:
	refresh()

func refresh() -> void:
	if is_queued_for_deletion():
		return
	if refreshing or mutating:
		refresh_again = true
		return
	refresh_again = false
	refreshing = true
	var result := await command("home")
	if is_queued_for_deletion():
		return
	if result.ok:
		home = result.data
		if status.text == "正在读取同道录…":
			status.text = ""
		if home.profile == null and view != "profile":
			show_view("profile")
		render_home()
		if view == "chat":
			await refresh_chat()
	else:
		status.text = result.message
	refreshing = false
	if refresh_again:
		refresh.call_deferred()

func mutate(kind: String, payload: Dictionary, note: String) -> bool:
	if mutating or is_queued_for_deletion():
		return false
	mutating = true
	status.text = "正在提交…"
	var result := await command(kind, payload)
	if is_queued_for_deletion():
		return false
	mutating = false
	status.text = note if result.ok else result.message
	refresh()
	return result.ok

func command(kind: String, payload: Dictionary = {}) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	return await core.dispatch("social." + kind, payload.merged({"cultivator_id": cultivator_id}))
