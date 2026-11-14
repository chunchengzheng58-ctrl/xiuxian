extends SceneTree

var failures := 0
var scene: Node

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("BATTLE_VIEW ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func fighter() -> Dictionary:
	return {"x": 520, "y": 570, "fx": 1, "hp": 100, "max_hp": 100, "mp": 100, "max_mp": 100, "stamina": 100, "max_stamina": 100,
		"ack": 0, "online": true, "shield": 0, "dash": false, "hit": false, "pose": "idle", "cd": [0, 0, 0, 0, 0, 0]}

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	scene.ui.close_modal(true)
	scene.ui.open_duel_battle("reclaimed-duel")
	var duel = scene.ui.duel_view
	var snapshot := {"match_id": "reclaimed-duel", "seat": 0, "tick": 300, "phase": "fighting", "seconds": 70,
		"players": [fighter(), fighter()], "names": ["甲", "乙"], "avatars": ["male", "female"], "blades": [], "result": null}
	duel.receive_state(snapshot)
	var stale := snapshot.duplicate(true)
	stale.tick = 20
	stale.seconds = 89
	duel.receive_state(stale)
	check(duel.state.seconds == 70, "Older active PVP packets cannot roll the fight backward")
	stale.tick = 0
	stale.phase = "finished"
	stale.result = {"winner": null, "reason": "interrupted", "hp": [100, 100]}
	duel.receive_state(stale)
	check(duel.can_close() and is_instance_valid(duel.result_panel), "Reclaimed PVP room result closes a previously connected view")
	scene.ui.close_modal(true)
	scene.ui.open_expedition_battle("reclaimed-expedition")
	var expedition = scene.ui.expedition_view
	var state := {"run_id": "reclaimed-expedition", "boss_id": "b01", "stage_id": "b01", "tick": 300, "phase": "fighting", "seconds": 160,
		"player": fighter(), "enemy": fighter(), "telegraphs": [], "hazards": [], "blades": [], "result": null}
	expedition.receive_state(state)
	stale = state.duplicate(true)
	stale.tick = 20
	stale.seconds = 179
	expedition.receive_state(stale)
	check(expedition.state.seconds == 160, "Older active PVE packets cannot roll the fight backward")
	stale.tick = 0
	stale.phase = "finished"
	stale.result = {"won": false, "reason": "interrupted", "reward": {"spirit_stones": 0, "materials": 0, "first_clear": false, "equipment": null}}
	expedition.receive_state(stale)
	check(expedition.can_close() and is_instance_valid(expedition.result_panel), "Reclaimed PVE room result closes a previously connected view")
	scene.ui.close_modal(true)
	scene.queue_free()
	await process_frame
	print("BATTLE_VIEW_TEST: ", failures, " failures")
	quit(1 if failures else 0)
