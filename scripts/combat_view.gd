extends Control

const Catalogue = preload("res://scripts/trial_catalogue.gd")
const Atmosphere = preload("res://scripts/arena_atmosphere.gd")
const Assets = preload("res://scripts/pixel_assets.gd")
const Actions = preload("res://scripts/systems/combat/action_atlas.gd")
const BossRules = preload("res://scripts/boss_rules.gd")
const Effects = preload("res://scripts/combat_effects.gd")
const SKILL_NAMES = ["听风剑诀", "踏云步", "云罡护体", "饕餮归元"]
const HIT_BURST_TIME := 0.40
const SAP_FLOW_TIME := 0.62
const SAP_PULSE_TIME := 0.26
const SPLIT_BURST_TIME := 0.70
const LANDING_FLASH_TIME := 0.42
@export var boss_id: String = ""
var encounter: Dictionary = {}
var boss_anchor = Vector2(1130, 510)
var boss_height: float = 410
## The main village is Node2D; the standalone demo hub is Control. Both expose
## the same state/asset facade, so the view only needs a Node here.
var game: Node
var ui: Control
var mode: String = "boss"
var support: int = 0
var entered_state: RefCounted
var wearable_effects: Dictionary = {}
var rules: RefCounted
var hero_outline: Sprite2D
var hero: Sprite2D
var dragon: Sprite2D
var dragon_frames: Array[Texture2D] = []
var world: Node2D
var poise_bar: ProgressBar
var poise_label: Label
var perfect_visual: float = 0
var counter_visual: float = 0
var phase_flash: float = 0
var slash_combo: int = 0
var boss_bank: Dictionary = {}
var hero_bank: Dictionary = {}
var boss_frame_index: int = 0
var hero_frame_index: int = 15
var hero_hurt_visual: float = 0
var hero_moving: bool = false
var roll_remaining: float = 0
var roll_direction := Vector2.RIGHT
var hit_bursts: Array = []
var sap_flows: Array = []
var sap_pulse_visual := 0.0
var split_bursts: Array = []
var wind_visual := 0.0
var wind_effect := ""
var landing_visual := 0.0
var landing_position := Vector2.ZERO
var enemy_intent: Label
var enemy_cast: ProgressBar
var hit_stop: float = 0
var shake: float = 0
var shake_strength: float = 0
var last_stage: int = 0
var boss_audio: AudioStreamPlayer
var clock: float = 0
var cast_visual: float = 0
var cast_duration: float = 0.5
var sword_visual: bool = false
var cast_origin = Vector2.ZERO
var cast_direction = Vector2.RIGHT
var dodge_origin = Vector2.ZERO
var dodge_visual: float = 0
var hurt_visual: float = 0
var boss_hurt_visual: float = 0.0
var boss_rage_visual: float = 0.0
var boss_recoil := Vector2.ZERO
var heal_visual: float = 0
var shield_impact: float = 0
var shield_break_visual: float = 0
var companion: RefCounted
var companion_sprite: Sprite2D
var companion_flash: float = 0.0
var paused: bool = false
var _add_sprites: Array[Sprite2D] = []
var result_shown: bool = false
var heal_was_unlocked: bool = false
var facing = Vector2.RIGHT
var skill_nodes: Array[Button] = []
var basic_button: Button
var ult_button: Button
var top_label: Label
var meter: ProgressBar
var player_status: Label
var vital_labels: Array[Label] = []
var vital_bars: Array[ProgressBar] = []
var impact_text: Label
var message: Label
var _skill_row: HBoxContainer
var _keyboard_tips: Label
var _touch_pause_button: Button
var combo_banner: Label
var flow_banner: Label
var finisher_visual: float = 0.0
var flow_visual: float = 0.0
var ultimate_visual: float = 0.0
var finisher_origin := Vector2.ZERO
var finisher_direction := Vector2.RIGHT
var _last_hitstreak: int = 0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	encounter = Catalogue.entry(boss_id) if boss_id != "" else {}
	entered_state = game.state
	if entered_state.is_remote() and mode != "practice":
		var response = await game.account_api.api.request_api("/api/v2/wearables/status", HTTPClient.METHOD_POST, {"cultivator_id": entered_state.cultivator_id})
		if not is_inside_tree() or game.state != entered_state:
			return
		if response.ok:
			wearable_effects = response.data.effects
	if entered_state.is_remote() and mode != "practice" and boss_id != "":
		_open_remote_session()
	rules = BossRules.new(entered_state, 0, game.state.selected_tier, game.state.selected_track, mode == "practice", encounter)
	rules.wearable_regeneration = float(wearable_effects.get("regeneration", 0))
	var resistance := 100.0 / float(rules.stats.damage_multiplier) - 100.0
	rules.stats.damage_multiplier = 100.0 / (100.0 + resistance * (1.0 + float(wearable_effects.get("defense", 0))))
	heal_was_unlocked = entered_state.heal_unlocked()
	var background = TextureRect.new()
	background.texture = Assets.texture(encounter.get("background", "res://assets/gameplay/boss-stage.png"))
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	world = Node2D.new()
	add_child(world)
	if not encounter.is_empty():
		var atmosphere = Node2D.new()
		atmosphere.set_script(Atmosphere)
		atmosphere.view = self
		world.add_child(atmosphere)
	var spawn = Vector2(625, 630) if encounter.is_empty() else Vector2(encounter.hero_spawn[0], encounter.hero_spawn[1])
	hero_bank = Actions.bank("hero_"+entered_state.avatar_id)
	hero = actor(game.walk_textures[8], spawn, 148)
	hero_outline = actor(game.walk_textures[8],spawn,148)
	hero_outline.z_index = 5
	var outline_material := ShaderMaterial.new()
	outline_material.shader = preload("res://assets/combat/hero_silhouette.gdshader")
	hero_outline.material = outline_material
	hero_outline.hide()
	if encounter.is_empty():
		dragon_frames = Assets.frames("res://assets/gameplay/dragon-states.png", 2, 2)
	else:
		boss_bank = Actions.bank(boss_id)
		dragon_frames = boss_bank.frames if not boss_bank.is_empty() else [Catalogue.boss_texture(boss_id)]
		boss_anchor = rules.boss_position
		boss_height = float(encounter.boss_height)
	dragon = actor(dragon_frames[0], boss_anchor, boss_height)
	var ground = Node2D.new()
	ground.set_script(Effects)
	ground.view = self
	ground.ground_only = true
	world.add_child(ground)
	boss_audio = AudioStreamPlayer.new()
	boss_audio.bus = "Effects"
	boss_audio.volume_db = -13
	add_child(boss_audio)
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.enter_battle(self)
	var effects = Node2D.new()
	effects.set_script(Effects)
	effects.view = self
	world.add_child(effects)
	effects.z_index = 4
	_build_hud()
	var touch := get_node_or_null("/root/TouchControls")
	if touch != null:
		touch.bind_battle(self)
		touch.controls_toggled.connect(_update_touch_hud)
		_update_touch_hud(touch.controls_enabled())
	for child in get_children():
		if child is Control and child != background:
			child.z_index = 10
	_hero_pose()
	_boss_pose(0)
	refresh()

func actor(texture: Texture2D, foot: Vector2, height: float) -> Sprite2D:
	var sprite = Sprite2D.new()
	sprite.texture = texture
	sprite.position = foot
	sprite.scale = Vector2.ONE * height / texture.get_height()
	sprite.offset.y = -texture.get_height() * 0.5
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	world.add_child(sprite)
	return sprite

func _bar(parent: Node, color: Color) -> ProgressBar:
	var bar = ProgressBar.new()
	bar.custom_minimum_size.y = 13
	bar.show_percentage = false
	var track = StyleBoxFlat.new()
	track.bg_color = Color("272b2d")
	track.set_border_width_all(1)
	track.border_color = Color("94794e")
	var fill = StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("background", track)
	bar.add_theme_stylebox_override("fill", fill)
	parent.add_child(bar)
	return bar

func _build_hud() -> void:
	var title = ui.card(Rect2(20, 18, 300, 84), self, Color("342922"))
	title.add_theme_constant_override("separation", 2)
	var name_label = ui.label_into(title, "松风四式 · " + ("演武练习" if mode == "practice" else "属性试炼"), 24, Color("f3d19a"))
	name_label.add_theme_font_override("font", game.title_font)
	var location: String = encounter.arena if not encounter.is_empty() else "%s线 / %d 档 / %s" % [entered_state.ATTRIBUTE_LABELS[rules.track], rules.tier, entered_state.realm()]
	var subtitle := str(encounter.get("subtitle", ""))
	if not subtitle.is_empty():
		location += " · " + subtitle
	ui.label_into(title, location, 16, Color("e2c89e"))
	var boss_card = ui.card(Rect2(336, 18, 856, 148), self, Color("342922"))
	boss_card.add_theme_constant_override("separation", 5)
	top_label = ui.label_into(boss_card, "", 19, Color("f8e5c2"))
	meter = _bar(boss_card, Color("b76075"))
	enemy_intent = ui.label_into(boss_card, "", 16, Color("f2ce91"))
	enemy_cast = _bar(boss_card, Color("e7b45f"))
	enemy_cast.custom_minimum_size.y = 5
	poise_label = ui.label_into(boss_card,"",14,Color("e5d29d"))
	poise_bar = _bar(boss_card,Color("d8b873"))
	poise_bar.custom_minimum_size.y = 6
	var leave = ui.button(self, "返回长廊 ×" if not encounter.is_empty() else "返回仙村 ×", leave_battle)
	leave.position = Vector2(1231, 20)
	leave.size.x = 185
	_touch_pause_button = ui.button(self, "暂停", _toggle_pause)
	_touch_pause_button.position = Vector2(1231, 80)
	_touch_pause_button.size.x = 185
	_touch_pause_button.hide()
	var status = ui.card(Rect2(20, 112, 300, 190), self, Color("342922"))
	status.add_theme_constant_override("separation", 7)
	ui.label_into(status, entered_state.player_name, 21, Color("f5ddb4"))
	for i in range(3):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		status.add_child(row)
		var label: Label = ui.label_into(row, "", 16, Color("f6e3c3"))
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.custom_minimum_size.x = 128
		vital_labels.append(label)
		var bar := _bar(row, [Color("bd6a63"), Color("63aebd"), Color("a4bc6c")][i])
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		vital_bars.append(bar)
	player_status = ui.label_into(status, "", 15, Color("dfcda9"))
	message = ui.label_into(self, str(encounter.get("tactics", "靠近目标普攻回灵；剑诀、护盾与归元共用灵力。")), 21, Color("fff0c6"))
	message.position = Vector2(330, 690)
	message.size = Vector2(1070, 38)
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.add_theme_color_override("font_outline_color", Color("2b2830"))
	message.add_theme_constant_override("outline_size", 6)
	impact_text = ui.label_into(self, "", 34, Color("c8f3d6"))
	impact_text.add_theme_color_override("font_outline_color", Color("3a2b2b"))
	impact_text.add_theme_constant_override("outline_size", 7)
	impact_text.hide()
	_skill_row = HBoxContainer.new()
	_skill_row.position = Vector2(25, 754)
	_skill_row.add_theme_constant_override("separation", 10)
	add_child(_skill_row)
	basic_button = ui.button(_skill_row, "普攻 [J]\n近身命中 · 灵力 +5", basic_attack)
	basic_button.tooltip_text = "靠近敌人连续普攻；命中恢复灵力，第三击完成一轮连招。"
	basic_button.custom_minimum_size = Vector2(210, 86)
	basic_button.add_theme_font_size_override("font_size", 16)
	for i in range(4):
		var choice = i
		var button = ui.button(_skill_row, "", func(): use_skill(choice), i == 0)
		button.custom_minimum_size = Vector2(220, 86)
		button.add_theme_font_size_override("font_size", 16)
		button.tooltip_text = ["听风剑诀：消耗灵力攻击，先普攻回灵再施放。", "踏云步：消耗体力闪避红色预警，精准闪避可充能。", "云罡护体：消耗灵力抵挡伤害，挡下攻击后可反击。", "饕餮归元：受伤后恢复生命并净化，首通两关解锁。"][i]
		skill_nodes.append(button)
	ult_button = ui.button(_skill_row, "赤霄剑域 [5/T]\n剑意 0%", use_ultimate)
	ult_button.custom_minimum_size = Vector2(240, 86)
	ult_button.add_theme_font_size_override("font_size", 16)
	_keyboard_tips = ui.label_into(self, "WASD 移动 · J 三段终结 · 命中后 1 行云 · 2/空格 踏云 · 3/K 护盾 · 4/R 归元 · 5/T 剑域 · P 暂停", 16, Color("fff0c6"))
	_keyboard_tips.position = Vector2(25, 858)
	_keyboard_tips.size.x = 1390
	_keyboard_tips.autowrap_mode = TextServer.AUTOWRAP_OFF
	_keyboard_tips.add_theme_color_override("font_outline_color", Color("29242e"))
	_keyboard_tips.add_theme_constant_override("outline_size", 5)
	# 连击与行云提示放在左侧空区，不遮挡 Boss 与弹道。
	combo_banner = ui.label_into(self, "", 44, Color("ffe3a0"))
	combo_banner.position = Vector2(28, 362)
	combo_banner.size = Vector2(320, 62)
	combo_banner.add_theme_font_override("font", game.title_font)
	combo_banner.add_theme_color_override("font_outline_color", Color("3a2a1c"))
	combo_banner.add_theme_constant_override("outline_size", 8)
	combo_banner.pivot_offset = Vector2(0, 31)
	combo_banner.hide()
	flow_banner = ui.label_into(self, "", 19, Color("b1fae7"))
	flow_banner.position = Vector2(30, 430)
	flow_banner.size = Vector2(340, 30)
	flow_banner.add_theme_color_override("font_outline_color", Color("20302c"))
	flow_banner.add_theme_constant_override("outline_size", 5)
	flow_banner.hide()

func _update_touch_hud(enabled: bool) -> void:
	_skill_row.visible = not enabled
	_keyboard_tips.visible = not enabled
	_touch_pause_button.visible = enabled and not rules.finished
	message.position = Vector2(336, 178) if enabled else Vector2(330, 690)
	message.size.x = 856 if enabled else 1070

func touch_actions_active() -> bool:
	return rules != null and not paused and not rules.finished and not _settings_open()

func battle_action_state() -> Array:
	# Match the mobile layout and reuse the desktop buttons' availability checks.
	var heal_hint := "" if entered_state.heal_unlocked() else "未解锁"
	var actions := [
		{"label": "普攻", "disabled": basic_button.disabled, "cooldown": rules.attack_cd},
		{"label": "剑诀", "disabled": skill_nodes[0].disabled, "cooldown": rules.sword_cd},
		{"label": "护盾", "disabled": skill_nodes[2].disabled, "cooldown": rules.shield_cd},
		{"label": "闪避", "disabled": skill_nodes[1].disabled, "cooldown": rules.dodge_cd},
		{"label": "归元", "disabled": skill_nodes[3].disabled, "cooldown": rules.heal_cd, "hint": heal_hint},
	]
	if rules.brain != null:
		actions.append({"label": "剑域", "disabled": ult_button.disabled, "cooldown": 0.0, "hint": "%d%%" % int(rules.ult_gauge)})
	return actions

func perform_action(action: int) -> void:
	if not touch_actions_active():
		return
	match action:
		0: basic_attack()
		1: use_skill(0)
		2: use_skill(2)
		3: use_skill(1)
		4: use_skill(3)
		5: use_ultimate()

func refresh() -> void:
	top_label.text = "%s  %d / %d    用时 %.1f 秒" % [rules.boss_name, rules.boss_hp, rules.boss_max_hp, rules.elapsed]
	if not encounter.is_empty():
		var add_name := "分身" if rules.brain != null and rules.brain.definition.has("wood_split_interval") else "散祟"
		top_label.text += " · 第%d阶段 · %s %d" % [rules.stage_index + 1, add_name, rules.active_adds()]
	meter.max_value = rules.boss_max_hp
	meter.value = rules.boss_hp
	if rules.brain != null:
		var brain: RefCounted = rules.brain
		var action: String = str(brain.move.get("name", "寻找进攻位置"))
		var state_names := {"waiting":"游走 / 追击", "windup":"蓄力", "attack":"出招", "breath":"收招 · 反击机会", "link":"连段未完 · 准备下一击", "stagger":"破势 · 输出窗口"}
		enemy_intent.text = "%s  ·  %s" % [state_names.get(rules.phase,"战斗结束"), action]
		if brain.combo_total>1 and rules.phase in ["windup","attack","link"]:
			enemy_intent.text += "  ·  连段 %d/%d" % [brain.combo_index+1,brain.combo_total]
		if rules.phase == "windup":
			enemy_intent.text += "  ·  %.1f 秒" % maxf(0, brain.phase_duration-brain.phase_clock)
		var signature_zones: Array = brain.signature_zones()
		var cast_progress: float = brain.progress()
		if not signature_zones.is_empty():
			var beat: Dictionary = signature_zones[0]
			enemy_intent.text += "  ·  第 %d/%d 段" % [beat.number, beat.total]
			var beat_label := str(beat.profile.get("label", ""))
			if not beat_label.is_empty():
				enemy_intent.text += " · " + beat_label
			if rules.phase == "attack":
				cast_progress = beat.progress
		enemy_cast.value = cast_progress * 100
		enemy_cast.visible = (rules.phase in ["windup", "breath", "stagger"] or not signature_zones.is_empty()) and not rules.finished
		poise_bar.max_value = rules.max_poise
		poise_bar.value = rules.poise
		poise_label.text = "第%d关 · 破势 %d/%d · 精准闪避 %d" % [rules.combat_rank,rules.poise,rules.max_poise,rules.perfect_dodges]
		poise_bar.show()
		poise_label.show()
	else:
		poise_bar.hide()
		poise_label.hide()
		enemy_intent.text = "观察起手与朝向 · 自主走位 · 收招时近身回灵"
		enemy_cast.hide()
	var current = [rules.hp, rules.mp, rules.stamina]
	var maximum = [rules.max_hp, rules.max_mp, rules.max_stamina]
	for i in range(3):
		vital_labels[i].text = "%s  %d / %d" % [["生命", "灵力", "体力"][i], current[i], maximum[i]]
		vital_bars[i].max_value = maximum[i]
		vital_bars[i].value = current[i]
	player_status.text = "云罡护盾 %d\n%s" % [rules.shield_hp, "吐纳 %.1f 秒 · 移动减速" % rules.heal_cast if rules.heal_cast > 0 else "本局资源 · 不扣健康属性"]
	var airborne: bool = rules.airborne_time > 0.0
	if airborne:
		player_status.text += "\n腾空 · 可施放护盾"
	elif rules.slow_time > 0.0:
		player_status.text += "\n迟滞 · 移速下降"
	if rules.brain != null:
		player_status.text += "\n剑意 %d / 100" % int(rules.ult_gauge)
		player_status.text += "\n" + ("反击就绪 %.1f 秒" % rules.counter_time if rules.counter_time>0 else "普攻连击 %d / 3" % rules.combo_step)
	basic_button.disabled = rules.finished or airborne or roll_remaining>0 or rules.ult_active or rules.attack_cd > 0 or rules.heal_cast > 0
	var cooldowns = [rules.sword_cd, rules.dodge_cd, rules.shield_cd, rules.heal_cd]
	var descriptions = ["18 灵力 · 行云 12 · 充能", "24 体力 · 精准闪避充能", "24 灵力 · 抵挡后反击", "45 灵力 · 恢复并净化"]
	for i in range(4):
		var unlocked = i != 3 or entered_state.heal_unlocked()
		var enough = rules.stamina >= BossRules.DODGE_COST if i == 1 else rules.mp >= [BossRules.SWORD_COST, 0, BossRules.SHIELD_COST, BossRules.HEAL_COST][i]
		var detail = descriptions[i]
		if not unlocked:
			detail = "首通两个不同关卡解锁"
		elif cooldowns[i] > 0:
			detail = "冷却 %.1f 秒" % cooldowns[i]
		elif not enough:
			detail = "体力不足 · 等待恢复" if i == 1 else "灵力不足 · 普攻回灵"
		if i == 3 and rules.heal_cast > 0:
			detail = "吐纳 %.1f 秒" % rules.heal_cast
		skill_nodes[i].text = SKILL_NAMES[i] + " [%d]\n" % (i + 1) + detail
		skill_nodes[i].disabled = not unlocked or (airborne and i != 2) or (roll_remaining>0 and i!=1) or rules.finished or rules.ult_active or rules.heal_cast > 0 or cooldowns[i] > 0 or not enough or (i == 3 and rules.hp == rules.max_hp)
	ult_button.visible = rules.brain != null
	var ult_detail := "剑意 %d%% · 三段斩" % int(rules.ult_gauge)
	if rules.ult_active:
		ult_detail = "剑域展开 · 可移动"
	elif rules.ult_gauge >= BossRules.ULT_MAX:
		ult_detail = "剑意已满 · 可释放"
	ult_button.text = "赤霄剑域 [5/T]\n" + ult_detail
	ult_button.disabled = rules.brain == null or rules.finished or airborne or roll_remaining > 0 or rules.ult_active or rules.heal_cast > 0 or not rules.pending_action.is_empty() or rules.ult_gauge < BossRules.ULT_MAX
	_refresh_combo_hud()

func _refresh_combo_hud() -> void:
	# 连击数字随命中弹跳，5 连击后转为更亮的金色，提示已有伤害加成。
	if rules.hitstreak >= 2 and not rules.finished:
		combo_banner.text = "%d 连击" % rules.hitstreak
		combo_banner.show()
		if rules.hitstreak != _last_hitstreak:
			combo_banner.scale = Vector2(1.25, 1.25)
			create_tween().tween_property(combo_banner, "scale", Vector2.ONE, 0.16)
		combo_banner.add_theme_color_override("font_color", Color("ffd27a") if rules.hitstreak >= 5 else Color("ffe3a0"))
	else:
		combo_banner.hide()
	_last_hitstreak = rules.hitstreak
	flow_banner.visible = rules.flow_time > 0.0 and not rules.finished
	if flow_banner.visible:
		flow_banner.text = "行云就绪 · 按 1 接剑气（%d 灵力）" % BossRules.FLOW_COST
	if rules.next_finisher():
		basic_button.text = "终结斩 [J]\n范围提升 · 破势大增"
	elif rules.flow_time > 0.0:
		basic_button.text = "普攻 [J]\n已命中 · 可按 1 行云"
	else:
		basic_button.text = "普攻 [J]\n近身命中 · 灵力 +5"

func _slash(is_sword: bool, damage: int, impacts: Array = [], counter: bool = false) -> void:
	sword_visual = is_sword
	slash_combo = rules.combo_step%3+1
	if counter:
		counter_visual = .7
	cast_duration = .52 if is_sword else .38
	cast_visual = cast_duration
	cast_origin = hero.position + Vector2(22, -75)
	cast_direction = (rules.boss_position - hero.position).normalized()
	if damage > 0: _landed_impact(damage,impacts,counter,is_sword)

func _landed_impact(damage: int, impacts: Array, counter: bool, is_sword: bool, finisher: bool = false, flowing: bool = false, ultimate: bool = false, ult_wave: int = 0) -> void:
	if damage<=0: return
	hurt_visual = .22
	if counter: counter_visual = .7
	if rules.brain != null:
		hit_stop = .060 if counter else (.055 if is_sword else .035)
		_jolt(5 if is_sword or counter else 3, .12)
		_sound("hit")
	if finisher:
		# 终结斩：更长顿帧、更强震屏，并触发大刀光与地面尘环。
		hit_stop = .085
		_jolt(9, .22)
		finisher_visual = .5
		finisher_origin = hero.position + Vector2(22, -75)
		finisher_direction = (rules.boss_position - hero.position).normalized()
		_sound("stagger")
	if flowing:
		flow_visual = .45
	if ultimate:
		hit_stop = .055 if ult_wave < 2 else .085
		_jolt(4.0 + ult_wave * 2.0, .14 if ult_wave < 2 else .20)
		if ult_wave == 2:
			_sound("stagger")
	for impact in impacts:
		var target_height := boss_height if impact.boss else 82.0
		var position := Vector2(impact.position) - Vector2(0, target_height * .42)
		hit_bursts.append({"position": position, "life": HIT_BURST_TIME, "counter": counter, "sword": is_sword, "finisher": finisher, "flow": flowing, "ultimate": ultimate, "wave": ult_wave})
		var text := "-%d" % impact.damage
		var tint := Color("ffe5a3") if counter else Color("c8f3d6")
		if ultimate:
			text = "剑域·%d " % (ult_wave + 1) + text
			tint = Color("e39a92")
		elif finisher:
			text = "终结 " + text
			tint = Color("e48a83")
		elif flowing:
			text = "行云 " + text
			tint = Color("b1fae7")
		floating(text,Vector2(impact.position)-Vector2(30,boss_height+10 if impact.boss else 100),tint)

func use_ultimate() -> void:
	if _settings_open() or paused:
		return
	var direction: Vector2 = (rules.boss_position - hero.position).normalized()
	var result: Dictionary = rules.ultimate(hero.position, direction)
	if not result.get("ok", false):
		floating(str(result.get("message", "剑意未满")), hero.position - Vector2(0, 140), Color("c9bda5"))
		return
	ultimate_visual = 1.2
	finisher_visual = 0.0
	flow_visual = 0.0
	cast_visual = 0.0
	message.text = "赤霄剑域 · 三式连落，仍可移动"
	_sound("phase")
	refresh()

func basic_attack() -> void:
	if _settings_open():
		return
	if paused or rules.airborne_time > 0.0 or roll_remaining>0:
		return
	var result = rules.start_action("basic",hero.position)
	if result.ok:
		_slash(false, result.damage, result.get("impacts",[]),result.get("counter",false))
	message.text = result.message
	refresh()
	if rules.finished:
		show_result()

func use_skill(choice: int) -> void:
	if _settings_open():
		return
	if paused or rules.finished or choice < 0 or choice > 3 or (roll_remaining>0 and choice!=1):
		return
	if rules.airborne_time > 0.0 and choice != 2:
		return
	match choice:
		0:
			var result = rules.start_action("sword",hero.position,rules.boss_position-hero.position)
			message.text = result.message
			if result.ok:
				_slash(true, result.damage, result.get("impacts",[]),result.get("counter",false))
				if result.get("flow",false):
					flow_visual = .5
		1:
			if rules.dodge():
				dodge_origin = hero.position
				dodge_visual = 0.45
				var direction = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
				if direction.is_zero_approx():
					direction = facing
				roll_direction = direction.normalized()
				roll_remaining = 145
				cast_visual = 0
			message.text = rules.last_message
		2:
			rules.defend()
			message.text = rules.last_message
		3:
			rules.heal()
			message.text = rules.last_message
	refresh()
	if rules.finished:
		show_result()

func floating(text: String, at: Vector2, color: Color = Color("c8f3d6")) -> void:
	var options := get_node_or_null("/root/GameOptions")
	if options != null and not options.get_value("show_damage_numbers", true):
		return
	var popup: Label = impact_text.duplicate()
	popup.text = text
	popup.autowrap_mode = TextServer.AUTOWRAP_OFF
	popup.add_theme_color_override("font_color",color)
	popup.z_index = 11
	add_child(popup)
	popup.reset_size()
	popup.position = Vector2(clampf(at.x, 0.0, maxf(0.0, size.x - popup.size.x)), at.y)
	popup.show()
	var tween := create_tween().set_parallel(true)
	tween.tween_property(popup,"position:y",at.y-34,.55)
	tween.tween_property(popup,"modulate:a",0.0,.22).set_delay(.33)
	tween.chain().tween_callback(popup.queue_free)

func _process(delta: float) -> void:
	if rules == null:
		return
	if _settings_open():
		return
	if game.state != entered_state or not entered_state.allows_battle():
		rules.finished = true
		rules.won = false
		ui.close_modal()
		ui.toast("角色或修行状态已变化，本局已结束。")
		return
	if paused:
		return
	if hit_stop > 0:
		var stopped := minf(hit_stop,delta)
		hit_stop -= stopped
		delta -= stopped
		if delta <= 0:
			return
	clock += delta
	if _reduced_flash():
		phase_flash = 0.0
		shake = 0.0
		hero.modulate = Color.WHITE
	hero_hurt_visual = maxf(0,hero_hurt_visual-delta)
	for effects in [hit_bursts, sap_flows, split_bursts]:
		for i in range(effects.size() - 1, -1, -1):
			effects[i].life -= delta
			if effects[i].life <= 0:
				effects.remove_at(i)
	sap_pulse_visual = maxf(0.0, sap_pulse_visual - delta)
	wind_visual = maxf(0.0, wind_visual - delta)
	landing_visual = maxf(0.0, landing_visual - delta)
	perfect_visual = maxf(0,perfect_visual-delta)
	counter_visual = maxf(0,counter_visual-delta)
	finisher_visual = maxf(0.0, finisher_visual - delta)
	flow_visual = maxf(0.0, flow_visual - delta)
	ultimate_visual = maxf(0.0, ultimate_visual - delta)
	if rules.ult_active:
		ultimate_visual = maxf(ultimate_visual, .18)
	phase_flash = maxf(0,phase_flash-delta)
	shake = maxf(0, shake-delta)
	world.position = Vector2(sin(clock*111), cos(clock*137)) * shake_strength * minf(1, shake*9) if shake > 0 else Vector2.ZERO
	companion_flash = maxf(0, companion_flash - delta)
	if companion != null and not rules.finished:
		companion_sprite.position = hero.position + Vector2(-65, 10)
		companion.step(delta)
		var damage: int = rules.companion_hit(companion.strike(companion_sprite.position, rules.boss_position))
		if damage > 0:
			companion_flash = 0.35
			floating("AI -%d" % damage, boss_anchor - Vector2(25, boss_height + 10))

	cast_visual = maxf(0, cast_visual - delta)
	dodge_visual = maxf(0, dodge_visual - delta)
	hurt_visual = maxf(0, hurt_visual - delta)
	boss_hurt_visual = maxf(0.0, boss_hurt_visual - delta)
	boss_rage_visual = maxf(0.0, boss_rage_visual - delta)
	boss_recoil = boss_recoil.move_toward(Vector2.ZERO, delta * 95.0)
	heal_visual = maxf(0, heal_visual - delta)
	shield_impact = maxf(0, shield_impact - delta)
	shield_break_visual = maxf(0, shield_break_visual - delta)
	if not rules.finished:
		var direction = Input.get_vector("move_left","move_right","move_forward","move_back")
		hero_moving = not direction.is_zero_approx()
		if rules.airborne_time > 0.0:
			hero_moving = false
			roll_remaining = 0.0
		elif roll_remaining>0:
			var distance := minf(roll_remaining,delta*145/.18)
			hero.position += roll_direction*distance
			roll_remaining -= distance
			facing = roll_direction
		else:
			if hero_moving: facing = direction.normalized()
			var movement := .3 if rules.heal_cast>0 else (.65 if cast_visual>0 else 1.0)
			if rules.ult_active:
				movement *= .65
			if rules.slow_time > 0.0:
				movement *= .62
			hero.position += direction*255*delta*movement*(1.0 + float(wearable_effects.get("movement", 0)))
		_clamp_hero()
		var shield_before: int = rules.shield_hp
		var was_airborne: bool = rules.airborne_time > 0.0
		var result = rules.step(delta, hero.position)
		var displacement: Vector2 = result.get("displacement", Vector2.ZERO)
		if not displacement.is_zero_approx():
			hero.position += displacement
			_clamp_hero()
		if rules.airborne_time > 0.0:
			hero_moving = false
			roll_remaining = 0.0
			cast_visual = 0.0
		elif was_airborne:
			landing_visual = LANDING_FLASH_TIME
			landing_position = hero.position
		if shield_before > 0 and rules.shield_hp == 0:
			shield_break_visual = 0.55
		if int(result.get("healed", 0)) > 0:
			heal_visual = 0.8
			floating("+%d" % result.healed, hero.position - Vector2(20, 160))
			message.text = "饕餮归元 · 暖光回流，生命恢复。"
		for event in result.get("events", [result]):
			_enemy_feedback(event, not displacement.is_zero_approx())
		if rules.stage_index > last_stage:
			last_stage = rules.stage_index
			_jolt(4, .20)
			_sound("phase")
			phase_flash = .75
			if split_bursts.is_empty():
				message.text = "第%d阶段 · 新招式出现，已显示的预兆保持不变。" % (last_stage+1)
	if not rules.finished and Input.is_physical_key_pressed(KEY_J) and rules.attack_cd<=0 and rules.heal_cast<=0:
		basic_attack()
	_hero_pose()
	_boss_pose(delta)
	_hero_visibility()
	_refresh_adds()
	refresh()
	if rules.finished and not result_shown:
		show_result()

func _clamp_hero() -> void:
	hero.position.x = clampf(hero.position.x, 150, 1230)
	hero.position.y = clampf(hero.position.y, 458, 680)

func _input(event: InputEvent) -> void:
	if rules == null:
		return
	if _settings_open():
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ESCAPE: leave_battle()
		KEY_P: _toggle_pause()
		KEY_J: basic_attack()
		KEY_1, KEY_Q: use_skill(0)
		KEY_2, KEY_SPACE: use_skill(1)
		KEY_3, KEY_K: use_skill(2)
		KEY_4, KEY_R: use_skill(3)
		KEY_5, KEY_T: use_ultimate()
		_: return
	get_viewport().set_input_as_handled()

func _toggle_pause() -> void:
	paused = not paused
	_touch_pause_button.text = "继续" if paused else "暂停"
	var pause_hint := "战斗已暂停" if _touch_pause_button.visible else "暂停 · P 继续 / Esc 返回"
	message.text = pause_hint if paused else "继续战斗"

func leave_battle() -> void:
	if not encounter.is_empty():
		ui.open_boss()
	else:
		ui.close_modal()

var remote_session: String = ""

func _open_remote_session() -> void:
	var started: Dictionary = await game.account_api.api.invoke("combat.start", {"cultivator_id": entered_state.cultivator_id, "encounter_id": boss_id})
	if started.ok:
		remote_session = str(started.data.session_id)

func _submit_remote_result() -> void:
	if remote_session.is_empty():
		return
	var payload = {"session_id": remote_session, "won": rules.won, "duration_seconds": snappedf(rules.elapsed, 0.01)}
	for attempt in range(3):
		var finished: Dictionary = await game.account_api.api.invoke("combat.finish", payload)
		if finished.ok or finished.code not in ["NETWORK_ERROR", "INTERNAL_ERROR"]:
			break
	if is_instance_valid(game):
		await game.account_api.sync_family(game.family)

func show_result() -> void:
	if result_shown:
		return
	result_shown = true
	_touch_pause_button.hide()
	_submit_remote_result()
	entered_state.save_game()
	ui.refresh()
	var content = ui.card(Rect2(410, 225, 640, 450), self)
	content.add_theme_constant_override("separation", 10)
	ui.label_into(content, "试炼通过 · " + rules.boss_name + "退散" if rules.won else "本次挑战结束", 28)
	ui.line(content)
	var stage_name = encounter.arena + " · " + encounter.name if not encounter.is_empty() else entered_state.ATTRIBUTE_LABELS[rules.track] + "试炼"
	ui.paragraph(content, "%s · %d 档%s\n用时 %.1f 秒    造成伤害 %d\n受到伤害 %d    受击 %d 次" % [stage_name, rules.tier, " · 练习" if mode == "practice" else "", rules.elapsed, rules.damage_total, rules.damage_taken, rules.hit_count], 20, Color("5c432e"))
	if rules.brain != null:
		ui.paragraph(content,"第%d关 · 精准闪避 %d · 破势 %d" % [rules.combat_rank,rules.perfect_dodges,rules.stagger_count],17)
	if mode == "practice":
		ui.paragraph(content, "技能练习不结算首通，健康属性和关卡进度保持原样。", 17)
	elif rules.won:
		ui.paragraph(content, "首通进度已保存 · 当前境界 " + entered_state.realm(), 18)
		if not heal_was_unlocked and entered_state.heal_unlocked():
			ui.label_into(content, "新技能解锁：饕餮归元 [4]", 21, Color("3a6b59"))
		if not encounter.is_empty() and entered_state.has_method("boss_unlocked"):
			var next_index := int(encounter.index) + 1
			if next_index < 20:
				var next = Catalogue.at(next_index)
				if entered_state.boss_unlocked(next.id):
					ui.label_into(content, "下一关已开放：第 %02d 关 · %s" % [next_index + 1, next.name], 20, Color("8a4f3f"))
			else:
				ui.label_into(content, "二十长廊已全线贯通", 20, Color("8a4f3f"))
	else:
		ui.paragraph(content, "健康属性与已通关记录保留。可再次练习，也可更新健康档案后再挑战。", 17)
	var actions = HBoxContainer.new()
	content.add_child(actions)
	if mode == "practice":
		ui.button(actions, "再次练习", ui.start_battle, true)
	else:
		if not encounter.is_empty():
			ui.button(actions, "再次挑战", func(): ui.start_corridor_boss(boss_id), true)
		else:
			ui.button(actions, "再次挑战", func(): ui.start_boss(false, rules.tier, rules.track), true)
	ui.button(actions, "返回长廊", ui.open_boss)
	ui.button(actions, "回到仙村", ui.close_modal)

func add_sprite_height(add: Dictionary) -> float:
	match str(add.get("variant", "")):
		"large": return boss_height * .49
		"small": return boss_height * .30
	return 74.0

func _refresh_adds() -> void:
	while _add_sprites.size() < rules.adds.size():
		var frames: Array[Texture2D] = Assets.frames("res://assets/pixel_campaign/minion_sheet.png", 5, 2, 0.1, true)
		var sprite: Sprite2D = actor(frames[_add_sprites.size() % 10], Vector2.ZERO, 74)
		sprite.z_index = 2
		_add_sprites.append(sprite)
	for i in range(_add_sprites.size()):
		var sprite := _add_sprites[i]
		if i >= rules.adds.size():
			sprite.hide()
			continue
		var add: Dictionary = rules.adds[i]
		sprite.visible = add.hp > 0 and not rules.finished
		if not sprite.visible:
			continue
		var move_x: float = add.position.x - sprite.position.x
		sprite.position = add.position + Vector2(0, sin(clock*13+i)*3 if add.phase == "seek" else 0)
		sprite.z_index = 3 if float(add.position.y) > hero.position.y else 1
		var variant := str(add.get("variant", ""))
		if variant in ["large", "small"] and not boss_bank.is_empty():
			var height := add_sprite_height(add)
			var frame := int(clock * 8.0 + i) % 4
			var tint := Color("ffd388") if variant == "large" else Color("adeb9e")
			match str(add.phase):
				"bud":
					frame = 8
					height *= lerpf(.55, 1.0, smoothstep(0.0, .60, float(add.clock)))
				"windup":
					frame = 5
					tint = tint.lightened(.32)
				"lunge": frame = 6
				"recover": frame = 7
			Actions.apply(sprite, boss_bank, frame, height)
			sprite.rotation = 0.0
			if add.phase in ["windup", "lunge"]:
				sprite.flip_h = Vector2(add.target).x > Vector2(add.position).x
			elif absf(move_x) > 0.1:
				sprite.flip_h = move_x > 0.0
			sprite.modulate = tint
			continue
		sprite.rotation = sin(clock*13+i)*.07 if add.phase == "seek" else -.10
		sprite.modulate = Color("ffc58a") if add.phase == "windup" else Color.WHITE
		var stretch := Vector2(1.16,.88) if add.phase == "lunge" else Vector2.ONE
		sprite.scale = stretch * add_sprite_height(add) / sprite.texture.get_height()

func enable_companion() -> bool:
	if mode != "practice" or companion != null:
		return false
	companion = preload("res://scripts/systems/combat/pr4_companion.gd").new(rules.stats)
	companion_sprite = actor(game.walk_textures[8], hero.position + Vector2(-65, 10), 90)
	message.text = "AI 护法陪练 · 仅本局辅助，不结算首通或灵气"
	return true


func _jolt(strength: float, duration: float) -> void:
	if _reduced_flash():
		return
	shake_strength = strength
	shake = duration

func _sound(cue: String) -> void:
	if DisplayServer.get_name() == "headless" or not is_instance_valid(boss_audio):
		return
	var path := "res://assets/combat/boss_" + cue + ".wav"
	if ResourceLoader.exists(path):
		boss_audio.stream = load(path)
		boss_audio.play()

func _enemy_feedback(event: Dictionary, displaced: bool = false) -> void:
	match str(event.get("event", "")):
		"player_hit":
			var hit: Dictionary = event.result
			var is_ultimate := bool(hit.get("ultimate", false))
			var wave := int(hit.get("ult_wave", 0))
			_landed_impact(int(hit.damage),hit.get("impacts",[]),hit.get("counter",false),event.kind=="sword" or is_ultimate,hit.get("finisher",false),hit.get("flow",false),is_ultimate,wave)
			if int(hit.damage) > 0:
				boss_hurt_visual = .22 if is_ultimate else (.24 if hit.get("finisher", false) else .16)
				var away: Vector2 = (rules.boss_position - hero.position).normalized()
				boss_recoil = away * (10.0 + wave * 2.0 if is_ultimate else (13.0 if hit.get("finisher", false) else 7.0))
			message.text = hit.message
		"enraged":
			boss_rage_visual = 2.4
			floating("激怒", rules.boss_position - Vector2(28, boss_height + 4), Color("dc7770"))
			message.text = rules.boss_name + "被激怒 · 蓄势回击，留意完整预警。"
			_sound("phase")
		"windup":
			var kind: String = str(rules.brain.move.kind) if rules.brain != null else "circle"
			var advice := {"charge":"横向闪开冲锋路线", "leap":"离开落点，等它落地再反击", "volley":"从弹道之间穿过", "nova":"贴近内圈，或退到环外", "slash":"绕到侧后方", "beam":"横向移出吐息线", "eruption":"观察起势，及时移动", "cross":"走向十字之间的空隙"}
			var hint: String = advice.get(kind, "观察动作，收招时反击")
			if rules.brain != null:
				var signature: Dictionary = rules.brain.move.get("signature", {})
				if not signature.is_empty():
					hint = str(signature.get("tactics", hint))
				elif rules.brain.move.get("style") == "sap":
					hint = "藤脉已锁定 · 横移避开连续吸血"
			message.text = str(event.get("attack", rules.boss_name)) + " · " + hint
			if rules.brain != null and rules.brain.move.get("provoked", false):
				message.text = "激怒回击 · " + message.text
			_sound("tell")
		"release":
			_sound("rush" if event.kind in ["charge","leap"] else ("shot" if event.kind == "volley" else "impact"))
		"volley_burst": _sound("shot")
		"signature_beat":
			var beat_label := str(event.get("label", ""))
			message.text = "第 %d/%d 段" % [event.number, event.total]
			if not beat_label.is_empty():
				message.text += " · " + beat_label
			_sound("shot")
		"signature_status":
			message.text = str(event.get("label", ""))
		"forced_move":
			var effect := str(event.effect)
			if effect != wind_effect or wind_visual <= 0.0:
				message.text = "逆风吸近 · 向侧面脱离" if effect == "pull" else "罡风吹飞 · 可施放护盾抵挡落地冲击"
				_sound("rush")
			wind_effect = effect
			wind_visual = .52
		"sap_pulse":
			sap_pulse_visual = SAP_PULSE_TIME
			_sound("shot")
		"drain":
			var position := Vector2(event.position)
			sap_flows.append({"source": Vector2(event.source_position), "target": position, "life": SAP_FLOW_TIME})
			floating("+%d 回血" % int(event.amount), position - Vector2(22, boss_height * .68), Color("b9ff9e"))
			message.text = "%s汲取生命 · 恢复 %d" % [rules.boss_name, int(event.amount)]
		"split":
			var position := Vector2(event.position)
			split_bursts.append({"position": position, "life": SPLIT_BURST_TIME})
			floating("分裂 ×%d" % int(event.count), position - Vector2(45, 172), Color("e9e5a4"))
			message.text = "%s正在长出分身 · 趁萌芽时清理" % rules.boss_name
			_sound("phase")
		"combo_link": message.text = "连段未结束 · 准备第%d / %d击，保留体力。" % [event.next,event.total]
		"stagger":
			phase_flash = .5
			_jolt(6,.20)
			_sound("stagger")
			floating("破势！",boss_anchor-Vector2(40,boss_height+20),Color("ffe1a0"))
			message.text = "破势 · 近身输出造成更多伤害！"
		"perfect_evade":
			perfect_visual = .7
			hit_stop = .045
			_sound("perfect")
			floating("精准闪避",hero.position-Vector2(40,175),Color("ffe6aa"))
			message.text = "精准闪避 · 体力 +10、剑意 +20，2秒内可强化反击。"
		"impact": _jolt(5, .18)
		"recover": message.text = "收招窗口 · 靠近普攻回灵，或用剑诀追击。"
		"evaded": message.text = "闪避成功 · 留意下一段攻击。"
		"blocked":
			shield_impact = .6
			message.text = "云罡抵挡 %d · 剑意 +10，反击就绪。" % event.absorbed
		"hurt":
			hero_hurt_visual = .30
			if event.get("attack_interrupted",false): cast_visual = 0
			shield_impact = .6 if event.absorbed > 0 else 0
			message.text = str(event.get("attack","攻击")) + "造成 %d 点伤害。" % event.damage + ("归元被中断。" if event.interrupted else "")
			floating("-%d" % event.damage, hero.position-Vector2(20,160+rules.airborne_height()),Color("ffb6a0"))
			if not _reduced_flash():
				hero.modulate = Color("ffaaa0")
				create_tween().tween_property(hero,"modulate",Color.WHITE,.4)
			if rules.brain != null:
				hit_stop = .055
				_jolt(6, .16)
				if not displaced:
					hero.position += Vector2(event.get("direction",Vector2.ZERO)) * 22
					_clamp_hero()
				_sound("impact")

func _boss_pose(_delta: float) -> void:
	if rules.brain == null:
		var frame := 3 if rules.finished and rules.won else (1 if rules.phase in ["windup","attack","breath"] else (2 if hurt_visual>0 else 0))
		dragon.texture = dragon_frames[mini(frame,dragon_frames.size()-1)]
		dragon.offset.y = -dragon.texture.get_height()*.5
		dragon.scale = Vector2.ONE*boss_height/dragon.texture.get_height()
		dragon.position = boss_anchor+Vector2(0,sin(clock*1.6)*3)
		return
	boss_anchor = rules.boss_position
	boss_frame_index = Actions.boss_frame(rules,clock,hurt_visual)
	var signature_attack: bool = rules.phase == "attack" and rules.brain.move.has("signature")
	if not boss_bank.is_empty(): Actions.apply(dragon,boss_bank,boss_frame_index,boss_height)
	var lift := 0.0
	if rules.phase=="attack" and rules.brain.move.kind=="leap" and not signature_attack: lift = sin(rules.brain.progress()*PI)*145
	dragon.position = boss_anchor+Vector2(0,-lift) + boss_recoil
	dragon.rotation = clampf(boss_recoil.x * .002, -.026, .026)
	dragon.flip_h = rules.brain.facing.x>.15
	dragon.z_index = 3 if boss_anchor.y>hero.position.y else 1
	hero.z_index = 2
	if boss_hurt_visual > 0.0 and not _reduced_flash():
		dragon.modulate = Color(1.08, .76, .78)
	elif boss_rage_visual > 0.0 and not _reduced_flash():
		dragon.modulate = Color(1.08, .86, .86)
	else:
		dragon.modulate = Color.WHITE
	if rules.finished and rules.won: dragon.modulate = Color(.7,.7,.7,.7)

func _exit_tree() -> void:
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.leave_battle(self)
	var touch := get_node_or_null("/root/TouchControls")
	if touch != null:
		touch.unbind_battle(self)
	if is_instance_valid(boss_audio):
		boss_audio.stop()
		boss_audio.stream = null

func _settings_open() -> bool:
	if not is_inside_tree():
		return false
	var options := get_node_or_null("/root/GameOptions")
	return options != null and options.settings_open

func _reduced_flash() -> bool:
	if not is_inside_tree():
		return false
	var options := get_node_or_null("/root/GameOptions")
	return options != null and options.get_value("reduced_flash", false)


func _hero_pose() -> void:
	if hero_bank.is_empty(): return
	hero_frame_index = 15
	if rules.airborne_time > 0.0:
		hero_frame_index = 14
	elif roll_remaining>0:
		hero_frame_index = 12 if roll_remaining>115 else 13
	elif hero_hurt_visual>0:
		hero_frame_index = 14
	elif cast_visual>0:
		var elapsed := cast_duration-cast_visual
		var start := 8 if sword_visual else 4
		var impact := .16 if sword_visual else .12
		if elapsed<impact*.5: hero_frame_index=start
		elif elapsed<impact: hero_frame_index=start+1
		elif elapsed<impact+.12: hero_frame_index=start+2
		else: hero_frame_index=start+3
	elif rules.heal_cast>0 or rules.shield_time>3.0:
		hero_frame_index = 8
	elif hero_moving and not rules.finished:
		hero_frame_index = int(clock*9)%4
	Actions.apply(hero,hero_bank,hero_frame_index,148)
	hero.offset.y -= rules.airborne_height() / hero.scale.y
	hero.rotation = 0
	hero.flip_h = (rules.boss_position.x<hero.position.x) if cast_visual>0 else facing.x<-.15

func _hero_visibility() -> void:
	hero_outline.visible = rules.brain != null and not rules.finished and dragon.z_index>hero.z_index and hero.position.distance_to(rules.boss_position)<boss_height*.55
	if hero_outline.visible:
		hero_outline.texture = hero.texture
		hero_outline.position = hero.position
		hero_outline.offset = hero.offset
		hero_outline.scale = hero.scale
		hero_outline.rotation = hero.rotation
		hero_outline.flip_h = hero.flip_h
