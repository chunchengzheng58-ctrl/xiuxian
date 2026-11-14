extends SceneTree

const Feedback = preload("res://scripts/battle_feedback.gd")
var failures := 0
var assertions := 0
var observed: Array[String] = []

class Wire extends Node:
	signal expedition_state_received(snapshot: Dictionary)
	signal expedition_error_received(id: String, code: String, message: String)
	signal duel_state_received(snapshot: Dictionary)
	signal duel_error_received(id: String, code: String, message: String)
	signal connection_changed(status: String)
	var packets: Array = []
	func send_expedition(packet: Dictionary) -> bool:
		packets.append(packet.duplicate(true))
		return true
	func send_duel(packet: Dictionary) -> bool:
		packets.append(packet.duplicate(true))
		return true

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		printerr("FEEDBACK FAIL ", message)

func fighter() -> Dictionary:
	return {"x":520.0,"y":570.0,"fx":1.0,"hp":100,"max_hp":100,"mp":100,"max_mp":100,"stamina":100,"max_stamina":100,
		"ack":1,"online":true,"shield":0,"dash":false,"hit":false,"pose":"idle","cd":[0,0,0,0,0,0]}

func packet() -> Dictionary:
	return {"run_id":"fixture-pve","stage_id":"b01","boss_id":"b01","tick":100,"phase":"fighting","seconds":160,
		"player":fighter(),"enemy":fighter(),"mechanic":{"stage":0,"phase":"seek","move_id":"a","label":"测试"},
		"telegraphs":[],"hazards":[],"blades":[],"result":null}

func run() -> void:
	var options := root.get_node_or_null("GameOptions")
	if options == null:
		options = load("res://scripts/game_options.gd").new()
		options.name = "GameOptions"
		root.add_child(options)
	options.update("muted", false)
	options.update("show_damage_numbers", true)
	var feedback := Feedback.new()
	root.add_child(feedback)
	feedback.feedback.connect(func(kind): observed.append(kind))
	var state := packet()
	state.player.cd[2] = 20
	feedback.observe(state)
	check(observed.is_empty(), "Initial/reconnect packet establishes a silent baseline")
	var changed := state.duplicate(true)
	changed.tick += 1
	changed.enemy.hp = 83
	changed.player.hp = 92
	changed.player.cd[3] = 18
	feedback.observe(changed)
	check(observed.count("hit") == 1 and observed.count("hurt") == 1 and observed.count("dash") == 1, "Confirmed health loss and accepted dash each create feedback")
	check(feedback.get_child_count() == 2, "Only confirmed HP deltas create floating numbers")
	var count := observed.size()
	feedback.observe(changed)
	feedback.observe(state)
	check(observed.size() == count, "Duplicate and out-of-order active packets create no sound")
	feedback.suspend()
	changed.tick += 40
	changed.player.hp = 50
	feedback.observe(changed)
	check(observed.size() == count, "Reconnection does not replay missed damage")
	changed.tick += 1
	changed.player.hp = 74
	changed.player.shield = 28
	changed.player.cd[4] = 39
	feedback.observe(changed)
	check(observed.count("guard") == 1 and feedback.get_child_count() == 3, "Confirmed shield cast and actual healing are visible")
	changed.tick += 1
	changed.player.shield = 12
	feedback.observe(changed)
	check(observed.count("block") == 1, "Shield absorbs actual damage without an invented HP loss")
	options.update("show_damage_numbers", false)
	await process_frame
	check(feedback.get_child_count() == 0, "Disabling floating numbers clears their current presentation")
	changed.tick += 1
	changed.enemy.hp -= 12
	feedback.observe(changed)
	check(feedback.get_child_count() == 0, "New confirmed hits respect the numbers option")
	changed.tick += 1
	changed.phase = "finished"
	changed.result = {"won":true,"reason":"knockout"}
	feedback.observe(changed)
	feedback.observe(changed)
	feedback.suspend()
	changed.tick = 0
	feedback.observe(changed)
	check(observed.count("victory") == 1, "Repeated/reclaimed terminal snapshots do not replay victory")
	var history := Feedback.new()
	root.add_child(history)
	var historical: Array = []
	history.feedback.connect(func(kind): historical.append(kind))
	history.observe(changed)
	check(historical.is_empty(), "Opening a persisted finished battle is silent")
	var duel := Feedback.new()
	root.add_child(duel)
	var duel_events: Array = []
	duel.feedback.connect(func(kind): duel_events.append(kind))
	var pvp := {"match_id":"fixture-pvp","tick":50,"seat":1,"phase":"fighting","players":[fighter(),fighter()],"result":null}
	duel.observe(pvp,true)
	pvp.tick += 1
	pvp.players[1].hp = 60
	pvp.players[0].hp = 85
	duel.observe(pvp,true)
	check(duel_events.count("hurt") == 1 and duel_events.count("hit") == 1, "PvP feedback follows assigned seat rather than assuming player zero")
	feedback.queue_free()
	history.queue_free()
	duel.queue_free()
	await process_frame
	await test_settings_neutral_input(options)
	await test_audio_lifecycle(options)
	print("BATTLE_FEEDBACK_TEST: ", assertions, " assertions; ", failures, " failures")
	quit(1 if failures else 0)

func test_settings_neutral_input(options: Node) -> void:
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame

	scene.ui.close_modal(true)
	var actual = scene.account_api.realtime
	var wire := Wire.new()
	root.add_child(wire)
	scene.account_api.realtime = wire
	scene.ui.open_expedition_battle("fixture-pve")
	var view = scene.ui.expedition_view
	view.receive_state(packet())
	view.set_process(false)
	view.pending_action = 2
	Input.action_press("move_right")
	var owner := Control.new()
	root.add_child(owner)
	options.begin_settings(owner)
	view._process(0.1)
	var sent: Dictionary = wire.packets[-1]
	check(sent.type == "expedition_input" and sent.x == 0 and sent.y == 0 and sent.action == 0, "Open settings sends neutral PVE movement and action")
	check(view.pending_action == 0 and not view.touch_actions_active() and not view.action_available(1), "Settings clears queued attacks and disables touch/skills")
	options.update("reduced_flash", true)
	var hit := fighter()
	hit.hit = true
	view.animate_fighter(view.hero,view.hero_bank,hit,148,0.1)
	check(view.hero.modulate == Color.WHITE, "Reduced flash suppresses confirmed PVE hit tint")
	options.end_settings(owner)
	view._process(0.1)
	sent = wire.packets[-1]
	check(sent.x > 0 and view.touch_actions_active(), "Closing settings restores normal movement and controls")
	scene.ui.close_modal(true)
	scene.ui.open_duel_battle("fixture-pvp")
	view = scene.ui.duel_view
	view.receive_state({"match_id":"fixture-pvp","tick":100,"phase":"fighting","seat":0,"seconds":80,"players":[fighter(),fighter()],"names":["甲","乙"],"avatars":["male","female"],"result":null,"blades":[]})
	view.set_process(false)
	options.begin_settings(owner)
	view.pending_action = 1
	view._process(0.1)
	sent = wire.packets[-1]
	check(sent.type == "duel_input" and sent.x == 0 and sent.y == 0 and sent.action == 0, "Open settings sends neutral PvP intent without pausing the match")
	options.end_settings(owner)
	Input.action_release("move_right")
	scene.ui.close_modal(true)
	scene.account_api.realtime = actual
	scene.queue_free()
	wire.queue_free()
	owner.queue_free()
	await process_frame

func test_audio_lifecycle(options: Node) -> void:
	var audio := root.get_node_or_null("GameAudio")
	check(audio != null, "Audio manager is installed before game scenes")
	if audio == null:
		return
	var original: Dictionary = options.values.duplicate(true)
	var cues: Array = []
	audio.cue_played.connect(func(kind): cues.append(kind))
	options.update("muted", false)
	audio.unlocked = false
	audio.play("hit")
	check(cues.is_empty(), "Audio waits for a Web-style user gesture instead of autoplaying effects")
	audio.unlock()
	check(audio.unlocked and is_instance_valid(audio._music) and audio._music.bus == "Music", "User gesture starts the selected music context on the Music bus")
	check(audio._music.stream is AudioStreamWAV and audio._music.stream.loop_mode == AudioStreamWAV.LOOP_FORWARD and absf(audio._music.stream.get_length() - 32.0) < 0.01, "Original score has a valid 32-second looping PCM stream")
	audio.play("guard")
	audio.play("guard")
	check(cues.count("guard") == 1, "Audio polyphony throttle prevents a same-frame cue pileup")
	options.update("muted", true)
	audio.play("sword")
	check(cues.count("sword") == 0 and AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")), "Global mute stops new cues and mutes legacy/effects/music together")
	options.update("muted", false)
	options.update("effects_volume", 0.0)
	audio.play("sword")
	check(cues.count("sword") == 0 and AudioServer.is_bus_mute(AudioServer.get_bus_index("Effects")), "Effects zero does not create new effects while keeping its independent bus")
	options.update("effects_volume", 0.7)
	options.update("music_volume", 0.2)
	check(absf(db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music"))) - 0.2) < 0.001, "Music volume applies independently to its bus")
	var first := Node.new()
	var second := Node.new()
	root.add_child(first)
	root.add_child(second)
	audio.enter_battle(first)
	audio.enter_battle(second)
	audio.leave_battle(first)
	check(audio.current_context == "battle" and audio.battle_owner_id == second.get_instance_id(), "Old scene exit cannot steal the new battle's music context")
	audio.leave_battle(second)
	check(audio.current_context == "village" and audio.battle_owner_id == 0, "Final battle exit restores the village score")
	await create_timer(0.8).timeout
	var players := audio.find_children("*", "AudioStreamPlayer", false, false)
	check(players.size() == 9, "Crossfades release old music players and retain the bounded effects pool")
	for key in original:
		options.update(key, original[key])
	first.queue_free()
	second.queue_free()
	await process_frame
