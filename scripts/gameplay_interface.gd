extends "res://scripts/pixel_interface.gd"

const PtdsSummary = preload("res://scripts/ptds_summary.gd")

const Assets = preload("res://scripts/pixel_assets.gd")
const TrialCatalogue = preload("res://scripts/trial_catalogue.gd")
const Combat = preload("res://scripts/combat_view.gd")
const SocialPanel = preload("res://scripts/social_panel.gd")
const DuelLobby = preload("res://scripts/duel_lobby.gd")
const DuelView = preload("res://scripts/duel_view.gd")
const MatchmakingLobby = preload("res://scripts/matchmaking_lobby.gd")
const ExpeditionLobby = preload("res://scripts/expedition_lobby.gd")
const ExpeditionView = preload("res://scripts/expedition_view.gd")
const StoryPanel = preload("res://scripts/story_panel.gd")
const SettingsPanel = preload("res://scripts/settings_panel.gd")
var start_screen: ColorRect
var selected_avatar: String = "male"
var avatar_buttons: Array[Button] = []
var nickname_input: LineEdit
var combat: Control
var corridor: Control
var corridor_position = Vector2(180, 715)
var corridor_camera: float = 0
var menu_hidden_controls: Array[Control] = []
var profile_file_dialog: FileDialog
var health_entry: Control
var treasure: Control
var family_panel: Control
var account_panel: Control
var return_to_health_entry = false
var companion_panel: Control
var companion_button: Button
var social_button: Button
var duel_button: Button
var duel_view: Control
var expedition_view: Control
var story_panel: Control
var settings_panel: CanvasLayer
var wechat_task_label: Label
var lifecycle_panel: Control
var lifecycle_gateway: Node
var guest_elder_id := ""
var guest_bound := false
var guest_task_done := false

func _ready() -> void:
	super._ready()
	get_node("/root/GameOptions").settings_requested.connect(open_settings)
	var settings_button := button(self, "设置 · F9", open_settings)
	settings_button.position = Vector2(994, 23)
	settings_button.size = Vector2(151, 46)
	game.account_api.completed.connect(on_account_result)
	game.account_api.progress.connect(on_account_progress)
	var menu_button = button(self, "我的家人 / 切换角色", open_family)
	menu_button.position = Vector2(16, 324)
	menu_button.size.x = 276
	var profile_button = button(self, "健康档案 / 五项属性", open_home, true)
	profile_button.position = Vector2(16, 382)
	profile_button.size.x = 276
	companion_button = button(self, "选择你的灵宠  →", open_companion)
	companion_button.position = Vector2(16, 440)
	companion_button.size = Vector2(276, 59)
	companion_button.expand_icon = true
	companion_button.add_theme_constant_override("icon_max_width", 39)
	refresh_companion_button()
	var lifecycle_button = button(self, "渡劫台 / 修行状态", open_recovery)
	lifecycle_button.position = Vector2(16, 506)
	lifecycle_button.size.x = 276
	social_button = button(self, "同道录 / 好友", open_social)
	social_button.position = Vector2(16, 572)
	social_button.size.x = 276
	duel_button = button(self, "论剑台 / 对战", open_arena)
	duel_button.position = Vector2(16, 638)
	duel_button.size.x = 276
	var expedition_button = button(self, "五域游历 / 主线", open_story)
	expedition_button.position = Vector2(16, 704)
	expedition_button.size.x = 276
	var guide_button = button(self, "新手指引 / 下一步  →", open_beginner_guide)
	guide_button.position = Vector2(16, 770)
	guide_button.size.x = 276
	var args = OS.get_cmdline_user_args()
	if "--skip-intro" not in args and "--preview" not in args:
		open_game_entry.call_deferred()

func refresh() -> void:
	super.refresh()
	refresh_companion_button()
	if is_instance_valid(social_button):
		var summary: Dictionary = game.account_api.social_summary
		var notices := int(summary.get("pending_requests", 0)) + int(summary.get("unread_messages", 0))
		social_button.text = "同道录 / 好友" + (" · %d" % notices if notices > 0 else "")
	if is_instance_valid(duel_button):
		var summary: Dictionary = game.account_api.duel_summary
		var notice: String = " · 待入场" if summary.get("active", false) else (" · 匹配中" if summary.get("queued", false) else (" · 新约战" if int(summary.get("invitations", 0)) > 0 else ""))
		duel_button.text = "论剑台 / 对战" + notice
	if is_instance_valid(treasure):
		treasure.refresh_market_wallet()
	if is_instance_valid(hud_avatar_image):
		hud_avatar_image.texture = game.portrait
		hud_name_label.text = game.state.player_name
		game.player_name_label.text = game.state.player_name
	var medication = "已确认" if game.state.task_done("medication") else "待记录"
	if not game.state.longterm_enabled or not game.state.medication_required:
		medication = "无用药计划"
	var recovery = {"not_started": "未开启", "active": "进行中", "recovered": "已确认结束"}.get(game.state.recovery_status, "未开启")
	var life_name: String = {"cultivating":"修行", "tribulation":"渡劫", "seclusion":"闭关", "ascended":"飞升"}.get(game.state.lifecycle_record().state, "未同步")
	daily_label.text = "服药：%s\n计划：%s\n修行状态：%s" % [medication, "已确认" if game.state.task_done("planned_record") else "待记录", life_name]
	if game.state.lifecycle_record().state in ["seclusion", "ascended"]:
		daily_label.text = "陪伴与回忆\n原有资源保留\n修行状态：" + life_name
	if is_instance_valid(game.companion_tasks) and game.companion_tasks.manages(game.family.active_id):
		var tasks = game.companion_tasks.members.get(game.family.active_id, [])
		var done = 0
		for task in tasks:
			done += int(task.status == "confirmed")
		daily_label.text = "微信安排：%d 项\n已反馈完成：%d 项\n修行状态：%s" % [tasks.size(), done, life_name]
	if is_instance_valid(wechat_task_label):
		wechat_task_label.text = wechat_record_text()

func refresh_companion_button() -> void:
	if not is_instance_valid(companion_button):
		return
	var catalogue = preload("res://scripts/companion_catalogue.gd")
	var pet = game.family.companion
	var chosen = catalogue.valid(str(pet.id)) and game.account_ready
	companion_button.text = "灵宠相伴 · " + catalogue.nickname(pet) if chosen else "选择你的灵宠  →"
	companion_button.icon = catalogue.texture(pet.id) if chosen else null

func open_companion(choose: bool = false) -> void:
	if require_family() or not can_change_family():
		return
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	companion_panel = Control.new()
	companion_panel.set_script(preload("res://scripts/companion_panel.gd"))
	companion_panel.game = game
	companion_panel.ui = self
	companion_panel.choose_mode = choose
	add_child(companion_panel)

func open_social() -> void:
	if require_family() or not can_change_family():
		return
	var content := _dialog("同道录", "用独立的社交昵称结识同道。交换邀请码后，由对方确认好友申请。")
	button(content, "神遁榜 · 全服 / 好友", open_shendun_board)
	if not game.state.is_remote() or not game.account_api.is_authenticated() or game.state.family_member_id != "self":
		paragraph(content, "登录游戏账号并切换到本人角色后，即可使用同道录。", 20)
		return
	var panel = SocialPanel.new()
	panel.game = game
	panel.ui = self
	panel.cultivator_id = game.state.cultivator_id
	content.add_child(panel)

func open_arena() -> void:
	var summary: Dictionary = game.account_api.duel_summary
	if int(summary.get("invitations", 0)) > 0 or summary.get("active_mode") == "friendly":
		open_duel_lobby()
	else:
		open_matchmaking_lobby()

func open_matchmaking_lobby() -> void:
	if require_family() or not can_change_family():
		return
	var content := _dialog("论剑台 · 匹配对战", "寻找在线同道，公平切磋，积累属于你的论剑战绩。")
	if not game.state.is_remote() or not game.account_api.is_authenticated() or game.state.family_member_id != "self":
		paragraph(content, "登录游戏账号并切换到本人角色后，即可参加匹配。", 20)
		return
	var lobby = MatchmakingLobby.new()
	lobby.game = game
	lobby.ui = self
	lobby.cultivator_id = game.state.cultivator_id
	content.add_child(lobby)

func open_duel_lobby(friend_id: String = "") -> void:
	if require_family() or not can_change_family():
		return
	var content := _dialog("论剑台", "好友实时切磋 · 双方使用同一套基础数值 · 一局 90 秒")
	if not game.state.is_remote() or not game.account_api.is_authenticated() or game.state.family_member_id != "self":
		paragraph(content, "登录游戏账号并切换到本人角色后，即可约战好友。", 20)
		return
	var lobby = DuelLobby.new()
	lobby.game = game
	lobby.ui = self
	lobby.cultivator_id = game.state.cultivator_id
	lobby.initial_friend = friend_id
	content.add_child(lobby)

func open_duel_battle(match_id: String) -> void:
	close_modal()
	modal_open = true
	game.player.blocked = true
	duel_view = DuelView.new()
	duel_view.game = game
	duel_view.ui = self
	duel_view.match_id = match_id
	duel_view.cultivator_id = game.state.cultivator_id
	add_child(duel_view)

func open_story(chapter_id: String = "") -> void:
	if require_family() or not can_change_family():
		return
	var content := _dialog("五域归衡 · 主线游历", "循线索游历五域，取得归衡印，完成守灯人的旅程。")
	if not game.state.is_remote() or not game.account_api.is_authenticated() or game.state.family_member_id != "self":
		paragraph(content, "登录游戏账号并切换到本人角色后，即可保存主线与冒险等级。", 20)
		return
	story_panel = StoryPanel.new()
	story_panel.game = game
	story_panel.ui = self
	story_panel.cultivator_id = game.state.cultivator_id
	story_panel.chapter_id = chapter_id
	content.add_child(story_panel)

func open_settings() -> void:
	if is_instance_valid(settings_panel) and not settings_panel.is_queued_for_deletion():
		return
	settings_panel = SettingsPanel.new()
	settings_panel.game = game
	settings_panel.ui = self
	add_child(settings_panel)

func open_expedition_lobby(chapter_id: String = "") -> void:
	if require_family() or not can_change_family():
		return
	var content := _dialog("五域秘境", "二十场正式挑战，通关获取历练、装备与锻材，推动五域归衡。")
	if not game.state.is_remote() or not game.account_api.is_authenticated() or game.state.family_member_id != "self":
		paragraph(content, "登录游戏账号并切换到本人角色后，即可进入秘境探索。", 20)
		return
	var lobby = ExpeditionLobby.new()
	lobby.game = game
	lobby.ui = self
	lobby.cultivator_id = game.state.cultivator_id
	lobby.chapter_id = chapter_id
	content.add_child(lobby)

func open_expedition_battle(run_id: String) -> void:
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	expedition_view = ExpeditionView.new()
	expedition_view.game = game
	expedition_view.ui = self
	expedition_view.run_id = run_id
	expedition_view.cultivator_id = game.state.cultivator_id
	add_child(expedition_view)

func close_modal(force: bool = false) -> void:
	if not force and is_instance_valid(story_panel) and story_panel.busy:
		toast("正在保存章节进度，请稍候。")
		return
	if not force and is_instance_valid(treasure) and treasure.is_submitting():
		toast("正在保存装备操作，请稍候。")
		return
	if is_instance_valid(expedition_view):
		if not force and not expedition_view.can_close():
			expedition_view.request_leave()
			return
		expedition_view.set_process(false)
		expedition_view.set_process_input(false)
		expedition_view.queue_free()
		expedition_view = null
	if is_instance_valid(duel_view):
		if not force and not duel_view.can_close():
			duel_view.request_leave()
			return
		duel_view.set_process(false)
		duel_view.set_process_input(false)
		duel_view.queue_free()
		duel_view = null
	if is_instance_valid(lifecycle_panel) and lifecycle_panel.busy and not force:
		toast("正在保存家属确认，请稍候。")
		return
	if is_instance_valid(lifecycle_panel):
		lifecycle_panel.queue_free()
	lifecycle_panel = null
	if is_instance_valid(lifecycle_gateway):
		lifecycle_gateway.queue_free()
	lifecycle_gateway = null
	if is_instance_valid(account_panel) and not game.account_ready and not force:
		return
	if is_instance_valid(account_panel):
		account_panel.clear_passwords()
		account_panel.queue_free()
	account_panel = null
	if is_instance_valid(start_screen):
		return
	if is_instance_valid(companion_panel):
		companion_panel.shutdown()
		companion_panel.queue_free()
	companion_panel = null
	wechat_task_label = null
	if is_instance_valid(health_entry):
		health_entry.shutdown()
		health_entry.queue_free()
	health_entry = null
	if is_instance_valid(treasure):
		treasure.finish_reveal()
		treasure.queue_free()
	treasure = null
	if is_instance_valid(family_panel):
		family_panel.queue_free()
	family_panel = null
	if is_instance_valid(corridor):
		corridor_position = corridor.player_position
		corridor_camera = corridor.camera_x
		corridor.set_process(false)
		corridor.set_process_input(false)
		corridor.queue_free()
	corridor = null
	if is_instance_valid(story_panel):
		story_panel.queue_free()
	story_panel = null
	if is_instance_valid(combat):
		combat.set_process(false)
		combat.set_process_input(false)
		combat.queue_free()
	combat = null
	super.close_modal()

func _check(parent: Node, text: String, checked: bool = false) -> CheckBox:
	var check = CheckBox.new()
	check.text = text
	check.button_pressed = checked
	check.add_theme_color_override("font_color", BROWN)
	check.add_theme_color_override("font_hover_color", Color("8d5f32"))
	check.add_theme_color_override("font_pressed_color", BROWN)
	check.add_theme_font_size_override("font_size", 16)
	parent.add_child(check)
	return check

func _dialog(title: String, subtitle: String) -> VBoxContainer:
	if not game.state.family_member_id.is_empty():
		subtitle = ("本人角色：" if game.state.family_member_id == "self" else "当前家人：") + game.state.member_label() + "  ·  " + subtitle
	close_modal()
	modal_open = true
	game.player.blocked = true
	modal = ColorRect.new()
	modal.color = Color(0.12, 0.08, 0.06, 0.65)
	add_child(modal)
	modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var content: VBoxContainer
	if preload("res://scripts/family_panel.gd").uses_touch_layout():
		var scroll := preload("res://scripts/family_panel.gd").form_scroll(modal, 1270)
		content = card(Rect2(), scroll)
		content.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		content = card(Rect2(270, 112, 900, 686), modal)
	var row = HBoxContainer.new()
	content.add_child(row)
	var title_label = label_into(row, title, 29)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button(row, "关闭 ×", close_modal)
	paragraph(content, subtitle, 16)
	line(content)
	return content

func open_game_entry() -> void:
	open_login()

func show_start() -> void:
	if is_instance_valid(start_screen):
		return
	return_to_health_entry = is_instance_valid(health_entry)
	close_modal()
	menu_hidden_controls.clear()
	for child in get_children():
		if child is Control and child.visible and not child.is_queued_for_deletion():
			menu_hidden_controls.append(child)
			child.hide()
	start_screen = ColorRect.new()
	start_screen.color = Color(0.08, 0.09, 0.1, 0.67)
	add_child(start_screen)
	start_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	selected_avatar = game.state.avatar_id
	var header = card(Rect2(425, 53, 590, 102), start_screen, WOOD)
	var title = label_into(header, "疯狂修仙，中", 46, Color("f3d19a"))
	title.add_theme_font_override("font", game.title_font)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var subtitle = label_into(start_screen, "选择你的守护者，与家人一同修行", 23, Color("fff0c6"))
	subtitle.position = Vector2(445, 176)
	subtitle.size.x = 550
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	avatar_buttons.clear()
	for i in range(2):
		var id = "male" if i == 0 else "female"
		var candidate = button(start_screen, "", func(): select_avatar(id))
		candidate.position = Vector2(412 + i * 335, 243)
		candidate.size = Vector2(281, 350)
		var image = Sprite2D.new()
		image.texture = game.avatar_frames[id][0]
		image.position = Vector2(140, 275)
		image.offset.y = -image.texture.get_height() * 0.5
		image.scale = Vector2.ONE * 233 / image.texture.get_height()
		candidate.add_child(image)
		var name_label = label_into(candidate, "男修 · 松风" if i == 0 else "女修 · 清岚", 24)
		name_label.position = Vector2(12, 290)
		name_label.size.x = 257
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		avatar_buttons.append(candidate)
	var prompt = label_into(start_screen, "你的昵称", 21, Color("f4e4c1"))
	prompt.position = Vector2(444, 625)
	nickname_input = LineEdit.new()
	nickname_input.position = Vector2(573, 618)
	nickname_input.size = Vector2(422, 49)
	nickname_input.text = game.state.player_name
	nickname_input.max_length = 10
	nickname_input.add_theme_stylebox_override("normal", style(PARCHMENT))
	nickname_input.add_theme_stylebox_override("focus", style(Color("f6e5bd")))
	nickname_input.add_theme_color_override("font_color", BROWN)
	nickname_input.add_theme_color_override("caret_color", BROWN)
	start_screen.add_child(nickname_input)
	var start = button(start_screen, "保存形象并进入" if game.state.profile_created else "开始修行", start_selected, true)
	start.position = Vector2(510, 711)
	start.size = Vector2(420, 68)
	if game.state.profile_created:
		var resume = button(start_screen, "继续上次修行  →", continue_game)
		resume.position = Vector2(1163, 23)
		resume.size.x = 252
	var note = label_into(start_screen, "为当前家人选择修仙形象；家人姓名与角色称号分别保存。", 16, Color("d9c6a7"))
	note.position = Vector2(420, 812)
	note.size.x = 600
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	select_avatar(selected_avatar)

func select_avatar(id: String) -> void:
	selected_avatar = "female" if id == "female" else "male"
	for i in range(avatar_buttons.size()):
		var chosen = (i == 1) == (selected_avatar == "female")
		var frame = style(Color("f0dbaf") if chosen else Color("cbb994"))
		frame.border_color = Color("f4c65f") if chosen else Color("8f724d")
		frame.set_border_width_all(5 if chosen else 2)
		avatar_buttons[i].add_theme_stylebox_override("normal", frame)

func start_selected() -> void:
	var needs_state_creation = return_to_health_entry or game.state.health_profile_id == ""
	return_to_health_entry = false
	game.apply_avatar(selected_avatar, nickname_input.text)
	continue_game()
	if needs_state_creation:
		open_health_entry()

func continue_game() -> void:
	if is_instance_valid(start_screen):
		start_screen.queue_free()
	start_screen = null
	for item in menu_hidden_controls:
		if is_instance_valid(item):
			item.show()
	menu_hidden_controls.clear()
	modal_open = false
	game.player.blocked = false
	refresh()
	if return_to_health_entry:
		return_to_health_entry = false
		open_health_entry()
		return
	toast("欢迎回到仙村，" + game.state.player_name)

func wechat_record_text() -> String:
	var context = preload("res://scripts/companion_context.gd")
	return game.companion_tasks.status_text() + "\n\n" + context.task_summary(context.snapshot(game), false)

func open_wechat_record() -> void:
	var content = _dialog("微信同步记录", "完成情况由老人微信反馈同步，这里可以查看最新状态。")
	wechat_task_label = paragraph(content, wechat_record_text(), 18, BROWN)
	wechat_task_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	button(content, "刷新微信记录", game.companion_tasks.refresh_now, true)
	paragraph(content, "老人明确反馈后，任务状态会自动刷新。", 14)

func open_record() -> void:
	if require_family():
		return
	if game.state.lifecycle_record().state in ["seclusion", "ascended"]:
		var content = _dialog("家人陪伴", "当前状态不发布健康管理任务。原有灵气、装备和通关记录保留。")
		paragraph(content, "家人可以探望、视频通话或记录共同回忆。陪伴不改变现实照护结果。", 21, BROWN)
		button(content, "查看修行状态", open_recovery, true)
		return
	if game.state.is_remote():
		open_wechat_tasks()
		return
	open_local_record()

## 老人在自己的微信里与健康助手聊天、反馈完成；这里只读取 C 结算后的任务状态，不提供代填。
func open_wechat_tasks() -> void:
	var state = game.state
	var content = _dialog("每日修行 · 微信记录", state.member_label() + "  ·  " + state.today())
	if state.family_member_id == "self":
		paragraph(content, "每日记录来自家人的微信健康助手。请切换到一位家人查看。", 20, BROWN)
		button(content, "PTDS 穿戴摘要", open_ptds_record, true)
		button(content, "我的家人", open_family)
		return
	wechat_task_label = paragraph(content, "正在读取微信同步记录…", 18, BROWN)
	wechat_task_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	content.add_child(actions)
	button(actions, "刷新", func(): refresh_wechat_tasks(state), true)
	button(actions, "绑定老人微信（扫码）", func(): bind_wechat(state))
	paragraph(content, "老人用微信扫码后，日常在微信里告诉健康助手完成情况即可；核验通过后灵气自动到账。两项记录每天共享一次奖励：修为 +10、灵印 +1、灵气 +100。", 15)
	refresh_wechat_tasks(state)

func open_ptds_record() -> void:
	var state = game.state
	var content = _dialog("PTDS 穿戴修行", "仅本人确认当天数据。原始生理指标只在本机预览，PVP 不受影响。")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 240
	content.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var preview = paragraph(box, "请选择本人从 PTDS 导出的 JSON。", 18, BROWN)
	var selection := {"date": "", "busy": false, "revision": -1, "summary": {}}
	var controls := {}
	var accept_summary := func(summary: Dictionary):
		preview.text = summary.message
		selection.date = summary.get("date", "")
		selection.summary = summary
		controls.confirm.disabled = selection.date != state.today() or selection.revision < 0
	var picker := FileDialog.new()
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.add_filter("*.json", "PTDS 摘要")
	content.add_child(picker)
	picker.file_selected.connect(func(path: String): accept_summary.call(PtdsSummary.read_file(path)))
	var choose = button(content, "选择摘要 JSON", func(): picker.popup_centered(Vector2i(720, 480)))
	if OS.has_feature("web"):
		choose.queue_free()
		var receive := JavaScriptBridge.create_callback(func(args: Array):
			if is_instance_valid(preview) and preview.is_visible_in_tree() and not selection.busy:
				accept_summary.call(PtdsSummary.preview(str(args[1])) if args[0] else {"message": str(args[1])})
		)
		content.set_meta("ptds_callback", receive)
		choose = button(content, "选择摘要 JSON", func():
			var window := JavaScriptBridge.get_interface("window")
			window.xiuxianPickPtdsSummary(receive)
		)
	var confirm = button(content, "确认本人今日记录", func():
		if selection.busy or selection.date != state.today() or game.state != state:
			return
		selection.busy = true
		controls.confirm.disabled = true
		var body: Dictionary = selection.summary.duplicate()
		body.erase("message")
		body.merge({"cultivator_id": state.cultivator_id, "rule": "wearable-v1", "expected_revision": selection.revision})
		var result = await game.account_api.api.request_api("/api/v2/wearables/confirm", HTTPClient.METHOD_POST, body)
		selection.busy = false
		if result.ok:
			await game.account_api.sync_family(game.family)
			refresh()
		if not is_instance_valid(preview) or game.state != state:
			return
		preview.text = "今日穿戴修行已确认。神遁距离已覆盖更新；每日奖励不重复发放，属性保持首次确认档位。可在神遁榜选择公开范围。" if result.ok else str(result.message)
		controls.confirm.disabled = false
		if result.ok:
			selection.date = ""
			controls.confirm.disabled = true
	, true)
	controls.confirm = confirm
	confirm.disabled = true
	button(content, "神遁榜 / 设置公开范围", open_shendun_board)
	button(content, "返回每日修行", open_record)
	var status = await game.account_api.api.request_api("/api/v2/wearables/status", HTTPClient.METHOD_POST, {"cultivator_id": state.cultivator_id})
	if not is_instance_valid(preview) or game.state != state:
		return
	if status.ok:
		selection.revision = int(status.data.revision)
		controls.confirm.disabled = selection.date != state.today()
	else:
		preview.text = str(status.message)


func open_shendun_board(scope: String = "global", period: String = "day", offset: int = 0) -> void:
	var state = game.state
	var content = _dialog("神遁榜", "1 步＝1 丈 · 按遁行距离排序 · 本人确认记录，不代表硬件认证")
	if not state.is_remote() or state.family_member_id != "self":
		paragraph(content, "登录并切换到本人角色后查看全服和好友神遁榜。", 20)
		return
	var tabs := HBoxContainer.new()
	content.add_child(tabs)
	button(tabs, "全服榜", func(): open_shendun_board("global", period), scope == "global")
	button(tabs, "好友榜", func(): open_shendun_board("friends", period), scope == "friends")
	button(tabs, "今日", func(): open_shendun_board(scope, "day"), period == "day")
	button(tabs, "本周", func(): open_shendun_board(scope, "week"), period == "week")
	var summary = paragraph(content, "正在读取…", 18)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 235
	content.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var rows = paragraph(box, "", 19, BROWN)
	paragraph(content, "公开距离可按固定比例反推出步数。默认不公开，以下选择会立即生效。", 16)
	var visibility := HBoxContainer.new()
	content.add_child(visibility)
	var feedback = paragraph(content, "", 16)
	for item in [["不公开", "private"], ["仅好友可见", "friends"], ["全服及好友可见", "public"]]:
		var label: String = item[0]
		var value: String = item[1]
		button(visibility, label, func():
			var response = await game.account_api.api.request_api("/api/v2/wearables/visibility", HTTPClient.METHOD_POST, {"cultivator_id": state.cultivator_id, "visibility": value})
			if not is_instance_valid(feedback) or game.state != state:
				return
			if response.ok:
				open_shendun_board(scope, period)
			else:
				feedback.text = str(response.message)
		)
	var actions := HBoxContainer.new()
	content.add_child(actions)
	button(actions, "导入今日穿戴数据", open_ptds_record, true)
	button(actions, "撤回今日记录", func():
		var response = await game.account_api.api.request_api("/api/v2/wearables/withdraw", HTTPClient.METHOD_POST, {"cultivator_id": state.cultivator_id})
		if is_instance_valid(feedback) and game.state == state:
			if response.ok:
				open_shendun_board(scope, period)
			else:
				feedback.text = str(response.message)
	)
	var result = await game.account_api.api.request_api("/api/v2/wearables/leaderboard", HTTPClient.METHOD_POST, {"cultivator_id": state.cultivator_id, "scope": scope, "period": period, "offset": offset})
	if not is_instance_valid(rows) or game.state != state:
		return
	if not result.ok:
		rows.text = str(result.message)
		return
	var data: Dictionary = result.data
	var own: Dictionary = data.get("self", {})
	summary.text = "%s 至 %s · 我的遁行：%s 丈 · 名次：%s" % [data.from, data.to, str(own.get("distance_zhang", "未确认")), str(own.get("rank", "未上榜"))]
	var lines := PackedStringArray()
	for entry in data.entries:
		lines.append("第 %d 名　%s%s　遁行 %d 丈" % [entry.rank, entry.alias, "（我）" if entry.is_self else "", entry.distance_zhang])
	rows.text = "\n".join(lines) if not lines.is_empty() else "暂无公开成绩。导入本人今日步数后，可选择参与神遁榜。"
	if offset > 0:
		button(actions, "上一页", func(): open_shendun_board(scope, period, maxi(0, offset - 50)))
	if data.has_more:
		button(actions, "下一页", func(): open_shendun_board(scope, period, offset + 50))
	var status = await game.account_api.api.request_api("/api/v2/wearables/status", HTTPClient.METHOD_POST, {"cultivator_id": state.cultivator_id})
	if is_instance_valid(feedback) and game.state == state and status.ok:
		var effect: Dictionary = status.data.effects
		feedback.text = "当前公开范围：%s · 今日 PVE：轻身 +%s%% / 回气 +%s%% / 护体 +%s%%" % [{"private": "不公开", "friends": "仅好友", "public": "全服及好友"}.get(status.data.visibility, "不公开"), str(float(effect.movement) * 100), str(float(effect.regeneration) * 100), str(float(effect.defense) * 100)]


func refresh_wechat_tasks(state) -> void:
	var result = await GameKernel.dispatch("quests.family_today", {"date": state.today()})
	if not is_instance_valid(wechat_task_label) or game.state != state:
		return
	if not result.ok:
		wechat_task_label.text = "暂时无法读取：" + str(result.message)
		return
	var lines: Array[String] = []
	var names = {"daily_medication_record": "既有用药安排", "daily_planned_record": "个人计划", "daily_step_record": "步数记录", "daily_measurement_record": "计划内测量"}
	var status_names = {"assigned": "等待老人微信反馈", "received": "已收到，核对中", "needs_supplement": "需要补充", "pending_confirmation": "等待确认", "verified": "已核验，结算中", "settled": "已完成", "rejected": "未通过"}
	for member in result.data.members:
		if member.cultivator_id != state.cultivator_id:
			continue
		for task in member.tasks:
			var line = "· %s：%s" % [names.get(task.template_id, task.title), status_names.get(task.status, task.status)]
			if task.settlement is Dictionary and int(task.settlement.spirit_stones) > 0:
				line += "  灵气 +%d" % int(task.settlement.spirit_stones)
			lines.append(line)
	wechat_task_label.text = "\n".join(lines) if not lines.is_empty() else "今天还没有已确认的安排。老人在微信里确认现有计划后，任务会自动出现。"
	await game.account_api.sync_family(game.family)
	refresh()

func bind_wechat(state) -> void:
	if not guest_elder_id.is_empty():
		guest_show_qr()
		return
	var invite = await game.account_api.api.request_api("/api/v2/bindings/invitations", HTTPClient.METHOD_POST, {"cultivator_id": state.cultivator_id})
	if not invite.ok:
		toast(str(invite.message))
		return
	var health_url = OS.get_environment("XIUXIAN_WECHAT_URL").strip_edges().trim_suffix("/")
	if health_url.is_empty() or OS.has_feature("official_client"):
		health_url = game.account_api.service_url if OS.has_feature("web") or OS.has_feature("official_client") else "http://127.0.0.1:8000"
	var request = HTTPRequest.new()
	request.timeout = 15
	add_child(request)
	request.request(health_url + "/api/v1/wechat/bind", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify({"invite_token": invite.data.invite_token}))
	var done = await request.request_completed
	request.queue_free()
	var data = JSON.parse_string(done[3].get_string_from_utf8()) if done[0] == HTTPRequest.RESULT_SUCCESS else null
	if not data is Dictionary or data.get("ok") != true:
		toast("微信助手暂时无法生成二维码，请稍后重试。")
		return
	OS.shell_open(health_url + "/wechat/bind/" + str(data.data.bind_id))
	toast("已打开二维码页面，请老人用自己的微信扫一扫。")

## 未登录 C 的本地演示存档沿用原记录页。
func open_local_record() -> void:
	var state = game.state
	var content = _dialog("每日修行 · 家人健康计划", state.member_label() + "  ·  " + state.today() + "  ·  本地演示")
	paragraph(content, "本地演示模式。正式账号的每日记录由老人微信反馈同步，不在游戏里代填。", 18, BROWN)
	var consent = _check(content, "我已了解这是模拟记录")
	var record = button(content, "确认今日计划记录（演示）", func(): confirm_task("planned_record", consent.button_pressed), true)
	record.disabled = state.task_done("planned_record")

func confirm_task(task: String, consent: bool) -> void:
	var result = game.state.record_task(task, consent)
	if not result.ok:
		toast(result.message)
		return
	refresh()
	if result.rewarded:
		open_reward(result.message)
	else:
		open_record()

func open_plan_settings() -> void:
	var content = _dialog("个人计划设置", "只配置演示任务，不生成医疗建议。")
	paragraph(content, "长期管理与阶段恢复可以同时存在。没有用药计划的家人，可关闭服药任务。", 21, BROWN)
	var longterm = _check(content, "启用长期健康管理", game.state.longterm_enabled)
	var medication = _check(content, "个人既有计划包含每日服药记录（演示）", game.state.medication_required)
	line(content)
	button(content, "保存计划设置", func():
		game.state.longterm_enabled = longterm.button_pressed
		game.state.medication_required = medication.button_pressed and longterm.button_pressed
		game.state.save_game()
		refresh()
		open_record()
	, true)
	button(content, "查看阶段恢复篇章", open_recovery)

func _a_scope() -> String:
	return "%s/%s/%d" % [str(game.family.account.id), str(game.family.active_id), game.state.get_instance_id()]

func open_recovery() -> void:
	if require_family():
		return
	if is_instance_valid(combat):
		toast("请先结束或退出当前战斗，再查看修行状态。")
		return
	close_modal()
	lifecycle_gateway = preload("res://scripts/tribulation/family_gateway.gd").new()
	lifecycle_gateway.remote_api = game.account_api.api
	add_child(lifecycle_gateway)
	var role_id: String = _a_scope()
	var started: Dictionary = lifecycle_gateway.bind(game.state, role_id, Callable(self, "_a_scope"))
	if not started.ok:
		toast(started.message)
		lifecycle_gateway.queue_free()
		lifecycle_gateway = null
		return
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	lifecycle_panel = load("res://scenes/tribulation/platform.tscn").instantiate()
	lifecycle_panel.kernel = lifecycle_gateway
	lifecycle_panel.quiet_background_texture = Assets.texture("res://assets/pixel_campaign/map_origin.png")
	lifecycle_panel.background_texture = Assets.texture("res://assets/gameplay/tribulation-stage.png")
	lifecycle_panel.cultivator_texture = Assets.texture("res://assets/gameplay/elder-meditating.png")
	lifecycle_panel.cultivator_id = role_id
	lifecycle_panel.cultivator_name = game.state.player_name
	var record: Dictionary = game.state.lifecycle_record()
	lifecycle_panel.lamps = int(record.lamps)
	if not str(record.template_id).is_empty():
		lifecycle_panel.template_id = record.template_id
	lifecycle_panel.left.connect(close_modal)
	lifecycle_panel.celebrated.connect(func(_role: String) -> void: refresh())
	lifecycle_panel.confirmation_canceled.connect(lifecycle_gateway.cancel_requests)
	lifecycle_panel.lamps_changed.connect(_a_save_lamp)
	lifecycle_panel.template_chosen.connect(func(template: String) -> void:
		var saved: Dictionary = lifecycle_gateway.remember_template(template)
		if not saved.ok:
			lifecycle_panel.status = saved.message
	)
	var banner := Label.new()
	banner.text = game.state.member_label() + " · 当前账号本机演示确认"
	banner.position = Vector2(650, 120)
	banner.add_theme_color_override("font_color", Color("#e0c587"))
	lifecycle_panel.add_child(banner)
	add_child(lifecycle_panel)

func _a_save_lamp(count: int) -> void:
	if not is_instance_valid(lifecycle_gateway):
		return
	var saved: Dictionary = lifecycle_gateway.record_lamp(count)
	if not saved.ok and is_instance_valid(lifecycle_panel):
		lifecycle_panel.lamps = int(game.state.lifecycle_record().lamps)
		lifecycle_panel.status = saved.message
		lifecycle_panel.queue_redraw()

func _a_battle_allowed() -> bool:
	if is_instance_valid(lifecycle_panel) and (lifecycle_panel.busy or lifecycle_panel._dialog.visible):
		toast("请先确认或取消当前家属操作。")
		return false
	if require_family():
		return false
	if not game.state.allows_battle():
		toast("当前家人正在渡劫、闭关或已飞升，请切换修行中的角色。")
		return false
	return true

func open_health_entry() -> void:
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	health_entry = Control.new()
	health_entry.set_script(load("res://scripts/health_entry_panel.gd"))
	health_entry.game = game
	health_entry.ui = self
	add_child(health_entry)

func open_beginner_guide() -> void:
	if require_family():
		return
	var state = game.state
	var content := _dialog("新手指引 · 第一段旅程", "从领取装备到完成首战，按下面的顺序体验。随时可从左侧重新打开。")
	var pulled: bool = int(state.equipment.get("starter_ten_pulls", 0)) == 0 and state.equipment.get("inventory", []).size() > 0
	var equipped: bool = state.equipment.get("equipped", {}).size() > 0
	var won: bool = state.cleared_bosses.size() > 0 or state.cleared_stages.size() > 0
	var steps = [
		{"done": pulled, "title": "领取第一批装备", "detail": "打开聚宝阁，使用新手免费十连；抽到的物品会进入行囊。", "action": "去聚宝阁", "callback": open_treasure.bind("wish")},
		{"done": equipped, "title": "穿上装备", "detail": "进入行囊，点开刚得到的装备并穿戴；装备属性会用于之后的战斗。", "action": "打开行囊", "callback": open_treasure.bind("bag")},
		{"done": won, "title": "完成第一次挑战", "detail": "从五域游历进入主线，选择开放的第一关并完成战斗。", "action": "进入主线", "callback": open_story}
	]
	var next_step := -1
	for i in range(steps.size()):
		if not steps[i].done and next_step == -1:
			next_step = i
	var summary := "第一段旅程已完成，可以继续探索。" if next_step == -1 else "当前目标：%s" % steps[next_step].title
	label_into(content, summary, 23)
	for i in range(steps.size()):
		var step: Dictionary = steps[i]
		label_into(content, "%s %d. %s" % ["✓" if step.done else "→" if i == next_step else "○", i + 1, step.title], 20)
		paragraph(content, step.detail, 17)
		if i == next_step:
			button(content, step.action + " →", step.callback, true)
	if next_step == -1:
		paragraph(content, "接下来可以查看今日计划：了解家人的记录如何连接到角色成长。此项由你自主体验，不计入首段通关。", 17)
		button(content, "查看今日计划 →", open_record)
	paragraph(content, "完成操作后再次打开指引，进度会从当前角色的装备与通关记录更新。", 16)

func open_home() -> void:
	if require_family():
		return
	if game.state.is_remote() and game.state.family_member_id == "self":
		open_adventure_home()
		return
	var state = game.state
	var content = _dialog(state.player_name + "档案 · 健康与修行", "健康档案形成五项属性；新的评估结果会更新下一场战斗的角色能力。")
	content.add_theme_constant_override("separation", 8)
	var columns = HBoxContainer.new()
	columns.add_theme_constant_override("separation", 28)
	content.add_child(columns)
	var left = VBoxContainer.new()
	left.custom_minimum_size.x = 370
	left.add_theme_constant_override("separation", 8)
	columns.add_child(left)
	label_into(left, state.player_name + "  ·  " + state.realm(), 25)
	label_into(left, "初始战斗属性 · 已确认" if not state.health_baseline.is_empty() else "五项健康属性 / 0—100", 17)
	for key in state.ATTRIBUTE_KEYS:
		var row = HBoxContainer.new()
		left.add_child(row)
		var name_label = label_into(row, state.ATTRIBUTE_LABELS[key], 19)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label_into(row, ("%d HP" if key == "life" else "%d") % state.health_attributes[key] if not state.health_baseline.is_empty() else "%d / 100" % state.health_attributes[key], 19)
		var bar = ProgressBar.new()
		bar.custom_minimum_size = Vector2(360, 10)
		bar.show_percentage = false
		bar.max_value = maxf(100, float(state.health_attributes[key]))
		bar.value = state.health_attributes[key]
		left.add_child(bar)
	var stats = state.battle_stats()
	line(left)
	paragraph(left, "含装备的战斗属性\n生命上限 %d    普攻伤害 %d\n灵力上限 %d    体力上限 %d\n云罡护盾 %d    伤害减免 %d%%" % [stats.max_hp, stats.attack, stats.max_mp, stats.max_stamina, stats.shield, roundi((1.0 - stats.damage_multiplier) * 100)], 17, BROWN)
	var right = VBoxContainer.new()
	right.custom_minimum_size.x = 420
	right.add_theme_constant_override("separation", 12)
	columns.add_child(right)
	label_into(right, "档案来源", 23)
	paragraph(right, state.health_source + (" · 模拟" if state.health_simulated else " · 外部评估档案"), 17, BROWN)
	button(right, "补充报告 · 重新生成属性" if not state.health_baseline.is_empty() else "上传健康报告 · 生成初始属性", open_health_entry, true)
	if not state.health_baseline.is_empty():
		paragraph(right, "这份初始档案已锁定。可补充报告后确认新档案，原有通关和技能解锁会保留。", 17)
		paragraph(right, "守护准备度 %d / 100" % state.health_baseline.readiness, 16)
	else:
		button(right, "导入已评估档案（JSON）", choose_profile_file, true)
		label_into(right, "选择一份模拟初始档案", 18)
		var presets = HBoxContainer.new()
		right.add_child(presets)
		for score in [20, 40, 60]:
			var value: int = score
			var preset = button(presets, "攻击 %d" % score, func(): use_mock_profile(value))
			preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button(right, "模拟健康改善 · 五项各 +10", improve_mock_profile)
	paragraph(right, "更新档案不清空已通关记录。战斗受伤、技能消耗也不会修改这五项属性。", 16)
	line(right)
	label_into(right, "技能解锁  %d / 4" % (4 if state.heal_unlocked() else 3), 21)
	paragraph(right, "听风剑诀 · 踏云步 · 云罡护体\n" + ("饕餮归元 · 已解锁" if state.heal_unlocked() else "饕餮归元 · 首通两个不同关卡解锁"), 16, BROWN)
	line(content)
	var actions = HBoxContainer.new()
	content.add_child(actions)
	button(actions, "进入属性闯关", open_boss, true)
	button(actions, "前往演武台", open_battle)
	button(actions, "记录今日计划", open_record)
	button(actions, "行囊与装备", func(): open_treasure("bag"))

func open_adventure_home() -> void:
	if not can_change_family():
		return
	var id: String = game.state.cultivator_id
	var content := _dialog("本人成长 · 冒险与装备", "正式秘境使用冒险等级与穿戴装备，论剑使用统一数值。")
	var panel := modal
	var details := paragraph(content, "正在读取正式冒险属性…", 20)
	button(content, "五域游历 · 继续主线", open_story, true)
	button(content, "行囊与锻造", open_treasure.bind("forge"))
	paragraph(content, "家人的健康档案可从「我的家人」切换查看。属性长廊与演武使用各自的档案属性，正式秘境的成长与奖励保存在游戏服务。", 17)
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("combat.expedition_lobby", {"cultivator_id": id})
	if not is_instance_valid(panel) or panel.is_queued_for_deletion() or modal != panel or game.state.cultivator_id != id:
		return
	if not result.ok:
		details.text = result.message
		button(content, "重新读取", open_adventure_home)
		return
	var adventure: Dictionary = result.data.get("adventure", {})
	var loadout: Dictionary = result.data.get("loadout", {})
	if loadout.is_empty():
		details.text = "当前游戏服务尚未提供冒险属性预览，请更新服务后重试。"
		return
	var rules := preload("res://scripts/adventure_catalogue.gd")
	details.text = rules.level_text(adventure) + "\n" + rules.progress_text(adventure) + "\n\n等级基础属性\n" + rules.stats_text(loadout.base_stats) + "\n\n当前装备与套装加成\n" + rules.stats_text(loadout.equipment_bonuses) + "\n\n下次秘境入场属性\n" + rules.stats_text(loadout.stats)
	details.tooltip_text = "以游戏服务当前等级与穿戴记录为准，每次入场重新生成快照。"

func use_mock_profile(score: int) -> void:
	var payload = game.state.HealthProfile.mock(score, game.state.health_revision + 1)
	payload.attributes.life = mini(100, score + 5)
	payload.attributes.defense = maxi(0, score - 5)
	payload.attributes.spirit = mini(100, score + 10)
	apply_profile(payload)

func improve_mock_profile() -> void:
	var payload = game.state.HealthProfile.mock(40, game.state.health_revision + 1)
	for key in game.state.ATTRIBUTE_KEYS:
		payload.attributes[key] = mini(100, int(game.state.health_attributes[key]) + 10)
	payload.source = "模拟健康改善"
	apply_profile(payload)

func apply_profile(payload: Dictionary) -> void:
	var result = game.state.save_health_profile(payload)
	if not result.ok:
		toast(result.message)
		return
	refresh()
	open_home()
	toast(result.message)

func choose_profile_file() -> void:
	if is_instance_valid(profile_file_dialog):
		profile_file_dialog.queue_free()
	profile_file_dialog = FileDialog.new()
	profile_file_dialog.title = "导入健康属性档案"
	profile_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	profile_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	profile_file_dialog.filters = PackedStringArray(["*.json ; 健康属性档案"])
	add_child(profile_file_dialog)
	profile_file_dialog.file_selected.connect(func(path: String):
		var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
		profile_file_dialog.queue_free()
		if not payload is Dictionary:
			toast("无法读取档案，请选择有效的 JSON 属性档案。")
			return
		apply_profile(payload)
	)
	profile_file_dialog.canceled.connect(profile_file_dialog.queue_free)
	profile_file_dialog.popup_centered(Vector2i(900, 620))

func open_battle() -> void:
	var content = _dialog("演武台 · 四式初习", "练习沿用当前属性，可自由重试，不结算闯关首通。")
	label_into(content, "普攻回灵，踏云回气，四式相辅", 27)
	paragraph(content, "普攻 [J]：靠近目标命中后，恢复 5 灵力。\n听风剑诀 [1]：18 灵力，剑气穿过路径上的目标。\n踏云步 [2 / 空格]：24 体力，快速位移并短暂闪避。\n云罡护体 [3 / K]：24 灵力，护盾强度随防御提升。\n饕餮归元 [4 / R]：45 灵力，短暂吐纳后恢复生命。", 20, BROWN)
	line(content)
	paragraph(content, "体力会自动恢复。归元吐纳时移动变慢，受到实际伤害会中断。每次进入训练或挑战，生命、灵力与体力重新补满。", 18)
	paragraph(content, "饕餮归元：" + ("已解锁" if game.state.heal_unlocked() else "首通两个不同关卡后解锁"), 18)
	button(content, "开始技能练习", start_battle, true)
	button(content, "AI 护法陪练（不结算首通）", start_companion_practice)
	button(content, "查看五项属性", open_home)

func start_battle() -> void:
	_open_combat("practice")

func open_boss() -> void:
	if require_family():
		return
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	corridor = load("res://scenes/boss_corridor.tscn").instantiate()
	corridor.game = game
	corridor.ui = self
	add_child(corridor)
	corridor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func start_corridor_boss(id: String) -> void:
	if not _a_battle_allowed():
		return
	var result = game.state.begin_named_boss(id)
	if not result.ok:
		toast(result.message)
		return
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	game.state.save_game()
	combat = load(TrialCatalogue.scene_path(id)).instantiate()
	combat.game = game
	combat.ui = self
	add_child(combat)
	combat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	refresh()

func select_track(track: String) -> void:
	game.state.selected_track = track
	game.state.selected_tier = game.state.next_tier(track)
	game.state.save_game()
	open_boss()

func start_boss(use_support: bool = false, tier: int = 0, track: String = "") -> void:
	if not _a_battle_allowed():
		return
	if tier == 0 and track == "":
		start_corridor_boss(game.state.selected_boss_id)
		return
	var result = game.state.begin_boss(use_support, tier, track)
	if not result.ok:
		toast(result.message)
		return
	game.state.save_game()
	_open_combat("boss")

func open_reward(message: String) -> void:
	var content = _dialog("今日修行已记下", "计划完成的积累已保存；健康属性由单独的评估档案更新。")
	paragraph(content, message, 23, BROWN)
	line(content)
	paragraph(content, "灵气已存入聚宝阁钱包，每日 +100；单抽 70、十连 700，十连至少一件史诗。装备加成在下一场战斗生效。", 18)
	button(content, "前往聚宝阁", open_treasure, true)
	button(content, "查看健康档案", open_home)
	button(content, "进入属性闯关", open_boss)
	button(content, "回到仙村", close_modal)

func _open_combat(kind: String, bonus: int = 0) -> void:
	if not _a_battle_allowed():
		return
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	combat = Control.new()
	combat.set_script(Combat)
	combat.game = game
	combat.ui = self
	combat.mode = kind
	combat.support = bonus
	add_child(combat)
	combat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	refresh()


func open_site(id: String) -> void:
	if id == "gacha":
		open_treasure()
	else:
		super.open_site(id)

func open_treasure(view: String = "wish") -> void:
	if require_family() or not can_change_family():
		return
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	treasure = Control.new()
	treasure.set_script(preload("res://scripts/treasure_panel.gd"))
	treasure.game = game
	treasure.ui = self
	treasure.tab = view
	add_child(treasure)


func require_family() -> bool:
	if not game.account_ready:
		open_login()
		return true
	return false

func can_change_family() -> bool:
	if is_instance_valid(story_panel) and story_panel.busy:
		toast("请等待章节进度保存完成。")
		return false
	if is_instance_valid(treasure) and treasure.is_submitting():
		toast("请等待本次装备操作完成。")
		return false
	if is_instance_valid(expedition_view) and not expedition_view.can_close():
		toast("请先结束当前秘境挑战。")
		return false
	if is_instance_valid(duel_view) and not duel_view.can_close():
		toast("请先结束当前论剑。")
		return false
	if is_instance_valid(lifecycle_panel) and (lifecycle_panel.busy or lifecycle_panel._dialog.visible):
		toast("请先确认或取消当前操作，再切换家人。")
		return false
	if is_instance_valid(combat) and not combat.rules.finished:
		toast("请先结束或退出当前战斗，再切换家人。")
		return false
	if is_instance_valid(health_entry) and health_entry.busy:
		health_entry.status.text = "资料正在处理中，请等待完成，或先返回取消处理。"
		toast("资料正在处理中，请等待完成，或先返回取消处理。")
		return false
	return true

func open_family() -> void:
	if require_family():
		return
	if not can_change_family():
		return
	close_modal()
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	family_panel = Control.new()
	family_panel.set_script(preload("res://scripts/family_panel.gd"))
	family_panel.game = game
	family_panel.ui = self
	add_child(family_panel)

func activate_family(id: String, fill_health: bool = false) -> bool:
	if not can_change_family():
		return false
	var result = game.family.select_member(id)
	if not result.ok:
		if is_instance_valid(family_panel) and is_instance_valid(family_panel.status_label):
			family_panel.status_label.text = result.message
		else:
			toast(result.message)
		return false
	close_modal()
	game.state = game.family.state_for(id)
	game.sync_avatar_from_state()
	game.player.position = game.SPAWN
	game.player.route.clear()
	game.player.destination_site = ""
	corridor_position = Vector2(180, 715)
	corridor_camera = 0
	refresh()
	if fill_health or (id != "self" and game.state.health_profile_id.is_empty()):
		open_health_entry()
	else:
		toast(("正在操作本人角色：" if id == "self" else "正在照顾：") + game.state.member_label())
	return true


func open_login() -> void:
	close_modal(true)
	modal_open = true
	game.player.blocked = true
	game.player.route.clear()
	account_panel = Control.new()
	account_panel.set_script(preload("res://scripts/account_panel.gd"))
	account_panel.game = game
	account_panel.ui = self
	add_child(account_panel)

## 现场演示入口：不注册、不联网，直接准备一份可走完「绑定家人 → 健康任务 → 结算」的数据。
func start_guest_demo() -> void:
	close_modal(true)
	var roster = game.FamilyRoster.new()
	roster.persist_enabled = false
	roster.account_bound = false
	roster.account = {"id": "guest-demo", "name": "游客演示"}
	roster.reset_owner({"display_name": "松风", "avatar": "male"})
	var added = roster.add_member({"name": "王奶奶", "relation": "母亲", "age": 68, "sex": "女", "title": "王奶奶的化身", "mode": "family", "consent": true})
	if not added.get("ok", false):
		toast("演示数据准备失败：" + str(added.get("message", "请重试")))
		return
	guest_elder_id = str(added.get("id", ""))
	var elder = roster.state_for(guest_elder_id)
	if elder == null:
		toast("演示数据准备失败，请重试。")
		return
	elder.choose_avatar("female", "王奶奶的化身")
	elder.apply_health_profile({"profile_id": "demo-elder-profile", "revision": 1,
		"attributes": {"life": 62, "attack": 48, "defense": 55, "spirit": 41, "stamina": 58},
		"source": "模拟健康档案（游客演示）", "simulated": true})
	elder.equipment.starter_ten_pulls = 1
	elder.medication_required = true
	elder.longterm_enabled = true
	game.family = roster
	game.account_ready = true
	game.state = elder
	game.companion_api.reset_session()
	game.sync_avatar_from_state()
	guest_bound = false
	guest_task_done = false
	refresh()
	open_guest_guide()

func open_guest_guide() -> void:
	var content = _dialog("游客演示 · 三步走完核心流程", "王奶奶（母亲，68 岁）· 所有数据都是现场模拟，不会真的发微信")
	paragraph(content, "正式产品里，家人扫描微信二维码后，每天的用药与计划完成情况由老人在微信里反馈；这里用按钮代替扫码和微信消息。", 17)
	line(content)
	var bind = button(content, "✅ 已绑定王奶奶的微信（演示）" if guest_bound else "① 模拟绑定王奶奶的微信（出示二维码）", guest_show_qr)
	bind.disabled = guest_bound
	var task = button(content, "✅ 今日健康任务已完成" if guest_task_done else "② 模拟完成今日健康任务", guest_complete_task)
	task.disabled = guest_task_done
	button(content, "③ 查看修行结算与健康属性", guest_show_result)
	line(content)
	button(content, "退出演示，回到登录", guest_exit_demo)

func guest_exit_demo() -> void:
	close_modal(true)
	guest_bound = false
	guest_task_done = false
	guest_elder_id = ""
	reset_logged_out()

## 演示二维码：不接真实微信通道，只画一张可识别的占位二维码，避免现场扫码失败。
func guest_show_qr() -> void:
	var content = _dialog("绑定家人微信（演示）", "真实流程会在这里显示微信授权二维码；演示用占位图代替。")
	var holder = CenterContainer.new()
	content.add_child(holder)
	var qr = TextureRect.new()
	qr.texture = _demo_qr_texture()
	qr.custom_minimum_size = Vector2(220, 220)
	qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	holder.add_child(qr)
	paragraph(content, "王奶奶的微信 · 等待扫码（演示占位）", 18)
	button(content, "模拟扫码成功", guest_confirm_qr, true)
	button(content, "返回", guest_back_to_guide)

func guest_confirm_qr() -> void:
	guest_bound = true
	close_modal(true)
	open_guest_guide()
	toast("已绑定王奶奶的微信（演示）")

func guest_back_to_guide() -> void:
	close_modal(true)
	open_guest_guide()

func _demo_qr_texture() -> Texture2D:
	var size = 29
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var rng = RandomNumberGenerator.new()
	rng.seed = 20261101
	for y in range(size):
		for x in range(size):
			if rng.randf() < 0.44:
				image.set_pixel(x, y, Color.BLACK)
	for origin in [Vector2i(1, 1), Vector2i(size - 8, 1), Vector2i(1, size - 8)]:
		for dy in range(7):
			for dx in range(7):
				var edge = dx == 0 or dy == 0 or dx == 6 or dy == 6
				var core = dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4
				image.set_pixel(origin.x + dx, origin.y + dy, Color.BLACK if (edge or core) else Color.WHITE)
	return ImageTexture.create_from_image(image)

func guest_complete_task() -> void:
	var elder = game.family.state_for(guest_elder_id)
	if elder == null:
		toast("演示家人已失效，请重新进入游客演示。")
		return
	game.state = elder
	game.sync_avatar_from_state()
	refresh()
	var medication = elder.record_task("medication", true)
	var planned = elder.record_task("planned_record", true)
	guest_task_done = true
	var content = _dialog("今日健康任务（演示）", "模拟王奶奶在微信里确认：今天的药吃了，计划也完成了。")
	paragraph(content, "服药记录：" + str(medication.get("message", "")), 17)
	paragraph(content, "每日计划：" + str(planned.get("message", "")), 17)
	line(content)
	paragraph(content, "当前修行值：修为 %d · 印记 %d · 灵气 %d" % [elder.cultivation, elder.seals, elder.qi], 19, BROWN)
	button(content, "下一步：查看结算", guest_next_result, true)
	button(content, "返回演示向导", guest_back_to_guide)

func guest_next_result() -> void:
	close_modal(true)
	guest_show_result()

func guest_show_result() -> void:
	var elder = game.family.state_for(guest_elder_id)
	if elder == null:
		toast("演示家人已失效，请重新进入游客演示。")
		return
	var content = _dialog("修行结算（演示）", "健康任务完成 → 修为、印记与灵气计入王奶奶的修行进度")
	paragraph(content, "修为 %d · 印记 %d · 灵气 %d" % [elder.cultivation, elder.seals, elder.qi], 22, BROWN)
	paragraph(content, "五项属性：生命 %d / 攻击 %d / 防御 %d / 灵力 %d / 体力 %d" % [elder.health_attributes.get("life", 0), elder.health_attributes.get("attack", 0), elder.health_attributes.get("defense", 0), elder.health_attributes.get("spirit", 0), elder.health_attributes.get("stamina", 0)], 18)
	paragraph(content, "来源：" + str(elder.health_source), 16)
	line(content)
	button(content, "回到演示向导", guest_back_to_guide, true)
	button(content, "打开家人面板", guest_open_family)
	button(content, "去聚宝阁 · 领取新手十连", func(): open_treasure("wish"), true)
	button(content, "返回仙村", close_modal)

func guest_open_family() -> void:
	close_modal(true)
	open_family()

func on_account_progress(message: String) -> void:
	if is_instance_valid(account_panel):
		account_panel.status_label.text = message

func on_account_result(action: String, result: Dictionary) -> void:
	if is_instance_valid(account_panel):
		account_panel.submit_button.disabled = false
	if not result.get("ok", false):
		if is_instance_valid(account_panel):
			account_panel.status_label.text = str(result.get("message", "操作失败，请重试。"))
		else:
			toast(str(result.get("message", "操作失败，请重试。")))
		return
	if action == "logout":
		reset_logged_out()
		return
	if action == "claim-legacy":
		finish_account_setup(true)
		return
	if action not in ["register", "login"]:
		return
	if is_instance_valid(account_panel):
		account_panel.clear_passwords()
	var roster = game.FamilyRoster.new()
	var expected_generation: int = game.account_api.generation
	roster.cache_root_override = game.account_cache_root_override
	roster.legacy_source_override = game.account_legacy_source_override
	var prepared = roster.open_account(result.account)
	if prepared.ok:
		# C 是本人与两位老人的权威来源；本机文件只作展示缓存。
		var synced = await game.account_api.sync_family(roster)
		if expected_generation != game.account_api.generation or not game.account_api.is_authenticated() or str(game.account_api.account.get("id", "")) != str(roster.account.id):
			roster.dispose()
			return
		if not synced.ok:
			prepared = {"ok": false, "message": str(synced.get("message", "无法读取游戏服务中的家族角色。"))}
	if not prepared.ok:
		roster.dispose()
		if is_instance_valid(account_panel):
			account_panel.status_label.text = prepared.message
		return
	game.pending_account_roster = roster
	if prepared.needs_import:
		account_panel.migration_mode = true
		account_panel.build()
	else:
		finish_account_setup(false)

func import_old_account() -> void:
	if game.pending_account_roster == null or game.account_api.busy or game.pending_account_roster.setup_in_progress:
		return
	var source = game.pending_account_roster.legacy_snapshot()
	if not source.ok:
		account_panel.status_label.text = source.message
		return
	var fingerprint = source.fingerprint
	account_panel.submit_button.disabled = true
	game.account_api.claim_legacy(fingerprint)

func finish_account_setup(import_old: bool) -> void:
	var roster = game.pending_account_roster
	if roster == null or roster.setup_in_progress:
		return
	roster.setup_in_progress = true
	if is_instance_valid(account_panel):
		account_panel.submit_button.disabled = true
	if not import_old:
		roster.legacy_choice_made = true
	if not (roster.import_legacy() if import_old else roster.save_game()):
		roster.setup_in_progress = false
		if is_instance_valid(account_panel):
			account_panel.submit_button.disabled = false
			account_panel.status_label.text = roster.last_error
		return
	if roster.is_service_account():
		var expected_generation: int = game.account_api.generation
		var synced: Dictionary = await game.account_api.sync_family(roster)
		if game.pending_account_roster != roster or expected_generation != game.account_api.generation:
			roster.setup_in_progress = false
			return
		if not synced.ok or not game.account_api.is_authenticated() or str(game.account_api.account.get("id", "")) != str(roster.account.id) or not roster.is_remote():
			roster.setup_in_progress = false
			if is_instance_valid(account_panel):
				account_panel.submit_button.disabled = false
				account_panel.status_label.text = "旧档已备份；" if import_old and not roster.legacy_archive.is_empty() else ""
				account_panel.status_label.text += str(synced.get("message", "账号角色同步未完成，请重试。")) if not synced.ok else "账号角色同步未完成，请重新登录。"
			return
	roster.setup_in_progress = false
	close_modal(true)
	game.family.dispose()
	game.family = roster
	game.pending_account_roster = null
	game.account_ready = true
	game.state = roster.active_state()
	game.companion_api.reset_session()
	game.sync_avatar_from_state()
	refresh()
	if game.family.companion.id.is_empty() and "--skip-intro" not in OS.get_cmdline_user_args():
		open_companion(true)
	else:
		open_family()

func logout_account() -> void:
	if not can_change_family() or game.account_api.busy:
		return
	if game.account_ready and not game.family.save_game():
		toast("当前进度保存失败，请重试后再退出。")
		return
	game.account_api.logout()

func reset_logged_out() -> void:
	close_modal(true)
	guest_bound = false
	guest_task_done = false
	guest_elder_id = ""
	if is_instance_valid(game.companion_tasks):
		game.companion_tasks.clear_state()
	game.companion_api.reset_session()
	game.family.dispose()
	if game.pending_account_roster != null:
		game.pending_account_roster.dispose()
		game.pending_account_roster = null
	game.family = game.FamilyRoster.new()
	game.family.persist_enabled = false
	game.state = game.family.owner_state
	game.account_ready = false
	game.sync_avatar_from_state()
	refresh()
	open_login()

func start_companion_practice() -> void:
	_open_combat("practice")
	if is_instance_valid(combat) and combat.mode == "practice":
		combat.enable_companion()
