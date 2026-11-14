extends SceneTree

class Options:
	extends Node
	var settings_open := false
	func begin_settings(_owner: Node) -> void: settings_open=true
	func end_settings(_owner: Node) -> void: settings_open=false

class Battle:
	extends Control
	func touch_actions_active() -> bool: return true
	func battle_action_state() -> Array: return []

var failures := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print("TOUCH_OPTIONS ", "PASS " if ok else "FAIL ", label)
	if not ok: failures+=1

func touch(index: int, point: Vector2, pressed: bool, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.index=index
	event.position=point
	event.pressed=pressed
	event.canceled=canceled
	root.push_input(event,true)
	await process_frame

func run() -> void:
	for action in ["move_left","move_right","move_forward","move_back","sprint"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	var options: Node=root.get_node_or_null("GameOptions")
	if options==null:
		options=Options.new()
		options.name="GameOptions"
		root.add_child(options)
	var pad: Node=root.get_node("TouchControls")
	pad.force_show=true
	pad._set_enabled(true)
	var battle := Battle.new()
	root.add_child(battle)
	pad.bind_battle(battle)
	await process_frame
	await touch(0,pad._joystick_center()+Vector2(pad._joystick_radius()*0.95,0),true)
	check(Input.get_action_strength("move_right")>0.5,"A real touch holds movement")
	check(pad._captured_fingers.has(0),"Joystick finger is captured")
	options.begin_settings(battle)
	await process_frame
	await process_frame
	check(not pad.surface.visible,"Settings hide battle touch controls")
	check(not Input.is_action_pressed("move_right"),"Opening settings releases held movement")
	check(pad._captured_fingers.is_empty() and pad._joystick_index==-1,"Opening settings releases captured fingers")
	options.end_settings(battle)
	await process_frame
	check(not Input.is_action_pressed("move_right"),"Closing settings does not revive an old finger")
	await touch(1,pad._joystick_center()+Vector2(pad._joystick_radius()*0.95,0),true)
	check(Input.get_action_strength("move_right")>0.5,"A fresh touch works after settings close")
	await touch(1,Vector2.ZERO,false,true)
	check(not Input.is_action_pressed("move_right"),"Canceled touch releases movement")
	pad.unbind_battle(battle)
	battle.queue_free()
	await process_frame
	pad._layout()
	var sprint: Dictionary=pad._buttons.filter(func(button):return button.kind=="sprint")[0]
	await touch(2,sprint.center,true)
	check(Input.is_action_pressed("sprint"),"Exploration sprint is held by a real touch")
	options.begin_settings(pad)
	await process_frame
	await process_frame
	check(not Input.is_action_pressed("sprint") and pad._captured_fingers.is_empty(),"Settings release held sprint and its finger")
	options.end_settings(pad)
	pad._reset_state()
	print("TOUCH_OPTIONS_TEST: ",failures," failures")
	quit(1 if failures else 0)
