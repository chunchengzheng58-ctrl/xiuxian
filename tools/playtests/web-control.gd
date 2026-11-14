extends Node
## Loaded only into the test browser's virtual FS; never included in release PCK.
## Drives the production scene through its real form controls and input events.
var scene: Node
var browser: JavaScriptObject
var handling := false
var root: Window:
	get: return get_tree().root

func _ready() -> void:
	boot.call_deferred()

func boot() -> void:
	browser = JavaScriptBridge.get_interface("window")
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = "user://web-online-tests"
	scene.account_legacy_source_override = "user://missing-legacy-test.json"
	root.add_child(scene)
	get_tree().current_scene = scene
	scene.account_api.allow_autostart = false
	await get_tree().process_frame
	scene.ui.open_login()
	browser.__gameReady = true

func _process(_delta: float) -> void:
	if browser != null and not handling and browser.__gameRequest != null:
		var request: Variant = JSON.parse_string(str(browser.__gameRequest))
		browser.__gameRequest = null
		if request is Dictionary:
			handling = true
			handle.call_deferred(request)

func handle(request: Dictionary) -> void:
	var result: Dictionary = await perform(request)
	await get_tree().process_frame
	await get_tree().process_frame
	browser.__gameResult = JSON.stringify({"id": request.id, "result": result})
	handling = false

func perform(request: Dictionary) -> Dictionary:
	match request.op:
		"inspect": return inspect()
		"login":
			var panel = scene.ui.account_panel
			panel.username_input.text = request.username
			panel.password_input.text = request.password
			panel.submit()
		"field":
			for field in scene.ui.find_children("*", "LineEdit", true, false):
				if field.is_visible_in_tree() and (str(field.get_path()) == request.get("path", "") or field.placeholder_text == request.get("placeholder", "!")):
					field.text = request.value
					field.text_changed.emit(field.text)
					return {"ok": true}
			return {"ok": false, "message": "Field not found"}
		"select":
			for option in scene.ui.find_children("*", "OptionButton", true, false):
				if not option.is_visible_in_tree(): continue
				for index in range(option.item_count):
					if option.get_item_text(index) == request.text:
						option.select(index)
						option.item_selected.emit(index)
						return {"ok": true}
			return {"ok": false, "message": "Option not found"}
		"click":
			for button in scene.ui.find_children("*", "Button", true, false):
				if not button.is_visible_in_tree() or button.disabled: continue
				var matched: bool = str(button.get_path()) == request.get("path", "") or (button.text.begins_with(request.text) if request.get("prefix", false) else button.text == request.get("text", "!"))
				if matched:
					return {"ok": await click(button), "message": "Mouse event must reach the visible button"}
			return {"ok": false, "message": "Button not found: " + str(request.get("text", ""))}
		"confirm":
			for dialog in scene.ui.find_children("*", "ConfirmationDialog", true, false):
				if dialog.visible:
					dialog.get_ok_button().pressed.emit()
					return {"ok": true}
			return {"ok": false, "message": "No confirmation dialog"}
		"key":
			for down in [true, false]:
				var event := InputEventKey.new()
				event.keycode = int(request.code)
				event.physical_keycode = int(request.code)
				event.pressed = down
				Input.parse_input_event(event)
				Input.flush_buffered_events()
				await get_tree().process_frame
		"move":
			for action in ["move_left", "move_right", "move_forward", "move_back"]: Input.action_release(action)
			var x := float(request.x)
			var y := float(request.y)
			if x < -0.1: Input.action_press("move_left", minf(1, -x))
			if x > 0.1: Input.action_press("move_right", minf(1, x))
			if y < -0.1: Input.action_press("move_forward", minf(1, -y))
			if y > 0.1: Input.action_press("move_back", minf(1, y))
		"action":
			var view = scene.ui.expedition_view if is_instance_valid(scene.ui.expedition_view) else scene.ui.duel_view
			if not is_instance_valid(view): return {"ok": false, "message": "No battle"}
			view.queue_action(int(request.action))
		"skip":
			if is_instance_valid(scene.ui.treasure): scene.ui.treasure.finish_reveal()
		_: return {"ok": false, "message": "Unknown test action"}
	return {"ok": true}

func click(button: Button) -> bool:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(button): return false
	var received := [false]
	button.pressed.connect(func(): received[0] = true, CONNECT_ONE_SHOT)
	var point: Vector2 = button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)
		await get_tree().process_frame
	return received[0]

func inspect() -> Dictionary:
	var buttons: Array = []
	var fields: Array = []
	var labels: Array = []
	for button in scene.ui.find_children("*", "Button", true, false):
		if button.is_visible_in_tree():
			buttons.append({"path": str(button.get_path()), "text": button.text, "disabled": button.disabled, "tooltip": button.tooltip_text, "x": button.global_position.x, "y": button.global_position.y, "width": button.size.x, "height": button.size.y})
	for field in scene.ui.find_children("*", "LineEdit", true, false):
		if field.is_visible_in_tree(): fields.append({"path": str(field.get_path()), "placeholder": field.placeholder_text, "value": "" if field.secret else field.text})
	for label in scene.ui.find_children("*", "Label", true, false):
		if label.is_visible_in_tree(): labels.append(label.text)
	var result := {"ok": true, "ready": scene.account_ready, "remote": scene.state.is_remote(), "actor": scene.state.cultivator_id, "equipment": scene.state.equipment, "buttons": buttons, "fields": fields, "labels": labels}
	if is_instance_valid(scene.ui.expedition_view): result["expedition"] = scene.ui.expedition_view.state
	if is_instance_valid(scene.ui.duel_view): result["duel"] = scene.ui.duel_view.state
	if is_instance_valid(scene.ui.treasure):
		result["tab"] = scene.ui.treasure.tab
		result["submitting"] = scene.ui.treasure.is_submitting()
		result["busy"] = scene.ui.treasure.busy
	return result
