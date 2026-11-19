extends SceneTree
const Player = preload("res://scripts/story_scene_player.gd")
var checks := 0
var failures: Array[String] = []
var captures: Array[String] = []
var campaign: Dictionary = {}

class FakeKernel extends Node:
	var calls: Array[Dictionary] = []
	func dispatch(command: String, payload: Dictionary) -> Dictionary:
		calls.append({"command": command, "payload": payload.duplicate(true)})
		return {"ok": true, "data": {}}

class Wire extends Node:
	signal expedition_state_received(snapshot: Dictionary)
	signal expedition_error_received(id: String, code: String, message: String)
	signal connection_changed(status: String)
	func send_expedition(_packet: Dictionary) -> bool:
		return true

class UIProbe extends Control:
	var opened := ""
	func open_expedition_battle(id: String) -> void:
		opened = id

class StoryPanelProbe extends "res://scripts/story_panel.gd":
	func refresh() -> void:
		pass

class LobbyProbe extends "res://scripts/expedition_lobby.gd":
	var started := ""
	func refresh() -> void:
		pass
	func start_now(id: String) -> void:
		started = id

class ExpeditionProbe extends "res://scripts/expedition_view.gd":
	var home_calls := 0
	func load_home() -> void:
		home_calls += 1

func expect(value: bool, title: String) -> void:
	checks += 1
	if not value:
		failures.append(title)
		printerr("FAIL: ", title)

func _initialize() -> void:
	_run.call_deferred()

func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	expect(image != null and not image.is_empty(), "rendered image exists: " + name)
	if image != null:
		expect(image.save_png("res://output/" + name + ".png") == OK, "save rendered " + name)
		captures.append("output/" + name + ".png")

func make_player(scene: Dictionary, kernel: FakeKernel, persist: bool, hero_id: String = "female", companion_id: String = "male") -> Control:
	var player := Player.new()
	player.scene_data = scene.duplicate(true)
	player.kernel = kernel
	player.cultivator_id = "story-p0-test"
	player.variants = {"protagonist": hero_id, "companion": companion_id}
	player.persist_marker = persist
	root.add_child(player)
	return player

func stage(id: String) -> Dictionary:
	for row in campaign.get("stages", []):
		if row.stage_id == id:
			return row
	return {}

func scene_for(id: String, kind: String) -> Dictionary:
	var row := stage(id)
	return {"scene_id": "stage.%s.%s" % [id, kind], "title": row.name, "kind": kind, "stage_id": id,
		"art": row.entrance.style, "dialogue": row[kind]}

func fighter() -> Dictionary:
	return {"x": 520.0, "y": 570.0, "fx": 1.0, "hp": 100, "max_hp": 100, "mp": 100, "max_mp": 100,
		"stamina": 100, "max_stamina": 100, "ack": 1, "online": true, "shield": 0, "dash": false,
		"hit": false, "pose": "idle", "cd": [0, 0, 0, 0, 0, 0]}

func test_boss_performance() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.ui.close_modal(true)
	var actual = game.account_api.realtime
	var wire := Wire.new()
	root.add_child(wire)
	game.account_api.realtime = wire
	game.ui.open_expedition_battle("story-p0-b12")
	var view = game.ui.expedition_view
	var boss_data := stage("b12")
	var packet := {"run_id": "story-p0-b12", "stage_id": "b12", "boss_id": "b12", "tick": 100,
		"phase": "fighting", "seconds": 160, "player": fighter(), "enemy": fighter(),
		"mechanic": {"stage": 0, "phase": "seek", "move_id": "letter", "label": "候风"},
		"presentation": {"entrance": boss_data.entrance, "barks": boss_data.barks},
		"telegraphs": [], "hazards": [], "blades": [], "result": null}
	view.receive_state(packet)
	expect(view.entrance_played and view.bark_label.text.contains("等"), "b12 custom entry bark appears")
	expect(view.story_prop.visible and view.story_prop.art == "letter", "b12 entrance prop appears without covering the arena")
	expect(view.battle_input_live(), "story entrance never disables battle input")
	expect(view.state.tick == 100 and view.state.mechanic.phase == "seek", "story entrance does not advance or pause authoritative combat")
	await capture("story-p0-boss-entrance")
	packet = packet.duplicate(true)
	packet.tick += 1
	packet.mechanic.stage = 1
	view.receive_state(packet)
	expect(view.bark_label.text.contains("风不回"), "phase change uses the short custom bark")
	packet = packet.duplicate(true)
	packet.tick += 1
	packet.enemy.hp = 20
	view.receive_state(packet)
	expect(view.low_hp_played, "low-health feedback triggers once")
	packet = packet.duplicate(true)
	packet.tick += 1
	packet.phase = "finished"
	packet.result = {"won": true, "reason": "knockout", "reward": {"first_clear": false, "spirit_stones": 0, "materials": 0, "adventure_xp": 0, "equipment": null}}
	view.receive_state(packet)
	expect(view.can_close() and is_instance_valid(view.result_panel), "boss defeat returns to the ordinary result flow")
	for id in ["b00", "b03", "b15", "b19"]:
		game.ui.close_modal(true)
		game.ui.open_expedition_battle("story-p0-" + id)
		view = game.ui.expedition_view
		boss_data = stage(id)
		packet = {"run_id": "story-p0-" + id, "stage_id": id, "boss_id": id, "tick": 100,
			"phase": "fighting", "seconds": 160, "player": fighter(), "enemy": fighter(),
			"mechanic": {"stage": 0, "phase": "seek", "move_id": "story", "label": "入场"},
			"presentation": {"entrance": boss_data.entrance, "barks": boss_data.barks},
			"telegraphs": [], "hazards": [], "blades": [], "result": null}
		view.receive_state(packet)
		expect(view.entrance_played and view.bark_label.text.contains(str(boss_data.barks.entry)), "custom entry bark appears: " + id)
		expect(view.story_prop.visible and view.story_prop.art == str(boss_data.entrance.style), "custom corner prop appears: " + id)
		expect(view.battle_input_live(), "battle input remains live during entrance: " + id)
		await capture("story-p0-boss-" + id)
	game.ui.close_modal(true)
	game.account_api.realtime = actual
	game.queue_free()
	await process_frame

func tap(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.position = point
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.position = point
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame

func test_resume_and_replay() -> void:
	var story_ui := UIProbe.new()
	var panel := StoryPanelProbe.new()
	panel.ui = story_ui
	panel.status_label = Label.new()
	panel.add_child(panel.status_label)
	panel.current = {"active_run": {"run_id": "run-original-42", "stage_id": "b12"}}
	await panel.scene_finished("stage.b12.prelude", false, true)
	expect(story_ui.opened == "run-original-42", "interrupted prelude returns to the original run id, not a stage id")
	panel.free()
	story_ui.free()
	var lobby := LobbyProbe.new()
	lobby.status_label = Label.new()
	lobby.add_child(lobby.status_label)
	lobby.pending_stage = ""
	lobby.scene_finished("stage.b12.resolution", false, true)
	expect(lobby.started.is_empty(), "resolution replay returns to the lobby without starting another battle")
	lobby.pending_stage = "b12"
	lobby.scene_finished("stage.b12.prelude", false, true)
	expect(lobby.started == "b12", "first-play prelude continues into its intended stage")
	lobby.pending_stage = "b12"
	lobby.scene_finished("stage.b12.prelude", true, false)
	expect(lobby.started == "b12" and lobby.pending_stage.is_empty(), "failed scene save does not bypass the prelude")
	lobby.free()
	var expedition := ExpeditionProbe.new()
	expedition.resolution_finished("stage.b19.resolution", false, true)
	expect(expedition.home_calls == 1, "final resolution continues directly into the home ending")
	expedition.resolution_finished("stage.b12.resolution", false, true)
	expect(expedition.home_calls == 1, "ordinary resolutions do not trigger the home ending")
	expedition.ready_to_close = true
	expedition.resolution_loading = true
	expect(not expedition.can_close(), "result cannot close while a story snapshot is loading")
	expedition.resolution_loading = false
	expedition.scene_player = Control.new()
	expect(not expedition.can_close(), "result cannot close behind an active story scene")
	expedition.scene_player.free()
	expedition.free()
	await process_frame

func _run() -> void:
	root.size = Vector2i(1440, 900)
	campaign = JSON.parse_string(FileAccess.get_file_as_string("res://data/adventure-campaign.v1.json"))
	expect(campaign.get("story_title") == "按时吃饭", "approved story title")
	expect(campaign.get("chapters", []).size() == 9 and campaign.get("stages", []).size() == 20, "nine chapters and twenty stages")
	var scenes := 0
	for row in campaign.get("stages", []):
		expect(not row.get("prelude", []).is_empty() and not row.get("resolution", []).is_empty(), "prelude and resolution: " + row.stage_id)
		scenes += 2
		for line in row.prelude + row.resolution:
			expect(not str(line.get("speaker", "")).is_empty() and not str(line.get("text", "")).is_empty(), "spoken line is complete: " + row.stage_id)
	expect(scenes == 40, "forty stage scenes")
	expect(campaign.get("ending_scene", {}).get("kind") == "ending" and campaign.ending_scene.dialogue.size() == 14, "independent home ending")
	for id in ["b00", "b03", "b12", "b15", "b19"]:
		var row := stage(id)
		expect(not row.get("entrance", {}).is_empty(), "custom entrance: " + id)
		for key in ["entry", "phase", "low_hp", "defeat"]:
			expect(row.get("barks", {}).has(key), "boss bark %s %s" % [id, key])
	for path in ["res://scripts/story_panel.gd", "res://scripts/expedition_lobby.gd", "res://scripts/expedition_view.gd", "res://scripts/story_scene_player.gd", "res://scripts/story_prop.gd"]:
		expect(load(path) != null, "script parses: " + path)

	var kernel := FakeKernel.new()
	root.add_child(kernel)
	var letter := make_player(scene_for("b12", "resolution"), kernel, true)
	await process_frame
	expect(letter.body_label.text == "……", "b12 defeat begins with restraint")
	letter.advance()
	expect(letter.body_label.text == "按时吃饭。" and letter.art_panel.art == "letter_changed", "letter is changed to the recurring meal line")
	await capture("story-p0-letter")
	await letter._finish(true)
	await process_frame
	expect(kernel.calls.size() == 1 and kernel.calls[0].command == "story.advance", "skip persists exactly one scene marker")
	expect(kernel.calls[0].payload.get("node_id") == "stage.b12.resolution", "marker uses authoritative scene id")
	expect(not kernel.calls[0].payload.has("reward") and not kernel.calls[0].payload.has("won"), "scene skip cannot submit rewards or victory")

	var replay := make_player(scene_for("b00", "prelude"), kernel, false)
	await process_frame
	await replay._finish(false)
	await process_frame
	expect(kernel.calls.size() == 1, "replay does not write another marker")

	var home: Dictionary = campaign.ending_scene
	var ending := make_player(home, kernel, true)
	await process_frame
	ending.index = 9
	ending._show_line()
	expect(ending.body_label.text == "咸不咸？" and ending.art_panel.art == "noodles", "home ending lands on the quiet meal exchange")
	await capture("story-p0-home")
	await ending._finish(false)
	await process_frame
	expect(kernel.calls.size() == 2 and kernel.calls[1].payload.get("node_id") == "ending.home", "home ending has its own idempotent marker")

	for combo in [["female", "female"], ["male", "female"], ["male", "male"]]:
		var variant_ending := make_player(home, kernel, false, combo[0], combo[1])
		await process_frame
		variant_ending.index = 9
		variant_ending._show_line()
		expect(variant_ending.art_panel.protagonist == combo[0] and variant_ending.art_panel.companion == combo[1], "ending preserves both independent appearance choices: %s/%s" % [combo[0], combo[1]])
		await capture("story-p0-home-%s-%s" % [combo[0], combo[1]])
		await variant_ending._finish(false)
		await process_frame
	expect(kernel.calls.size() == 2, "appearance-only ending replays never write additional markers")
	var art_source := FileAccess.get_file_as_string("res://scripts/story_prop.gd")
	var player_source := FileAccess.get_file_as_string("res://scripts/story_scene_player.gd")
	expect(not art_source.contains("func _person"), "block-person placeholder drawing is removed")
	expect(art_source.contains("按时吃饭。") and art_source.contains("draw_string"), "the old letter contains real readable copy")
	expect(player_source.contains("art_panel.queue_redraw()"), "dialogue art changes trigger an actual redraw")

	var touch_player := make_player(scene_for("b03", "prelude"), kernel, true)
	await process_frame
	await tap(touch_player.next_button)
	expect(touch_player.index == 1, "simulated touch advances the shared story player")
	await tap(touch_player.skip_button)
	expect(kernel.calls.size() == 3 and kernel.calls[2].payload.get("node_id") == "stage.b03.prelude", "simulated touch can skip and save once")
	await process_frame
	var offline := make_player(scene_for("b00", "prelude"), null, true)
	await process_frame
	var offline_saved := [true]
	offline.finished.connect(func(_id, _skip, saved): offline_saved[0] = saved)
	await offline._finish(true)
	expect(not offline_saved[0], "missing save service is reported as unsaved")
	await process_frame
	await test_resume_and_replay()
	await test_boss_performance()
	var report := {"checks": checks, "failures": failures, "captures": captures}
	var file := FileAccess.open("res://output/story-p0-report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("STORY_P0_RENDER_TEST: %d assertions; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
