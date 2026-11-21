extends Control

const Assets = preload("res://scripts/pixel_assets.gd")
const Actions = preload("res://scripts/systems/combat/action_atlas.gd")
const Lobby = preload("res://scripts/duel_lobby.gd")
const Feedback = preload("res://scripts/battle_feedback.gd")
const ACTION_NAMES = ["普攻 [J]", "听风剑诀 [1]", "踏云步 [2]", "云罡护体 [3]", "饕餮归元 [4]"]
const TOUCH_ORDER = [1, 2, 4, 3, 5]
var game: Node
var ui: Control
var match_id: String
var cultivator_id: String
var state: Dictionary = {}
var heroes: Array[Sprite2D] = []
var banks: Array[Dictionary] = []
var name_labels: Array[Label] = []
var health_labels: Array[Label] = []
var bars: Array[ProgressBar] = []
var resource_labels: Array[Label] = []
var action_buttons: Array[Button] = []
var heading: Label
var banner: Label
var exit_button: Button
var settings_button: Button
var keyboard_hint: Label
var result_panel: Control
var leave_dialog: ConfirmationDialog
var realtime: Node
var seat: int = 0
var sequence: int = 0
var pending_action: int = 0
var send_clock: float = 0
var animation_clock: float = 0
var last_packet_ms: int = 0
var last_tick: int = -1
var ready_to_close: bool = false
var leaving: bool = false
var feedback: Node2D

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	feedback = Feedback.new()
	add_child(feedback)
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.enter_battle(self)
	realtime = game.account_api.realtime
	realtime.duel_state_received.connect(receive_state)
	realtime.duel_error_received.connect(receive_error)
	realtime.connection_changed.connect(connection_changed)
	for index in range(2):
		banks.append(Actions.bank("hero_male"))
		var hero := Sprite2D.new()
		hero.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		hero.position = Vector2(520 if index == 0 else 920, 570)
		add_child(hero)
		heroes.append(hero)
		var label: Label = ui.label_into(self, "", 17, Color("fff0ce"))
		label.size = Vector2(220, 28)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_outline_color", Color("302820"))
		label.add_theme_constant_override("outline_size", 5)
		name_labels.append(label)
	build_hud()
	var touch := get_node_or_null("/root/TouchControls")
	if touch != null:
		touch.bind_battle(self)
		touch.controls_toggled.connect(update_touch)
		update_touch(touch.controls_enabled())
	join()

func build_hud() -> void:
	for index in range(2):
		var card: VBoxContainer = ui.card(Rect2(24 if index == 0 else 966, 22, 450, 145), self, Color("342922"))
		card.get_parent().z_index = 10
		health_labels.append(ui.label_into(card, "", 21, Color("f4d89d")))
		var bar := ProgressBar.new()
		bar.max_value = 100
		bar.show_percentage = false
		bar.custom_minimum_size.y = 19
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color("6eadc2") if index == 0 else Color("d79373")
		bar.add_theme_stylebox_override("fill", fill)
		card.add_child(bar)
		bars.append(bar)
		resource_labels.append(ui.label_into(card, "", 18, Color("eadfc5")))
	heading = ui.label_into(self, "论剑台 · 实时对战", 25, Color("f8dfa9"))
	heading.position = Vector2(475, 30)
	heading.size = Vector2(490, 45)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_color_override("font_outline_color", Color("302820"))
	heading.add_theme_constant_override("outline_size", 5)
	exit_button = ui.button(self, "退出擂台", request_leave)
	exit_button.position = Vector2(615, 105)
	exit_button.size = Vector2(210, 48)
	exit_button.z_index = 10
	if ui.has_method("open_settings"):
		settings_button = ui.button(self, "设置", ui.open_settings)
		settings_button.position = Vector2(835, 105)
		settings_button.size = Vector2(120, 48)
		settings_button.z_index = 10
	banner = ui.label_into(self, "正在连接擂台…", 32, Color("ffe3a3"))
	banner.position = Vector2(270, 214)
	banner.size = Vector2(900, 60)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_color_override("font_outline_color", Color("302820"))
	banner.add_theme_constant_override("outline_size", 7)
	for index in range(5):
		var action := index
		var button: Button = ui.button(self, ACTION_NAMES[index], func(): queue_action(action + 1), index == 0)
		button.position = Vector2(25 + index * 282, 781)
		button.size = Vector2(267, 68)
		button.z_index = 10
		action_buttons.append(button)
	keyboard_hint = ui.label_into(self, "WASD 移动 · 面向移动方向出招 · 1 剑诀 · 2 / 空格 踏云 · 3 / K 护盾 · 4 / R 归元 · Esc 退出", 18, Color("fff1cc"))
	keyboard_hint.position = Vector2(55, 862)
	keyboard_hint.add_theme_color_override("font_outline_color", Color("302820"))
	keyboard_hint.add_theme_constant_override("outline_size", 4)

func update_touch(enabled: bool) -> void:
	for button in action_buttons:
		button.visible = not enabled
	keyboard_hint.visible = not enabled
	exit_button.position.y = 95 if enabled else 105
	exit_button.size.y = 104 if enabled else 48
	exit_button.add_theme_font_size_override("font_size", 28 if enabled else 17)
	if is_instance_valid(settings_button):
		settings_button.position.y = exit_button.position.y
		settings_button.size = Vector2(130 if enabled else 120, exit_button.size.y)
		settings_button.add_theme_font_size_override("font_size", 28 if enabled else 17)
	banner.position.y = 245 if enabled else 214

func join() -> void:
	sequence = 0
	realtime.send_duel({"type": "duel_join", "match_id": match_id})

func connection_changed(status: String) -> void:
	if ready_to_close:
		return
	if status == "connected":
		join()
	elif status == "unauthorized":
		ready_to_close = true
		banner.text = "会话已过期，请重新登录"
		exit_button.text = "返回论剑台"
	else:
		feedback.suspend()
		banner.text = "连接中断，正在重连…"

func receive_error(id: String, _code: String, message: String) -> void:
	if id != match_id:
		return
	ready_to_close = true
	banner.text = message
	exit_button.text = "返回论剑台"

func receive_state(snapshot: Dictionary) -> void:
	if snapshot.get("match_id") != match_id or not snapshot.get("players") is Array or snapshot.players.size() != 2:
		return
	var tick := int(snapshot.get("tick", -1))
	# A persisted final result can be reconstructed with tick zero after its room
	# is reclaimed. The immutable result must still close a reconnecting view.
	if tick < last_tick and not snapshot.get("result") is Dictionary:
		return
	last_tick = maxi(last_tick, tick)
	last_packet_ms = Time.get_ticks_msec()
	state = snapshot
	feedback.observe(snapshot, true)
	seat = int(state.seat)
	sequence = maxi(sequence, int(state.players[seat].get("ack", 0)))
	for index in range(2):
		var player: Dictionary = state.players[index]
		var avatar: String = str(state.avatars[index])
		banks[index] = Actions.bank("hero_" + avatar)
		var name_text: String = str(state.names[index]) + (" · 你" if index == seat else "")
		health_labels[index].text = "%s  生命 %d / 100" % [name_text, player.hp]
		bars[index].value = player.hp
		resource_labels[index].text = "灵力 %d / 100    体力 %d / 100" % [player.mp, player.stamina]
		name_labels[index].text = name_text
	heading.text = ("匹配擂台" if state.get("mode") == "ranked" else "好友切磋") + " · %d 秒" % int(state.seconds)
	banner.text = {
		"waiting": "等待双方入场", "countdown": "准备开战 · %d" % int(state.seconds),
		"fighting": "", "reconnecting": "等待同道重连 · %d 秒" % int(state.seconds), "finished": "",
	}.get(state.phase, "连接擂台…")
	exit_button.text = "认输 / 退出" if state.phase in ["fighting", "reconnecting"] else "退出擂台"
	if state.get("result") is Dictionary:
		show_result()
	for index in range(5):
		action_buttons[index].disabled = not action_available(index + 1)
		var cooldown := float(state.players[seat].cd[index + 1]) * 0.04
		action_buttons[index].text = ACTION_NAMES[index] + (" · %.1f 秒" % cooldown if cooldown > 0 else "")
	queue_redraw()

func _process(delta: float) -> void:
	animation_clock += delta
	if not state.is_empty():
		for index in range(2):
			var player: Dictionary = state.players[index]
			var hero := heroes[index]
			hero.position = hero.position.lerp(Vector2(player.x, player.y), 1.0 - exp(-delta * 23))
			hero.flip_h = float(player.fx) < -0.1
			hero.z_index = 2 if hero.position.y > heroes[1 - index].position.y else 1
			hero.modulate = Color(1.25, 0.7, 0.6) if player.hit and not feedback.option("reduced_flash", false) else Color.WHITE
			var pose := 15
			match str(player.pose):
				"walk": pose = int(animation_clock * 9) % 4
				"attack": pose = 4 + int(animation_clock * 12) % 4
				"sword", "guard", "heal": pose = 8 + int(animation_clock * 9) % 4
				"dash": pose = 12 + int(animation_clock * 12) % 2
			if not banks[index].is_empty():
				Actions.apply(hero, banks[index], pose, 148)
			name_labels[index].position = hero.position + Vector2(-110, -185)
	if battle_input_live():
		if options_open():
			pending_action = 0
		elif Input.is_physical_key_pressed(KEY_J) and action_available(1) and pending_action == 0:
			pending_action = 1
		send_clock += delta
		if send_clock >= 0.06:
			send_clock = 0
			var direction := Vector2.ZERO if options_open() else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
			sequence += 1
			if realtime.send_duel({"type": "duel_input", "match_id": match_id, "seq": sequence, "x": direction.x, "y": direction.y, "action": pending_action}):
				pending_action = 0
	elif not ready_to_close and last_packet_ms > 0 and Time.get_ticks_msec() - last_packet_ms > 2500:
		banner.text = "正在等待擂台连接…"
	queue_redraw()

func action_available(action: int) -> bool:
	if not touch_actions_active():
		return false
	var player: Dictionary = state.players[seat]
	if float(player.cd[action]) > 0:
		return false
	return (action != 2 or player.mp >= 18) and (action != 3 or player.stamina >= 24) and (action != 4 or player.mp >= 24) and (action != 5 or player.mp >= 40)

func battle_input_live() -> bool:
	return not leaving and not ready_to_close and not state.is_empty() and state.phase == "fighting" and Time.get_ticks_msec() - last_packet_ms < 1000

func options_open() -> bool:
	if not is_inside_tree():
		return false
	var options := get_node_or_null("/root/GameOptions")
	return options != null and options.settings_open

func touch_actions_active() -> bool:
	return battle_input_live() and not options_open()

func battle_action_state() -> Array:
	var result: Array = []
	for index in range(5):
		var action: int = TOUCH_ORDER[index]
		var cd: float = 0 if state.is_empty() else float(state.players[seat].cd[action]) * 0.04
		result.append({"label": ["", "普攻", "剑诀", "踏云", "护体", "归元"][action], "disabled": not action_available(action), "cooldown": cd})
	return result

func perform_action(index: int) -> void:
	if index >= 0 and index < TOUCH_ORDER.size():
		queue_action(TOUCH_ORDER[index])

func queue_action(action: int) -> void:
	if action_available(action):
		pending_action = action

func _input(event: InputEvent) -> void:
	if options_open():
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ESCAPE: request_leave()
		KEY_J: queue_action(1)
		KEY_1, KEY_Q: queue_action(2)
		KEY_2, KEY_SPACE: queue_action(3)
		KEY_3, KEY_K: queue_action(4)
		KEY_4, KEY_R: queue_action(5)
		_: return
	get_viewport().set_input_as_handled()

func _draw() -> void:
	draw_texture_rect(Assets.texture("res://assets/pixel_campaign/map_metal.png"), Rect2(0, 0, 1440, 900), false)
	draw_rect(Rect2(220, 390, 1000, 325), Color(0.1, 0.6, 0.72, 0.55), false, 2)
	if state.is_empty():
		return
	for index in range(2):
		var player: Dictionary = state.players[index]
		var point := heroes[index].position
		draw_ellipse_shadow(point)
		if player.shield > 0:
			draw_arc(point + Vector2(0, -63), 72, 0, TAU, 48, Color(0.45, 0.9, 1, 0.75), 3)
		if player.dash:
			draw_line(point - Vector2(player.fx, 0) * 85 + Vector2(0, -35), point + Vector2(0, -35), Color(0.7, 0.95, 1, 0.5), 7)
	for blade in state.get("blades", []):
		var direction := Vector2(blade.fx, blade.fy)
		var point := Vector2(blade.x, blade.y - 45)
		draw_line(point - direction * 45, point + direction * 25, Color(0.65, 0.9, 1, 0.35), 18)
		draw_line(point - direction * 35, point + direction * 25, Color("e8fbff"), 4)

func draw_ellipse_shadow(point: Vector2) -> void:
	var shape := PackedVector2Array()
	for index in range(20):
		var angle := index * TAU / 20
		shape.append(point + Vector2(cos(angle) * 35, sin(angle) * 11))
	draw_colored_polygon(shape, Color(0.12, 0.13, 0.15, 0.4))

func show_result() -> void:
	ready_to_close = true
	pending_action = 0
	exit_button.text = "返回论剑台"
	if is_instance_valid(leave_dialog):
		leave_dialog.queue_free()
	if is_instance_valid(result_panel):
		return
	var data: Dictionary = state.result.merged({"seat": seat})
	var column: VBoxContainer = ui.card(Rect2(450, 270, 540, 315), self, Color("342922"))
	result_panel = column.get_parent()
	result_panel.z_index = 20
	ui.label_into(column, Lobby.result_text(data), 36, Color("f6d599")).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui.paragraph(column, str(Lobby.END_REASONS.get(data.reason, "本场结束")), 21, Color("f5e4c3"))
	ui.paragraph(column, "双方生命 %d / %d" % [int(state.players[seat].hp), int(state.players[1 - seat].hp)], 19, Color("f5e4c3"))
	if state.get("mode") == "ranked":
		var change: Variant = state.get("rating_change")
		if change is Dictionary:
			ui.paragraph(column, "论剑积分 %d → %d  (%+d)" % [int(change.before), int(change.after), int(change.delta)], 23, Color("f6d599"))
	ui.button(column, "返回论剑台", request_leave, true)

func can_close() -> bool:
	return ready_to_close

func return_to_lobby() -> void:
	if state.get("mode") == "ranked":
		ui.open_matchmaking_lobby()
	else:
		ui.open_duel_lobby()

func request_leave() -> void:
	if ready_to_close:
		return_to_lobby()
		return
	if is_instance_valid(leave_dialog):
		return
	leave_dialog = ConfirmationDialog.new()
	leave_dialog.title = "退出论剑"
	leave_dialog.dialog_text = "开战后退出会判为认输。确认离开擂台？"
	leave_dialog.ok_button_text = "确认退出"
	leave_dialog.cancel_button_text = "继续切磋"
	add_child(leave_dialog)
	leave_dialog.confirmed.connect(func(): leave_dialog.queue_free(); leave())
	leave_dialog.canceled.connect(leave_dialog.queue_free)
	leave_dialog.popup_centered()

func leave() -> void:
	if leaving:
		return
	leaving = true
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("combat.duel_leave", {"cultivator_id": cultivator_id, "match_id": match_id})
	if not result.ok:
		leaving = false
		banner.text = result.message
		return
	ready_to_close = true
	return_to_lobby()

func _exit_tree() -> void:
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.leave_battle(self)
	if is_instance_valid(realtime):
		realtime.send_duel({"type": "duel_exit", "match_id": match_id})
	var touch := get_node_or_null("/root/TouchControls")
	if touch != null:
		touch.unbind_battle(self)
