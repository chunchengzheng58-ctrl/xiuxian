extends SceneTree
var scene: Node
func _initialize() -> void: run.call_deferred()
func run() -> void:
	scene=load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override="res://work/playtests/touch-layout-cache"
	scene.account_legacy_source_override="res://work/playtests/missing-touch-legacy.json"
	root.add_child(scene)
	current_scene=scene
	scene.account_api.allow_autostart=false
	await process_frame
	scene.ui.close_modal(true)
	var pad: Node=root.get_node("TouchControls")
	pad._set_enabled(true)
	await process_frame
	var target: Button
	for button in scene.ui.find_children("*","Button",true,false):
		if button.text=="五域游历 / 主线": target=button
	var pressed := [false]
	target.pressed.connect(func():pressed[0]=true)
	var point: Vector2=target.get_global_rect().get_center()
	var captured_on_press := false
	for down in [true,false]:
		var event := InputEventScreenTouch.new()
		event.index=0
		event.position=point
		event.pressed=down
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await process_frame
		await process_frame
		if down: captured_on_press=pad._captured_fingers.has(0)
	print("TOUCH_LAYOUT_PROBE: ",JSON.stringify({"point":[point.x,point.y],"joystick":[pad._joystick_center().x,pad._joystick_center().y],"captured_by_overlay":captured_on_press,"button_pressed":pressed[0],"modal_open":scene.ui.modal_open,"touch_controls":pad.controls_enabled(),"emulate_mouse":Input.is_emulating_mouse_from_touch()}))
	scene.queue_free()
	await process_frame
	quit()
