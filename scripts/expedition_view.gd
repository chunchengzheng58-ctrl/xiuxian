extends Control

const Assets = preload("res://scripts/pixel_assets.gd")
const Actions = preload("res://scripts/systems/combat/action_atlas.gd")
const Catalogue = preload("res://scripts/trial_catalogue.gd")
const Equipment = preload("res://scripts/equipment_rules.gd")
const Adventure = preload("res://scripts/adventure_catalogue.gd")
const Feedback = preload("res://scripts/battle_feedback.gd")
const StoryScenePlayer = preload("res://scripts/story_scene_player.gd")
const StoryProp = preload("res://scripts/story_prop.gd")
const STORY_BOSSES = ["b00", "b03", "b12", "b15", "b19"]
const ACTION_NAMES = ["普攻 [J]", "听风剑诀 [1]", "踏云步 [2]", "云罡护体 [3]", "饕餮归元 [4]"]
const ACTION_HELP = ["靠近敌人连续普攻；命中可恢复灵力。", "消耗灵力造成伤害；普攻回灵后再用。", "消耗体力闪避红色预警区域。", "消耗灵力抵挡攻击，适合躲不开时使用。", "消耗灵力恢复生命；受伤后再用。"]
const TOUCH_ORDER = [1, 2, 4, 3, 5]
const END_REASONS = {"knockout": "本场战斗结束", "time": "探索时间已到", "disconnect": "连接中断超时", "absent": "入场等待超时", "withdrawn": "已离开秘境", "forfeit": "已退出挑战", "interrupted": "服务中断，本场未结算奖励", "unavailable": "角色状态已变化"}
const TACTICS = {
	"b01": "落木锁定脚下，横梁横扫整行。看清红色预警，向上下方移开后反击。",
	"b02": "沿线冲撞与齿轮阵交替发动。避开冲撞路线，向齿轮阵两侧闪避。",
	"b03": "根阵夹击上下两侧，吸灵线命中会为木心回血。绕开预警，把握收招时机。",
}
var game: Node
var ui: Control
var run_id: String
var cultivator_id: String
var state: Dictionary = {}
var realtime: Node
var hero: Sprite2D
var boss: Sprite2D
var hero_bank: Dictionary
var boss_bank: Dictionary = {}
var entry: Dictionary = {}
var heading: Label
var banner: Label
var mechanic_hint: Label
var health_labels: Array[Label] = []
var bars: Array[ProgressBar] = []
var resource_labels: Array[Label] = []
var action_buttons: Array[Button] = []
var keyboard_hint: Label
var exit_button: Button
var settings_button: Button
var result_panel: Control
var leave_dialog: ConfirmationDialog
var sequence := 0
var pending_action := 0
var last_tick := -1
var last_packet_ms := 0
var send_clock := 0.0
var animation_clock := 0.0
var ready_to_close := false
var leaving := false
var effects_layer: Control
var feedback: Node2D
var bark_label: Label
var story_prop: Control
var prop_tween: Tween
var bark_tween: Tween
var entrance_played := false
var low_hp_played := false
var last_boss_stage := -1
var story_data: Dictionary = {}
var scene_player: Control
var resolution_loading := false
var resolution_played := false

class ArenaEffects extends Control:
	var view: Control
	func _draw() -> void:
		draw_set_transform(-position)
		view.draw_effects(self)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	feedback = Feedback.new()
	add_child(feedback)
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.enter_battle(self)
	effects_layer = ArenaEffects.new()
	effects_layer.view = self
	effects_layer.position = Vector2(220, 390)
	effects_layer.size = Vector2(1000, 325)
	effects_layer.clip_contents = true
	effects_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(effects_layer)
	realtime = game.account_api.realtime
	realtime.expedition_state_received.connect(receive_state)
	realtime.expedition_error_received.connect(receive_error)
	realtime.connection_changed.connect(connection_changed)
	hero_bank = Actions.bank("hero_" + ("female" if game.state.avatar_id == "female" else "male"))
	hero = Sprite2D.new()
	hero.position = Vector2(520, 570)
	add_child(hero)
	boss = Sprite2D.new()
	boss.position = Vector2(980, 570)
	add_child(boss)
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
		health_labels.append(ui.label_into(card, "等待入场…", 21, Color("f4d89d")))
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size.y = 19
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color("6eadc2") if index == 0 else Color("d79373")
		bar.add_theme_stylebox_override("fill", fill)
		card.add_child(bar)
		bars.append(bar)
		resource_labels.append(ui.label_into(card, "", 18, Color("eadfc5")))
	heading = ui.label_into(self, "五域秘境", 26, Color("f8dfa9"))
	heading.position = Vector2(475, 30)
	heading.size = Vector2(490, 45)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outline(heading)
	exit_button = ui.button(self, "离开秘境", request_leave)
	exit_button.position = Vector2(615, 105)
	exit_button.size = Vector2(210, 48)
	exit_button.z_index = 10
	if ui.has_method("open_settings"):
		settings_button = ui.button(self, "设置", ui.open_settings)
		settings_button.position = Vector2(835, 105)
		settings_button.size = Vector2(120, 48)
		settings_button.z_index = 10
	mechanic_hint = ui.label_into(self, "红色区域即将受到攻击，及时移动或踏云闪避", 20, Color("fff0ce"))
	mechanic_hint.position = Vector2(85, 177)
	mechanic_hint.size = Vector2(1270, 34)
	mechanic_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mechanic_hint.clip_text = true
	outline(mechanic_hint)
	banner = ui.label_into(self, "正在连接秘境…", 31, Color("ffe3a3"))
	banner.position = Vector2(270, 226)
	banner.size = Vector2(900, 60)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outline(banner)
	bark_label = ui.label_into(self, "", 21, Color("e8c6a5"))
	bark_label.position = Vector2(405, 306)
	bark_label.size = Vector2(630, 47)
	bark_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bark_label.z_index = 12
	bark_label.visible = false
	outline(bark_label)
	story_prop = StoryProp.new()
	story_prop.position = Vector2(1145, 224)
	story_prop.size = Vector2(190, 120)
	story_prop.backdrop = false
	story_prop.z_index = 8
	story_prop.visible = false
	add_child(story_prop)
	for index in range(5):
		var action := index + 1
		var button: Button = ui.button(self, ACTION_NAMES[index], queue_action.bind(action), index == 0)
		button.position = Vector2(25 + index * 282, 781)
		button.size = Vector2(267, 68)
		button.z_index = 10
		button.tooltip_text = ACTION_HELP[index]
		action_buttons.append(button)
	keyboard_hint = ui.label_into(self, "WASD 移动 · J 连续普攻回灵 → 1 剑诀输出 · 红圈用 2/空格 闪避 · 3/K 护体 · 4/R 归元", 18, Color("fff1cc"))
	keyboard_hint.position = Vector2(95, 862)
	outline(keyboard_hint)

func outline(label: Label) -> void:
	label.add_theme_color_override("font_outline_color", Color("302820"))
	label.add_theme_constant_override("outline_size", 5)

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
	mechanic_hint.position.y = 208 if enabled else 177
	banner.position.y = 245 if enabled else 226

func join() -> void:
	sequence = 0
	realtime.send_expedition({"type": "expedition_join", "run_id": run_id})

func connection_changed(status: String) -> void:
	if ready_to_close:
		return
	if status == "connected":
		join()
	elif status == "unauthorized":
		ready_to_close = true
		banner.text = "会话已过期，请重新登录"
		exit_button.text = "返回秘境"
	else:
		feedback.suspend()
		banner.text = "连接中断，正在重连…"

func receive_error(id: String, _code: String, message: String) -> void:
	if id != run_id:
		return
	ready_to_close = true
	banner.text = message
	exit_button.text = "返回秘境"

func receive_state(snapshot: Dictionary) -> void:
	if snapshot.get("run_id") != run_id or not snapshot.get("player") is Dictionary or not snapshot.get("enemy") is Dictionary:
		return
	var tick := int(snapshot.get("tick", -1))
	if tick < last_tick and not snapshot.get("result") is Dictionary:
		return
	last_tick = maxi(last_tick, tick)
	last_packet_ms = Time.get_ticks_msec()
	state = snapshot
	feedback.observe(snapshot)
	sequence = maxi(sequence, int(state.player.get("ack", 0)))
	if entry.get("id") != state.boss_id:
		entry = Catalogue.entry(str(state.boss_id))
		boss_bank = Actions.bank(str(state.boss_id))
	var player: Dictionary = state.player
	var enemy: Dictionary = state.enemy
	health_labels[0].text = "%s  生命 %d / %d" % [game.state.player_name, player.hp, player.max_hp]
	health_labels[1].text = "%s  生命 %d / %d" % [str(entry.get("name", "守关者")), enemy.hp, enemy.max_hp]
	for index in range(2):
		var fighter: Dictionary = player if index == 0 else enemy
		bars[index].max_value = fighter.max_hp
		bars[index].value = fighter.hp
	resource_labels[0].text = "灵力 %d / %d    体力 %d / %d" % [player.mp, player.max_mp, player.stamina, player.max_stamina]
	var statuses := status_text(player.get("statuses", []))
	if not statuses.is_empty():
		resource_labels[0].text += " · " + statuses
	resource_labels[1].text = str(entry.get("subtitle", "守关者"))
	var stage := Adventure.stage(str(state.boss_id))
	var region := str(stage.get("region", "五域"))
	heading.text = "%s秘境 · %d 秒" % [region + "域" if region in ["木", "火", "土", "金", "水"] else region, int(state.seconds)]
	var mechanic: Dictionary = state.get("mechanic", {})
	if not mechanic.is_empty():
		var phase := str({"seek": "游走", "windup": "蓄势", "attack": "出招", "recovery": "收招"}.get(mechanic.get("phase", ""), ""))
		mechanic_hint.text = "第%d阶段 · %s · %s" % [int(mechanic.get("stage", 0)) + 1, phase, str(mechanic.get("label", mechanic.get("name", "")))]
	else:
		mechanic_hint.text = str(stage.get("tactics", TACTICS.get(state.boss_id, "红色区域即将受到攻击，及时移动或踏云闪避")))
	mechanic_hint.tooltip_text = mechanic_hint.text
	update_story_performance(mechanic)
	banner.text = {"waiting": "准备入场", "countdown": "准备开战 · %d" % int(state.seconds), "fighting": "", "reconnecting": "等待重连 · %d 秒" % int(state.seconds), "finished": ""}.get(state.phase, "连接秘境…")
	exit_button.text = "退出挑战" if state.phase in ["fighting", "reconnecting"] else "离开秘境"
	if state.get("result") is Dictionary:
		show_result()
	for index in range(5):
		action_buttons[index].disabled = not action_available(index + 1)
		var cooldown := float(player.cd[index + 1]) * 0.04
		action_buttons[index].text = ACTION_NAMES[index] + (" · %.1f 秒" % cooldown if cooldown > 0 else "")
	queue_redraw()

func update_story_performance(mechanic: Dictionary) -> void:
	if str(state.get("boss_id", "")) not in STORY_BOSSES:
		return
	var presentation: Dictionary = state.get("presentation", {})
	var barks: Dictionary = presentation.get("barks", {})
	if state.get("phase") == "fighting" and not entrance_played:
		entrance_played = true
		show_bark(str(barks.get("entry", "")))
		var entrance: Dictionary = presentation.get("entrance", {})
		show_story_prop(str(entrance.get("style", "lamp")))
	if state.get("phase") != "fighting":
		return
	var boss_stage := int(mechanic.get("stage", 0))
	if last_boss_stage < 0:
		last_boss_stage = boss_stage
	elif boss_stage != last_boss_stage:
		last_boss_stage = boss_stage
		show_bark(str(barks.get("phase", "")))
	var enemy: Dictionary = state.get("enemy", {})
	if not low_hp_played and float(enemy.get("max_hp", 1)) > 0 and float(enemy.get("hp", 1)) / float(enemy.get("max_hp", 1)) < 0.35:
		low_hp_played = true
		show_bark(str(barks.get("low_hp", "")))

func show_bark(text: String) -> void:
	if text.is_empty():
		return
	if bark_tween and bark_tween.is_valid():
		bark_tween.kill()
	bark_label.text = str(entry.get("name", "守关者")) + " · " + text
	bark_label.visible = true
	bark_label.modulate.a = 0.0
	bark_tween = create_tween()
	bark_tween.tween_property(bark_label, "modulate:a", 1.0, 0.14)
	bark_tween.tween_interval(1.55)
	bark_tween.tween_property(bark_label, "modulate:a", 0.0, 0.35)
	bark_tween.tween_callback(func(): bark_label.visible = false)

func show_story_prop(style: String) -> void:
	if prop_tween and prop_tween.is_valid():
		prop_tween.kill()
	story_prop.art = style
	story_prop.stage_id = str(state.get("boss_id", ""))
	story_prop.visible = true
	story_prop.modulate.a = 0.0
	prop_tween = create_tween()
	prop_tween.tween_property(story_prop, "modulate:a", 0.78, 0.2)
	prop_tween.tween_interval(1.6)
	prop_tween.tween_property(story_prop, "modulate:a", 0.0, 0.35)
	prop_tween.tween_callback(func(): story_prop.visible = false)

func _process(delta: float) -> void:
	animation_clock += delta
	effects_layer.queue_redraw()
	if not state.is_empty():
		animate_fighter(hero, hero_bank, state.player, 148, delta)
		var height: float = 170 if state.boss_id == "b02" else 255
		animate_fighter(boss, boss_bank, state.enemy, height, delta)
		hero.z_index = 2 if hero.position.y > boss.position.y else 1
		boss.z_index = 3 - hero.z_index
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
			if realtime.send_expedition({"type": "expedition_input", "run_id": run_id, "seq": sequence, "x": direction.x, "y": direction.y, "action": pending_action}):
				pending_action = 0
	elif not ready_to_close and last_packet_ms > 0 and Time.get_ticks_msec() - last_packet_ms > 2500:
		banner.text = "正在等待秘境连接…"
	queue_redraw()

func animate_fighter(sprite: Sprite2D, bank: Dictionary, fighter: Dictionary, height: float, delta: float) -> void:
	sprite.position = sprite.position.lerp(Vector2(fighter.x, fighter.y), 1.0 - exp(-delta * 23))
	sprite.flip_h = float(fighter.fx) < -0.1
	sprite.modulate = Color(1.3, 0.7, 0.6) if fighter.get("hit", false) and not feedback.option("reduced_flash", false) else Color.WHITE
	var pose := 0
	match str(fighter.get("pose", "idle")):
		"walk": pose = int(animation_clock * 9) % 4
		"attack": pose = 4 + int(animation_clock * 12) % 4
		"sword", "guard", "heal", "windup", "cast": pose = 8 + int(animation_clock * 9) % 4
		"dash", "charge": pose = 12 + int(animation_clock * 12) % 2
		"defeated", "dead": pose = 15
	if not bank.is_empty():
		Actions.apply(sprite, bank, pose, height)

func battle_input_live() -> bool:
	return not leaving and not ready_to_close and not state.is_empty() and state.phase == "fighting" and Time.get_ticks_msec() - last_packet_ms < 1000

func options_open() -> bool:
	if not is_inside_tree():
		return false
	var options := get_node_or_null("/root/GameOptions")
	return options != null and options.settings_open

func touch_actions_active() -> bool:
	return battle_input_live() and not options_open()

func action_available(action: int) -> bool:
	if not touch_actions_active():
		return false
	var player: Dictionary = state.player
	if float(player.cd[action]) > 0:
		return false
	return (action != 2 or player.mp >= 18) and (action != 3 or player.stamina >= 24) and (action != 4 or player.mp >= 24) and (action != 5 or player.mp >= 40)

func battle_action_state() -> Array:
	var result: Array = []
	for action in TOUCH_ORDER:
		var cd: float = 0 if state.is_empty() else float(state.player.cd[action]) * 0.04
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
	var background: String = str(entry.get("background", "res://assets/pixel_campaign/map_wood.png"))
	draw_texture_rect(Assets.texture(background), Rect2(0, 0, 1440, 900), false)
	draw_rect(Rect2(220, 390, 1000, 325), Color(0.45, 0.83, 0.64, 0.65), false, 2)
	if state.is_empty():
		return
	for sprite in [hero, boss]:
		var shadow := PackedVector2Array()
		for index in range(20):
			var angle := index * TAU / 20
			shadow.append(sprite.position + Vector2(cos(angle) * 35, sin(angle) * 11))
		draw_colored_polygon(shadow, Color(0.12, 0.13, 0.15, 0.4))
	if state.player.get("shield", 0) > 0:
		draw_arc(hero.position + Vector2(0, -63), 72, 0, TAU, 48, Color(0.45, 0.9, 1, 0.8), 3)
	if state.player.get("dash", false):
		draw_line(hero.position - Vector2(state.player.fx, 0) * 85 + Vector2(0, -35), hero.position + Vector2(0, -35), Color(0.7, 0.95, 1, 0.5), 7)
	for blade in state.get("blades", []):
		var direction := Vector2(blade.fx, blade.fy)
		var point := Vector2(blade.x, blade.y - 45)
		draw_line(point - direction * 45, point + direction * 25, Color(0.65, 0.9, 1, 0.35), 18)
		draw_line(point - direction * 35, point + direction * 25, Color("e8fbff"), 4)

func draw_effects(canvas: CanvasItem) -> void:
	if state.is_empty():
		return
	for hazard in state.get("hazards", []):
		draw_zone(hazard, true, canvas)
	for telegraph in state.get("telegraphs", []):
		draw_zone(telegraph, false, canvas)
	for projectile in state.get("enemy_projectiles", []):
		var point := Vector2(float(projectile.x), float(projectile.y))
		var radius := float(projectile.get("radius", 8))
		var color := Color("ffbb68") if str(projectile.get("style", "")) in ["fire", "ember", "flame"] else Color("f5dbad")
		canvas.draw_circle(point, radius + 3, Color(color, 0.3))
		canvas.draw_circle(point, radius, color)
		canvas.draw_arc(point, radius, 0, TAU, 20, Color("ff725b"), 2)

func draw_zone(zone: Dictionary, active: bool, canvas: CanvasItem) -> void:
	var center := Vector2(float(zone.x), float(zone.y))
	var fill := Color(1, 0.22, 0.07, 0.4) if active else Color(0.95, 0.16, 0.1, 0.2)
	var edge := Color("ffd27a") if active else Color("ff5d53")
	if zone.kind == "polygon":
		for raw_polygon in zone.get("polygons", []):
			var polygon := PackedVector2Array()
			for point in raw_polygon:
				polygon.append(Vector2(float(point[0]), float(point[1])))
			if polygon.size() < 3:
				continue
			canvas.draw_colored_polygon(polygon, fill)
			var outline := polygon.duplicate()
			outline.append(polygon[0])
			canvas.draw_polyline(outline, edge, 2)
	elif zone.kind == "circle":
		var radius := float(zone.get("radius", 70))
		canvas.draw_circle(center, radius, fill)
		canvas.draw_arc(center, radius, 0, TAU, 64, edge, 3)
		if not active:
			var progress := clampf(1 - float(zone.get("remaining", 1)) / maxf(0.01, float(zone.get("total", 1))), 0, 1)
			canvas.draw_arc(center, radius - 5, -PI / 2, -PI / 2 + TAU * progress, 64, Color("ffe9b6"), 4)
	else:
		var end := Vector2(float(zone.get("x2", zone.x)), float(zone.get("y2", zone.y)))
		var width := float(zone.get("width", 60))
		var normal := (end - center).normalized().orthogonal() * width * 0.5
		var polygon := PackedVector2Array([center + normal, end + normal, end - normal, center - normal])
		canvas.draw_colored_polygon(polygon, fill)
		canvas.draw_circle(center, width * 0.5, fill)
		canvas.draw_circle(end, width * 0.5, fill)
		canvas.draw_arc(center, width * 0.5, 0, TAU, 32, edge, 2)
		canvas.draw_arc(end, width * 0.5, 0, TAU, 32, edge, 2)
		canvas.draw_polyline(PackedVector2Array([polygon[0], polygon[1], polygon[2], polygon[3], polygon[0]]), edge, 3)

func show_result() -> void:
	ready_to_close = true
	pending_action = 0
	exit_button.text = "返回秘境"
	if is_instance_valid(leave_dialog):
		leave_dialog.queue_free()
	if is_instance_valid(result_panel):
		return
	var result: Dictionary = state.result
	var column: VBoxContainer = ui.card(Rect2(390, 240, 660, 460), self, Color("342922"))
	result_panel = column.get_parent()
	result_panel.z_index = 20
	ui.label_into(column, "秘境通关" if result.won else "本次探索结束", 36, Color("f6d599")).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if result.won:
		var reward: Dictionary = result.reward
		ui.paragraph(column, "首次通关奖励" if reward.get("first_clear", false) else "再战奖励", 22, Color("f5e4c3"))
		ui.paragraph(column, "+%d 灵气    +%d 锻造材料" % [reward.spirit_stones, reward.materials], 25, Color("f6d599"))
		ui.paragraph(column, "+%d 历练 · 在主线页查看冒险等级与章节奖励" % int(reward.get("adventure_xp", 0)), 19, Color("f5e4c3"))
		var item: Variant = reward.get("equipment")
		if item is Dictionary:
			var info := Equipment.detail(item.merged({"id": str(item.get("equipment_id", ""))}))
			ui.paragraph(column, "获得装备：" + str(info.name), 21, info.color)
	else:
		ui.paragraph(column, str(END_REASONS.get(result.reason, "可以调整装备后再次挑战")), 22, Color("f5e4c3"))
		ui.paragraph(column, "可在锻造台强化装备、组合流派，再来挑战。", 20, Color("f5e4c3"))
	if result.won and str(state.get("boss_id", "")) in STORY_BOSSES:
		var barks: Dictionary = state.get("presentation", {}).get("barks", {})
		ui.paragraph(column, str(entry.get("name", "守关者")) + "：“" + str(barks.get("defeat", "……")) + "”", 20, Color("d9b69b"))
	ui.button(column, "战后 · 归途留言", load_resolution.bind(false))
	ui.button(column, "返回秘境", request_leave, true)
	ui.button(column, "查看本章剧情", func(): ui.open_story(str(Adventure.stage(str(state.boss_id)).get("chapter_id", ""))))
	ui.button(column, "前往锻造台", func(): ui.open_treasure("forge"))
	if result.won and result.get("reward", {}).get("first_clear", false):
		load_resolution.call_deferred(true)

func load_resolution(auto_play: bool) -> void:
	if resolution_loading or is_instance_valid(scene_player) or (auto_play and resolution_played):
		return
	resolution_loading = true
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("story.snapshot", {"cultivator_id": cultivator_id})
	resolution_loading = false
	if is_queued_for_deletion() or not result.ok:
		if not auto_play and not is_queued_for_deletion():
			ui.toast(str(result.get("message", "战后剧情读取失败")))
		return
	story_data = result.data
	var scene: Dictionary = {}
	for row in story_data.get("scenes", []):
		if str(row.get("stage_id", "")) == str(state.get("boss_id", "")) and row.get("kind") == "resolution":
			scene = row
			break
	if scene.is_empty() or not scene.get("replayable", false):
		return
	if auto_play and scene.get("completed", false):
		return
	resolution_played = true
	present_scene(scene, core)

func present_scene(scene: Dictionary, core: Node) -> void:
	var player := StoryScenePlayer.new()
	player.scene_data = scene.duplicate(true)
	player.kernel = core
	player.cultivator_id = cultivator_id
	player.variants = story_data.get("variants", {})
	player.persist_marker = not scene.get("completed", false)
	scene_player = player
	StoryScenePlayer.mount(player, get_tree().root)
	player.finished.connect(resolution_finished)

func load_home() -> void:
	if resolution_loading or is_instance_valid(scene_player):
		return
	resolution_loading = true
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("story.snapshot", {"cultivator_id": cultivator_id})
	resolution_loading = false
	if is_queued_for_deletion() or not result.ok:
		return
	story_data = result.data
	var home: Dictionary = story_data.get("home", {})
	var scene: Variant = home.get("scene")
	if home.get("available", false) and not home.get("completed", false) and scene is Dictionary:
		present_scene(scene, core)

func resolution_finished(scene_id: String, _skipped: bool, saved: bool) -> void:
	scene_player = null
	if not saved:
		ui.toast("回村标记未同步，可从主线章节重试。" if scene_id == "ending.home" else "战后标记未同步，可点“归途留言”重试。")
	elif scene_id == "stage.b19.resolution":
		load_home()

static func status_text(statuses: Array) -> String:
	var parts: PackedStringArray = []
	for status in statuses:
		var name := str(status.get("name", status.get("kind", ""))) if status is Dictionary else str(status)
		var text := str({"slow": "缓行", "fatigue": "疲劳", "drain": "汲取", "push": "推离", "pull": "牵引", "silence": "封灵", "seal": "封诀", "launch": "击退"}.get(name, name))
		if not text.is_empty():
			parts.append(text)
	return " / ".join(parts)

func can_close() -> bool:
	return ready_to_close and not resolution_loading and not is_instance_valid(scene_player)

func request_leave() -> void:
	if resolution_loading or is_instance_valid(scene_player):
		return
	if ready_to_close:
		ui.open_expedition_lobby()
		return
	if is_instance_valid(leave_dialog):
		return
	leave_dialog = ConfirmationDialog.new()
	leave_dialog.title = "离开秘境"
	leave_dialog.dialog_text = "退出将结束本次挑战，本次不获得通关奖励。确认离开？"
	leave_dialog.ok_button_text = "离开秘境"
	leave_dialog.cancel_button_text = "继续挑战"
	add_child(leave_dialog)
	leave_dialog.confirmed.connect(func(): leave_dialog.queue_free(); leave())
	leave_dialog.canceled.connect(leave_dialog.queue_free)
	leave_dialog.popup_centered()

func leave() -> void:
	if leaving:
		return
	leaving = true
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("combat.expedition_leave", {"cultivator_id": cultivator_id, "run_id": run_id})
	if not result.ok:
		leaving = false
		banner.text = result.message
		return
	ready_to_close = true
	ui.open_expedition_lobby()

func _exit_tree() -> void:
	if is_instance_valid(scene_player):
		scene_player.queue_free()
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.leave_battle(self)
	if is_instance_valid(realtime):
		realtime.send_expedition({"type": "expedition_exit", "run_id": run_id})
	var touch := get_node_or_null("/root/TouchControls")
	if touch != null:
		touch.unbind_battle(self)
