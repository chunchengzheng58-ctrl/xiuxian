extends SceneTree
## Render all 41 formal scenes and produce nine chapter review sheets.
const Player = preload("res://scripts/story_scene_player.gd")
const StoryProp = preload("res://scripts/story_prop.gd")
var checks := 0
var failures: Array[String] = []
var scene_captures: Array[Dictionary] = []
var chapter_captures: Dictionary = {}
var campaign: Dictionary = {}

func expect(value: bool, title: String) -> void:
	checks += 1
	if not value:
		failures.append(title)
		printerr("FAIL: ", title)

func _initialize() -> void:
	_run.call_deferred()

func scene_for(row: Dictionary, kind: String) -> Dictionary:
	return {"scene_id": "stage.%s.%s" % [row.stage_id, kind], "title": row.name, "kind": kind,
		"stage_id": row.stage_id, "art": row.entrance.style, "dialogue": row[kind]}

func make_player(scene: Dictionary, hero: String, companion: String) -> Control:
	var player := Player.new()
	player.scene_data = scene.duplicate(true)
	player.variants = {"protagonist": hero, "companion": companion}
	player.persist_marker = false
	root.add_child(player)
	return player

func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	expect(image != null and not image.is_empty(), "render exists: " + name)
	if image != null and not image.is_empty():
		expect(image.get_size() == Vector2i(1440, 900), "full-size capture: " + name)
		expect(image.save_png("res://output/story-refined/" + name + ".png") == OK, "save capture: " + name)

func representative(scene: Dictionary) -> int:
	var lines: Array = scene.dialogue
	if scene.scene_id == "stage.b12.resolution": return 1
	if scene.scene_id == "ending.home": return 9
	for index in range(lines.size()):
		if lines[index].has("art"):
			return index
	return maxi(0, lines.size() - 1)

func render_scene(scene: Dictionary, chapter: String, caption: String, hero: String, companion: String, count_scene: bool = true, forced_index: int = -1) -> void:
	var player := make_player(scene, hero, companion)
	await process_frame
	var lines: Array = scene.dialogue
	expect(not lines.is_empty(), "dialogue exists: " + scene.scene_id)
	for index in range(lines.size()):
		player.index = index
		player._show_line()
		await process_frame
		var row: Dictionary = lines[index]
		var expected_art := str(row.get("art", scene.get("art", "lamp")))
		expect(player.art_panel.art == expected_art, "line art is live: %s/%d" % [scene.scene_id, index])
		expect(player.body_label.text == str(row.text), "native dialogue text: %s/%d" % [scene.scene_id, index])
		if str(row.speaker) != "旁白":
			expect(player.portrait_image.texture != null and player.portrait_frame.visible, "speaker portrait: %s/%d/%s" % [scene.scene_id, index, row.speaker])
		if index > 0 and str(row.speaker) == "主角":
			var previous := str(lines[index - 1].speaker)
			if previous not in ["主角", "旁白", "阿宁留言"]:
				expect(player.art_panel.actor_name == previous, "interlocutor remains on stage: %s/%d" % [scene.scene_id, index])
		var key: String = player.art_panel.prop_key(expected_art)
		if not key.is_empty():
			expect(player.art_panel.prop_texture(expected_art) != null, "formal prop loaded: %s/%s" % [scene.scene_id, key])
	var selected := representative(scene) if forced_index < 0 else forced_index
	player.index = clampi(selected, 0, lines.size() - 1)
	player._show_line()
	var file_name := str(scene.scene_id).replace("stage.", "").replace(".", "-")
	if forced_index >= 0:
		file_name += "-%02d" % forced_index
	await capture(file_name)
	var item := {"path": "res://output/story-refined/" + file_name + ".png", "caption": caption, "scene_id": scene.scene_id}
	if count_scene:
		scene_captures.append(item)
	if not chapter_captures.has(chapter):
		chapter_captures[chapter] = []
	chapter_captures[chapter].append(item)
	player.queue_free()
	await process_frame

func contact_sheet(chapter: String, title: String, items: Array) -> void:
	var canvas := Control.new()
	root.add_child(canvas)
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("111b19")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(background)
	var heading := Label.new()
	heading.text = title + "｜逐场景实渲"
	heading.position = Vector2(26, 14)
	heading.size = Vector2(1200, 44)
	heading.add_theme_font_size_override("font_size", 25)
	heading.add_theme_color_override("font_color", Color("ead9b6"))
	canvas.add_child(heading)
	for index in range(items.size()):
		var column := index % 3
		var row := index / 3
		var origin := Vector2(18 + column * 476, 66 + row * 410)
		var frame := Panel.new()
		frame.position = origin
		frame.size = Vector2(464, 394)
		var style := StyleBoxFlat.new()
		style.bg_color = Color("1d2925")
		style.border_color = Color("756448")
		style.set_border_width_all(1)
		style.set_corner_radius_all(7)
		frame.add_theme_stylebox_override("panel", style)
		canvas.add_child(frame)
		var texture := ImageTexture.create_from_image(Image.load_from_file(str(items[index].path)))
		var image := TextureRect.new()
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.position = Vector2(7, 7)
		image.size = Vector2(450, 330)
		image.texture = texture
		frame.add_child(image)
		var label := Label.new()
		label.text = str(items[index].caption)
		label.position = Vector2(12, 343)
		label.size = Vector2(440, 38)
		label.add_theme_font_size_override("font_size", 19)
		label.add_theme_color_override("font_color", Color("e2d5bb"))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		frame.add_child(label)
	await capture("chapter-" + chapter)
	canvas.queue_free()
	await process_frame

func _run() -> void:
	root.size = Vector2i(1440, 900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://output/story-refined"))
	campaign = JSON.parse_string(FileAccess.get_file_as_string("res://data/adventure-campaign.v1.json"))
	var probe := StoryProp.new()
	for key in StoryProp.PROP_FILES:
		var texture: Texture2D = probe.prop_texture(key)
		expect(texture != null and texture.get_width() > 32, "validated prop cell exists: " + key)
	probe.free()
	var combos := [["female", "male"], ["male", "female"], ["female", "female"], ["male", "male"]]
	var chapter_names := {}
	for chapter in campaign.chapters:
		chapter_names[chapter.id] = str(chapter.region) + " · " + str(chapter.title)
	for stage_index in range(campaign.stages.size()):
		var row: Dictionary = campaign.stages[stage_index]
		var combo: Array = combos[stage_index % combos.size()]
		for kind in ["prelude", "resolution"]:
			var suffix := "战前" if kind == "prelude" else "战后"
			await render_scene(scene_for(row, kind), str(row.chapter_id), "%s · %s · %s" % [row.stage_id, row.name, suffix], combo[0], combo[1])
	var ending: Dictionary = campaign.ending_scene
	await render_scene(ending, "finale", "回村 · 咸不咸", "female", "male")
	await render_scene(ending, "finale", "回村 · 同桌三人", "male", "female", false, 0)
	await render_scene(ending, "finale", "回村 · 灶边旧碗筷", "female", "female", false, 6)
	await render_scene(ending, "finale", "回村 · 院门未关", "male", "male", false, 13)
	expect(scene_captures.size() == 41, "exactly forty-one formal scenes rendered")
	for chapter in chapter_names:
		await contact_sheet(chapter, str(chapter_names[chapter]), chapter_captures.get(chapter, []))
	var report := {"checks": checks, "failures": failures, "formal_scene_count": scene_captures.size(), "captures": scene_captures, "chapter_sheets": chapter_captures.keys()}
	var file := FileAccess.open("res://output/story-refined/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("STORY_VISUAL_P1_TEST: %d assertions; %d failures; %d formal scenes" % [checks, failures.size(), scene_captures.size()])
	quit(0 if failures.is_empty() else 1)
