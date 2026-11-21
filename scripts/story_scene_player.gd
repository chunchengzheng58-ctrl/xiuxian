extends Control
## One player for first-run scenes, skips, replays and the home ending.
signal finished(scene_id: String, skipped: bool, saved: bool)

const StoryProp = preload("res://scripts/story_prop.gd")
var scene_data: Dictionary = {}
var kernel: Node
var cultivator_id: String = ""
var variants: Dictionary = {}
var persist_marker: bool = true
var index: int = 0
var saving: bool = false

var art_panel: Control
var title_label: Label
var progress_label: Label
var speaker_label: Label
var body_label: Label
var status_label: Label
var portrait_frame: Panel
var portrait_image: TextureRect
var present_actor := ""
var art_tween: Tween
var previous_button: Button
var next_button: Button
var skip_button: Button
const MODAL_LAYER := 100

# z_index on a root Control cannot outrank the village HUD's CanvasLayer.
# Use one shared high-priority layer for every real entry and destroy it with
# the player, so replays cannot accumulate invisible players or draw calls.
static func mount(player: Control, root: Window) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = MODAL_LAYER
	root.add_child(layer)
	layer.add_child(player)
	player.tree_exited.connect(func():
		if is_instance_valid(layer) and not layer.is_queued_for_deletion():
			layer.queue_free()
	)
	return layer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 300
	var shade := ColorRect.new()
	shade.color = Color(0.035, 0.055, 0.052, 0.97)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	art_panel = StoryProp.new()
	art_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art_panel.offset_left = 28
	art_panel.offset_top = 76
	art_panel.offset_right = -28
	art_panel.offset_bottom = -258
	art_panel.protagonist = str(variants.get("protagonist", "male"))
	art_panel.companion = str(variants.get("companion", "female"))
	art_panel.stage_id = str(scene_data.get("stage_id", ""))
	add_child(art_panel)

	title_label = _label(str(scene_data.get("title", "灯下旧事")), 28, Color("ead9b6"))
	title_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	title_label.position = Vector2(34, 20)
	title_label.size = Vector2(780, 46)
	add_child(title_label)
	progress_label = _label("", 17, Color("9f9b88"))
	progress_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	progress_label.offset_left = -340
	progress_label.offset_top = 29
	progress_label.offset_right = -158
	progress_label.offset_bottom = 62
	progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(progress_label)
	skip_button = _button("跳过并保存" if persist_marker else "关闭回看", func(): _finish(true))
	skip_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	skip_button.offset_left = -145
	skip_button.offset_top = 18
	skip_button.offset_right = -28
	skip_button.offset_bottom = 64
	add_child(skip_button)

	var dialogue := Panel.new()
	dialogue.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	dialogue.offset_left = 28
	dialogue.offset_top = -244
	dialogue.offset_right = -28
	dialogue.offset_bottom = -24
	dialogue.add_theme_stylebox_override("panel", _style(Color("202c28"), Color("8b7350")))
	add_child(dialogue)
	var margins := MarginContainer.new()
	margins.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margins.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		margins.add_theme_constant_override("margin_" + side, 16)
	dialogue.add_child(margins)
	var dialogue_column := VBoxContainer.new()
	dialogue_column.add_theme_constant_override("separation", 9)
	margins.add_child(dialogue_column)
	var reading_row := HBoxContainer.new()
	reading_row.add_theme_constant_override("separation", 20)
	reading_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dialogue_column.add_child(reading_row)
	portrait_frame = Panel.new()
	portrait_frame.custom_minimum_size = Vector2(108, 112)
	portrait_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	portrait_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_frame.add_theme_stylebox_override("panel", _style(Color("17221f"), Color("695c46")))
	reading_row.add_child(portrait_frame)
	portrait_image = TextureRect.new()
	portrait_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait_image.offset_left = 5
	portrait_image.offset_top = 5
	portrait_image.offset_right = -5
	portrait_image.offset_bottom = -5
	portrait_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_frame.add_child(portrait_image)
	var text_column := VBoxContainer.new()
	text_column.add_theme_constant_override("separation", 7)
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	reading_row.add_child(text_column)
	speaker_label = _label("", 22, Color("d4b273"))
	text_column.add_child(speaker_label)
	body_label = _label("", 25, Color("f0e5ca"))
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_column.add_child(body_label)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 12)
	dialogue_column.add_child(action_row)
	status_label = _label("", 15, Color("9f9b88"))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	action_row.add_child(status_label)
	previous_button = _button("上一句", previous)
	previous_button.custom_minimum_size.x = 112
	action_row.add_child(previous_button)
	next_button = _button("继续  ·  空格", advance, true)
	next_button.custom_minimum_size.x = 184
	action_row.add_child(next_button)
	_show_line()

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12
	style.content_margin_right = 12
	return style

func _button(text: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(112, 45)
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_stylebox_override("normal", _style(Color("725037") if primary else Color("34433b"), Color("aa8b58")))
	button.add_theme_stylebox_override("hover", _style(Color("8b6542"), Color("d1b479")))
	button.add_theme_stylebox_override("pressed", _style(Color("4b3428"), Color("d1b479")))
	button.add_theme_stylebox_override("disabled", _style(Color("29332f"), Color("4f574e")))
	button.add_theme_color_override("font_color", Color("f3e6c7"))
	button.add_theme_color_override("font_hover_color", Color("fff3d5"))
	button.add_theme_color_override("font_disabled_color", Color("747a6e"))
	button.pressed.connect(callback)
	return button

func _show_line() -> void:
	var lines: Array = scene_data.get("dialogue", [])
	if lines.is_empty():
		_finish(false)
		return
	index = clampi(index, 0, lines.size() - 1)
	var row: Dictionary = lines[index]
	var speaker_name := str(row.get("speaker", "旁白"))
	if speaker_name == "阿宁留言":
		present_actor = ""
	elif speaker_name not in ["主角", "旁白"]:
		present_actor = speaker_name
	speaker_label.text = speaker_name
	body_label.text = str(row.get("text", ""))
	var next_art := str(row.get("art", scene_data.get("art", "lamp")))
	var art_changed: bool = str(art_panel.art) != next_art
	art_panel.art = next_art
	art_panel.speaker = speaker_name
	art_panel.actor_name = present_actor
	art_panel.queue_redraw()
	var portrait: Texture2D = art_panel.portrait_texture(speaker_name)
	portrait_image.texture = portrait
	portrait_frame.visible = portrait != null
	if art_tween and art_tween.is_valid():
		art_tween.kill()
	# Keep the illustration stable while reading; only a genuine art change gets
	# a very short fade. Re-fading the whole scene on every line looks like lag.
	art_panel.modulate.a = 1.0
	if art_changed:
		art_panel.modulate.a = 0.94
		art_tween = create_tween()
		art_tween.tween_property(art_panel, "modulate:a", 1.0, 0.08)
	progress_label.text = "%02d / %02d%s" % [index + 1, lines.size(), " · 回看" if not persist_marker else ""]
	previous_button.disabled = index == 0 or saving
	next_button.text = "看完，回去" if index == lines.size() - 1 else "继续  ·  空格"
	status_label.text = "空格继续 · 跳过只记录场景，不发奖励" if persist_marker else "回看不会改变奖励、通关或真相旗标"

func previous() -> void:
	if saving or index <= 0:
		return
	index -= 1
	_show_line()

func advance() -> void:
	if saving:
		return
	var lines: Array = scene_data.get("dialogue", [])
	if index >= lines.size() - 1:
		_finish(false)
		return
	index += 1
	_show_line()

func _input(event: InputEvent) -> void:
	if saving or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode in [KEY_SPACE, KEY_ENTER, KEY_RIGHT]:
		advance()
	elif event.keycode == KEY_LEFT:
		previous()
	else:
		return
	get_viewport().set_input_as_handled()

func _finish(skipped: bool) -> void:
	if saving:
		return
	saving = true
	previous_button.disabled = true
	next_button.disabled = true
	skip_button.disabled = true
	status_label.text = "正在保存场景标记…" if persist_marker else ""
	var saved := true
	if persist_marker:
		if is_instance_valid(kernel) and not cultivator_id.is_empty():
			var result: Dictionary = await kernel.dispatch("story.advance", {"cultivator_id": cultivator_id, "node_id": str(scene_data.get("scene_id", ""))})
			saved = bool(result.get("ok", false))
			if not saved:
				status_label.text = "标记未同步；下次可重新播放。"
				push_warning("Story scene marker failed: " + str(result.get("message", "unknown error")))
		else:
			saved = false
			status_label.text = "存档服务未连接；下次可重新播放。"
	finished.emit(str(scene_data.get("scene_id", "")), skipped, saved)
	queue_free()
