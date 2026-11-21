extends SceneTree
const BossRules = preload("res://scripts/boss_rules.gd")
## 战斗表现验证：打开演示 Boss 关，自动打出三段连击、终结斩与行云剑气并截图。
## 用法：godot --path . --script res://tests/combat_fx_preview.gd
## 产物在 output/ 下，仅用于视觉回归，不影响任何存档。

func _initialize() -> void:
	root.size = Vector2i(1440, 900)
	_run()

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "res://output/" + name + ".png"
	print("FX_SHOT ", path, " result=", image.save_png(path))

func _run() -> void:
	var hub: Control = load("res://scenes/combat/demo_hub.tscn").instantiate()
	root.add_child(hub)
	await create_timer(0.6).timeout
	hub.open("boss")
	await create_timer(1.2).timeout
	var view = hub.current
	if view == null:
		push_error("演示 Boss 关未能打开")
		quit(1)
		return
	# 贴近 Boss，保证普攻进入判定。
	view.hero.position = Vector2(905, 600)
	await create_timer(0.2).timeout
	# 第一段：普攻命中后立刻接剑气，验证行云取消。
	for i in range(2):
		view.hero.position = view.rules.boss_position + Vector2(-110, 20)
		view.basic_attack()
		var armed := 0.0
		while view.rules.flow_time <= 0.0 and armed < 1.0:
			await create_timer(0.03).timeout
			armed += 0.03
		if i == 0:
			view.use_skill(0)
			print("FX_FLOW_STRIKES=", view.rules.flow_strikes, " msg=", view.message.text)
			await create_timer(0.16).timeout
			await _shot("fx-flow")
		else:
			await create_timer(0.5).timeout
	# 第二段：连续三段普攻，在终结命中的瞬间截图。
	for i in range(3):
		while view.rules.attack_cd > 0.0:
			await create_timer(0.05).timeout
		view.hero.position = view.rules.boss_position + Vector2(-110, 20)
		var finishing: bool = view.rules.next_finisher()
		view.basic_attack()
		print("FX_ATTACK_", i, " msg=", view.message.text, " finishing=", finishing)
		if finishing:
			var waited := 0.0
			while view.rules.finisher_hits == 0 and waited < 1.5:
				await create_timer(0.03).timeout
				waited += 0.03
			print("FX_FINISHER_HITS=", view.rules.finisher_hits, " visual=", view.finisher_visual, " streak=", view.rules.hitstreak)
			await create_timer(0.10).timeout
			await _shot("fx-finisher")
			break
		await create_timer(0.5).timeout
	await create_timer(0.35).timeout
	await _shot("fx-combo")
	# 怒意满槽后会在 Boss 可出手时自动触发；若仍在出招，最多再补一剑。
	var rage_wait := 0.0
	while view.rules.rage_count == 0 and rage_wait < 1.6:
		await create_timer(0.05).timeout
		rage_wait += 0.05
	if view.rules.rage_count == 0 and not view.rules.finished:
		while view.rules.attack_cd > 0.0:
			await create_timer(0.05).timeout
		view.hero.position = view.rules.boss_position + Vector2(-110, 20)
		view.basic_attack()
		rage_wait = 0.0
		while view.rules.rage_count == 0 and rage_wait < 1.6:
			await create_timer(0.05).timeout
			rage_wait += 0.05
	# 等激怒后的原招式进入完整蓄力，截取回击预警。
	var tell_wait := 0.0
	while tell_wait < 1.4:
		if view.rules.phase == "windup" and view.rules.brain.move.get("provoked", false):
			break
		await create_timer(0.05).timeout
		tell_wait += 0.05
	print("FX_ENRAGED count=", view.rules.rage_count, " phase=", view.rules.phase, " provoked=", view.rules.brain.move.get("provoked", false), " tell=", view.rules.windup_duration)
	if view.rules.rage_count < 1 or not view.rules.brain.move.get("provoked", false):
		push_error("激怒回击未能进入原招式预警")
		quit(1)
		return
	await _shot("fx-rage")
	# 规则测试已验证充能，这里直接装满剑意，专注验证三式的真实画面和输入入口。
	view.hero.position = view.rules.boss_position + Vector2(-120, 20)
	view.rules.ult_gauge = BossRules.ULT_MAX
	view.refresh()
	await create_timer(0.08).timeout
	await _shot("fx-ultimate-touch" if "--touch" in OS.get_cmdline_user_args() else "fx-ultimate-ready")
	if "--touch" in OS.get_cmdline_user_args():
		view.perform_action(5)
	else:
		var key := InputEventKey.new()
		key.keycode = KEY_5
		key.physical_keycode = KEY_5
		key.pressed = true
		view._input(key)
	print("FX_ULTIMATE_ACTIVE=", view.rules.ult_active, " button=", view.ult_button.text)
	for wave in range(1, 4):
		var wave_wait := 0.0
		while (view.rules.ult_wave < wave or view.rules.ult_clock < float(BossRules.ULT_WAVE_TIMES[wave - 1]) + .07) and wave_wait < 1.2:
			await create_timer(0.025).timeout
			wave_wait += 0.025
		await _shot("fx-ultimate-%d" % wave)
	var finish_wait := 0.0
	while view.rules.ult_active and finish_wait < 1.0:
		await create_timer(0.04).timeout
		finish_wait += 0.04
	print("FX_ULTIMATE used=", view.rules.ult_used, " hits=", view.rules.ult_hits, " waves=", view.rules.ult_wave, " active=", view.rules.ult_active, " gauge=", view.rules.ult_gauge)
	if view.rules.ult_used < 1 or view.rules.ult_wave < 3 or view.rules.ult_hits < 1 or view.rules.ult_active:
		push_error("赤霄剑域未完成三段实机结算")
		quit(1)
		return
	print("FX_RULES_OK hitstreak=", view.rules.hitstreak, " boss_hp=", view.rules.boss_hp)
	quit()
