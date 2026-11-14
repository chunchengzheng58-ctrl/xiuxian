extends Node
## Read-only bridge for the actual Web touch test. This script accepts no game
## commands, synthetic movement, mouse clicks, rewards, or combat actions.
var scene: Node
var browser: JavaScriptObject
var handling := false
var touch_events := 0
var drag_events := 0
var root: Window:
	get: return get_tree().root

func _ready() -> void: boot.call_deferred()

func boot() -> void:
	browser=JavaScriptBridge.get_interface("window")
	scene=load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override="user://touch-online-tests"
	scene.account_legacy_source_override="user://missing-touch-legacy.json"
	root.add_child(scene)
	get_tree().current_scene=scene
	scene.account_api.allow_autostart=false
	await get_tree().process_frame
	scene.ui.open_login()
	browser.__touchReady=true

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch: touch_events+=1
	if event is InputEventScreenDrag: drag_events+=1

func _process(_delta: float) -> void:
	if browser!=null and not handling and browser.__touchRequest!=null:
		var request: Variant=JSON.parse_string(str(browser.__touchRequest))
		browser.__touchRequest=null
		if request is Dictionary:
			handling=true
			handle.call_deferred(request)

func handle(request: Dictionary) -> void:
	var result: Dictionary=inspect() if request.get("op")=="inspect" else {"ok":false,"message":"Touch bridge is read-only"}
	browser.__touchResult=JSON.stringify({"id":request.id,"result":result})
	handling=false

func rect_data(rect: Rect2) -> Dictionary:
	return {"x":rect.position.x,"y":rect.position.y,"width":rect.size.x,"height":rect.size.y}

func clip_rect(control: Control) -> Rect2:
	var rect:=control.get_global_rect().intersection(root.get_visible_rect())
	var parent: Node=control.get_parent()
	while parent!=null:
		if parent is Control and (parent.clip_contents or parent is ScrollContainer): rect=rect.intersection(parent.get_global_rect())
		parent=parent.get_parent()
	return rect

func ancestor_scroll(control: Control) -> String:
	var parent: Node=control.get_parent()
	while parent!=null:
		if parent is ScrollContainer: return str(parent.get_path())
		parent=parent.get_parent()
	return ""

func ancestor_scrolls(control: Control) -> Array:
	var paths: Array=[]
	var parent: Node=control.get_parent()
	while parent!=null:
		if parent is ScrollContainer: paths.append(str(parent.get_path()))
		parent=parent.get_parent()
	return paths

func inspect() -> Dictionary:
	var buttons: Array=[]
	var fields: Array=[]
	var scrolls: Array=[]
	var labels: Array=[]
	for node in root.find_children("*","Control",true,false):
		if not node.is_visible_in_tree(): continue
		if node is Button:
			buttons.append({"path":str(node.get_path()),"text":node.text,"disabled":node.disabled,"pressed":node.button_pressed,"rect":rect_data(node.get_global_rect()),"clip":rect_data(clip_rect(node)),"scroll":ancestor_scroll(node),"scroll_chain":ancestor_scrolls(node),"tooltip":node.tooltip_text})
		if node is LineEdit:
			fields.append({"path":str(node.get_path()),"placeholder":node.placeholder_text,"value":"" if node.secret else node.text,"length":node.text.length(),"rect":rect_data(node.get_global_rect()),"clip":rect_data(clip_rect(node)),"scroll":ancestor_scroll(node),"secret":node.secret})
		if node is ScrollContainer:
			scrolls.append({"path":str(node.get_path()),"rect":rect_data(node.get_global_rect()),"clip":rect_data(clip_rect(node)),"value":node.scroll_vertical,"maximum":node.get_v_scroll_bar().max_value,"page":node.get_v_scroll_bar().page})
		if node is Label: labels.append(node.text)
	var pad: Node=root.get_node_or_null("TouchControls")
	var pad_state: Dictionary={}
	if pad!=null:
		var center: Vector2=pad._joystick_center()
		var battle_buttons: Array=[]
		for button in pad._battle_buttons:
			battle_buttons.append({"id":button.id,"label":button.label,"disabled":button.disabled,"cooldown":button.cooldown,"x":button.center.x,"y":button.center.y,"radius":button.radius})
		pad_state={"enabled":pad.controls_enabled(),"visible":pad.surface.visible,"active":pad._active(),"joystick":{"x":center.x,"y":center.y,"radius":pad._joystick_radius()},"captured":pad._captured_fingers.keys(),"move_x":Input.get_action_strength("move_right")-Input.get_action_strength("move_left"),"move_y":Input.get_action_strength("move_back")-Input.get_action_strength("move_forward"),"buttons":battle_buttons}
	var options: Node=root.get_node_or_null("GameOptions")
	var audio: Node=root.get_node_or_null("GameAudio")
	var result: Dictionary={"ok":true,"ready":scene.account_ready,"remote":scene.state.is_remote(),"actor":scene.state.cultivator_id,"viewport":rect_data(root.get_visible_rect()),"buttons":buttons,"fields":fields,"scrolls":scrolls,"labels":labels,"touch":pad_state,"touch_events":touch_events,"drag_events":drag_events,"settings_open":options.get("settings_open")==true if options!=null else false,"equipment":scene.state.equipment,"adventure":scene.state.adventure}
	if is_instance_valid(scene.ui.story_panel): result["story"]=scene.ui.story_panel.current
	if is_instance_valid(scene.ui.expedition_view): result["expedition"]=scene.ui.expedition_view.state
	if is_instance_valid(scene.ui.treasure): result["treasure"]={"tab":scene.ui.treasure.tab,"busy":scene.ui.treasure.busy,"submitting":scene.ui.treasure.is_submitting()}
	if audio!=null: result["audio"]={"unlocked":audio.unlocked,"context":audio.current_context,"effects_played":audio._cursor,"music_playing":is_instance_valid(audio._music) and audio._music.playing}
	if options!=null: result["options"]=options.values
	return result
