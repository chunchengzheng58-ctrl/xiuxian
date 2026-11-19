extends Control
## P1 story presentation: real actors, validated transparent props, native readable copy.
const Assets = preload("res://scripts/pixel_assets.gd")
const Catalogue = preload("res://scripts/trial_catalogue.gd")
const VILLAGE = "res://assets/pixel/village-background.png"
const MOTHER = "res://assets/story_characters/mother.png"
const ANING = "res://assets/story_characters/aning.png"
const HERO_MALE = "res://assets/pixel/cultivator-walk.png"
const HERO_FEMALE = "res://assets/gameplay/female-walk-v2.png"
const VILLAGE_NPCS = "res://assets/pixel/village-npcs.png"
const NPC_SHEET = "res://assets/pixel_campaign/npc_sheet.png"
const PROP_DIR = "res://assets/story_props/cells/"
const PROP_FILES = {
	"lamp": "00-lamp.png", "tree": "01-tree.png", "rations": "02-rations.png",
	"rope": "03-rope.png", "boat": "04-boat.png", "map": "05-map.png",
	"chess": "06-chess.png", "compass": "07-compass.png", "letter": "08-letter.png",
	"noodle_bowl": "09-noodle_bowl.png", "old_bowl": "10-old_bowl.png", "travel_pack": "11-travel_pack.png"
}
const HOME_ART = ["home", "village_return", "old_bowl", "noodles", "chopsticks"]
const BOSS_SPEAKERS = ["听雷", "朽梁", "涩节", "窃荣", "乱律", "窄焰", "赤棘", "积璧", "薄丹", "失稷", "闭岚", "灼羽", "缄风", "沉砂", "滞潮", "壅川", "漏夜", "失简", "晦鳞", "执衡", "烬疫", "膨火", "滞垒", "田心", "磐首", "切锋", "锢羽", "蚀涟", "壅鳞", "刹羽", "魇灯", "忘机"]
const NPC_INDEX = {"雷叔": 0, "阿禾": 3, "木匠": 2, "刘婶": 1, "铁头": 2, "烬婶": 1, "石翁": 4, "田婆": 1, "素娘": 3, "汀兰": 1}

var art := "lamp"
var protagonist := "male"
var companion := "female"
var backdrop := true
var stage_id := ""
var speaker := ""
var actor_name := ""
var clock := 0.0
var redraw_clock := 0.0
const REDRAW_FPS := 30.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	# Battle corners are deliberately hidden most of the time. They must not
	# redraw a full set of textures while invisible.
	if not is_visible_in_tree():
		redraw_clock = 0.0
		return
	clock += delta
	redraw_clock += delta
	if redraw_clock >= 1.0 / REDRAW_FPS:
		redraw_clock = fmod(redraw_clock, 1.0 / REDRAW_FPS)
		queue_redraw()

func _draw() -> void:
	var sx := size.x / 640.0
	var sy := size.y / 320.0
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(sx, sy))
	if not backdrop:
		_prop(art, true)
		return
	_draw_background()
	if art in HOME_ART:
		_home()
	elif art in ["letter", "letter_changed"]:
		_letter(art == "letter_changed")
	else:
		_prop(art)
		_draw_story_characters()

func _draw_background() -> void:
	var path := VILLAGE
	if not stage_id.is_empty():
		var entry: Dictionary = Catalogue.entry(stage_id)
		path = str(entry.get("background", VILLAGE))
	var texture := Assets.texture(path)
	var palette := _chapter_palette()
	if texture != null:
		if stage_id.is_empty():
			draw_texture_rect_region(texture, Rect2(0, 0, 640, 320), Rect2(0, 140, 760, 380), palette.tint)
		else:
			_cover(texture, Rect2(0, 0, 640, 320), palette.tint)
	else:
		draw_rect(Rect2(0, 0, 640, 320), Color("25332f"))
	draw_rect(Rect2(0, 0, 640, 320), palette.wash)
	draw_rect(Rect2(0, 252, 640, 68), Color(0.025, 0.03, 0.032, 0.32))
	# Restrained vignette; no fog band is introduced behind the dialogue.
	for index in range(5):
		draw_rect(Rect2(index * 5, index * 4, 640 - index * 10, 320 - index * 8), Color(0.02, 0.025, 0.026, 0.025), false, 5)

func _chapter_palette() -> Dictionary:
	if stage_id.is_empty():
		return {"tint": Color(0.94, 0.85, 0.70), "wash": Color(0.15, 0.085, 0.035, 0.12)}
	var number := int(stage_id.trim_prefix("b"))
	if number <= 0:
		return {"tint": Color(0.82, 0.76, 0.64), "wash": Color(0.18, 0.11, 0.045, 0.18)}
	if number <= 3:
		return {"tint": Color(0.69, 0.79, 0.68), "wash": Color(0.035, 0.12, 0.075, 0.22)}
	if number <= 6:
		return {"tint": Color(0.84, 0.68, 0.56), "wash": Color(0.20, 0.055, 0.025, 0.20)}
	if number <= 9:
		return {"tint": Color(0.80, 0.75, 0.61), "wash": Color(0.14, 0.105, 0.045, 0.20)}
	if number <= 12:
		return {"tint": Color(0.69, 0.74, 0.78), "wash": Color(0.045, 0.065, 0.085, 0.24)}
	if number <= 15:
		return {"tint": Color(0.62, 0.78, 0.79), "wash": Color(0.025, 0.105, 0.12, 0.23)}
	if number <= 17:
		return {"tint": Color(0.66, 0.70, 0.76), "wash": Color(0.035, 0.055, 0.10, 0.25)}
	if number == 18:
		return {"tint": Color(0.71, 0.77, 0.74), "wash": Color(0.055, 0.095, 0.085, 0.23)}
	return {"tint": Color(0.80, 0.75, 0.65), "wash": Color(0.12, 0.085, 0.055, 0.23)}

func _cover(texture: Texture2D, target: Rect2, tint: Color = Color.WHITE) -> void:
	var dimensions := Vector2(texture.get_size())
	if dimensions.x <= 0 or dimensions.y <= 0:
		return
	var factor := maxf(target.size.x / dimensions.x, target.size.y / dimensions.y)
	var source_size := target.size / factor
	var source_position := (dimensions - source_size) * Vector2(0.5, 0.44)
	draw_texture_rect_region(texture, target, Rect2(source_position, source_size), tint)

func prop_key(art_name: String) -> String:
	if art_name in ["tree", "noodle_bowl", "travel_pack"]:
		return art_name
	match art_name:
		"lamp", "door_lamp": return "lamp"
		"tree_marks": return "tree"
		"marks": return "rope" if stage_id in ["b01", "b02", "b08", "b11"] else "tree"
		"rations": return "travel_pack" if stage_id in ["b09", "b10"] else "rations"
		"rope": return "rope"
		"boat": return "boat"
		"map": return "map"
		"chess", "tea", "cups": return "chess"
		"compass": return "compass"
		"letter", "letter_changed": return "letter"
		"noodles", "chopsticks": return "noodle_bowl"
		"old_bowl": return "old_bowl"
	return ""

func prop_texture(art_name: String) -> Texture2D:
	var key := prop_key(art_name)
	if not PROP_FILES.has(key):
		return null
	return Assets.texture(PROP_DIR + str(PROP_FILES[key]))

func _prop(art_name: String, corner: bool = false) -> void:
	var texture := prop_texture(art_name)
	if texture == null:
		return
	var key := prop_key(art_name)
	var bottom := Vector2(320, 278)
	var height := 205.0
	match key:
		"lamp": bottom = Vector2(322, 300); height = 258
		"tree": bottom = Vector2(322, 310); height = 282
		"rations", "travel_pack": bottom = Vector2(330, 270); height = 174
		"rope": bottom = Vector2(330, 252); height = 166
		"boat": bottom = Vector2(320, 280); height = 218
		"map": bottom = Vector2(330, 266); height = 205
		"chess": bottom = Vector2(320, 288); height = 226
		"compass": bottom = Vector2(320, 272); height = 214
		"letter": bottom = Vector2(320, 270); height = 205
	if corner:
		bottom = Vector2(320, 258)
		height = 230
	if key == "boat" and not corner:
		bottom.y += sin(clock * 1.25) * 1.8
	var dimensions := Vector2(texture.get_size())
	var width := height * dimensions.x / maxf(dimensions.y, 1.0)
	if not corner:
		width = minf(width, 390)
		var adjusted_height := width * dimensions.y / dimensions.x
		bottom.y -= height - adjusted_height
		height = adjusted_height
	var destination := Rect2(bottom.x - width * 0.5, bottom.y - height, width, height)
	if key == "lamp":
		var glow := 0.035 + sin(clock * 2.1) * 0.008
		_ellipse(destination.get_center(), Vector2(width * 0.58, height * 0.44), Color(1.0, 0.64, 0.25, glow), true)
	_ellipse(Vector2(bottom.x, bottom.y - 3), Vector2(width * 0.31, 8), Color(0, 0, 0, 0.24), true)
	draw_texture_rect(texture, destination, false, Color(1, 1, 1, 0.94 if corner else 1.0))

func _actor(kind: String, variant: String, bottom: Vector2, height: float) -> void:
	var texture := _actor_texture(kind, variant)
	if texture == null:
		return
	if kind == "companion" and variant != "male":
		height *= 1.10
	if kind == "boss":
		height *= 1.10
		var boss_dimensions := Vector2(texture.get_size())
		var natural_width := height * boss_dimensions.x / maxf(boss_dimensions.y, 1.0)
		var maximum_width := 190.0 if bottom.x > 400 else 150.0
		if natural_width > maximum_width:
			height *= maximum_width / natural_width
	var breath := sin(clock * 1.55 + bottom.x * 0.015) * 0.9
	_texture(texture, bottom + Vector2(0, breath), height)

func _actor_texture(kind: String, variant: String) -> Texture2D:
	match kind:
		"mother": return Assets.texture(MOTHER)
		"hero":
			var path := HERO_FEMALE if protagonist == "female" else HERO_MALE
			var frames := Assets.frames(path, 4, 4, 0.2, true)
			return frames[0] if not frames.is_empty() else null
		"companion":
			if companion == "male":
				var frames := Assets.frames(VILLAGE_NPCS, 3, 1, 0.2, true)
				return frames[2] if frames.size() >= 3 else null
			return Assets.texture(ANING)
		"npc":
			var frames := Assets.frames(NPC_SHEET, 3, 2, 0.2, false)
			var index := clampi(int(variant), 0, 5)
			return frames[index] if frames.size() == 6 else null
		"boss": return Catalogue.boss_texture(stage_id)
	return null

func _texture(texture: Texture2D, bottom: Vector2, height: float) -> void:
	var dimensions := Vector2(texture.get_size())
	if dimensions.y <= 0:
		return
	var width := height * dimensions.x / dimensions.y
	var destination := Rect2(bottom.x - width * 0.5, bottom.y - height, width, height)
	_ellipse(Vector2(bottom.x, bottom.y - 2), Vector2(width * 0.28, 7), Color(0, 0, 0, 0.28), true)
	draw_texture_rect(texture, destination, false)

func _speaker_kind(value: String) -> String:
	if value == "主角": return "hero"
	if value == "阿宁": return "companion"
	if value == "母亲": return "mother"
	if value in BOSS_SPEAKERS: return "boss"
	if value == "阿宁留言": return "prop"
	if value == "旁白" or value.is_empty(): return "none"
	return "npc"

func _actor_for_name(value: String, bottom: Vector2, height: float) -> void:
	var kind := _speaker_kind(value)
	match kind:
		"hero": _actor("hero", "", bottom, height)
		"companion": _actor("companion", companion, bottom, height)
		"mother": _actor("mother", "", bottom, height + 10)
		"boss": _actor("boss", "", bottom, height + 20)
		"npc": _actor("npc", str(NPC_INDEX.get(value, 2)), bottom, height)

func portrait_texture(value: String) -> Texture2D:
	var kind := _speaker_kind(value)
	match kind:
		"hero": return Assets.portrait(_actor_texture("hero", ""))
		"companion": return Assets.portrait(_actor_texture("companion", companion))
		"mother": return Assets.portrait(_actor_texture("mother", ""))
		"boss": return _actor_texture("boss", "")
		"npc": return Assets.portrait(_actor_texture("npc", str(NPC_INDEX.get(value, 2))))
		"prop": return prop_texture("map")
	return null

func _draw_story_characters() -> void:
	_actor("hero", protagonist, Vector2(98, 304), 188)
	if actor_name not in ["", "主角", "旁白", "阿宁留言"]:
		_actor_for_name(actor_name, Vector2(542, 304), 180)

func _home() -> void:
	if art == "village_return":
		_actor("mother", "", Vector2(132, 302), 218)
		_actor("hero", protagonist, Vector2(322, 304), 210)
		_actor("companion", companion, Vector2(510, 302), 194)
		return
	if stage_id.is_empty():
		_actor("mother", "", Vector2(122, 282), 214)
		_actor("hero", protagonist, Vector2(326, 284), 202)
		_actor("companion", companion, Vector2(515, 282), 188)
	else:
		_actor("hero", protagonist, Vector2(112, 284), 194)
		if actor_name not in ["", "主角", "旁白", "阿宁留言"]:
			_actor_for_name(actor_name, Vector2(522, 282), 184)
	# Supporting table is deterministic; the bowls are the validated formal art.
	draw_rect(Rect2(0, 232, 640, 88), Color("382820"))
	draw_rect(Rect2(0, 232, 640, 8), Color("805a40"))
	draw_rect(Rect2(0, 244, 640, 3), Color("241b19"))
	for x in range(18, 640, 74):
		draw_line(Vector2(x, 248), Vector2(x + 32, 320), Color(0.12, 0.075, 0.06, 0.30), 2)
	for y in [272, 298]:
		draw_line(Vector2(0, y), Vector2(640, y + 3), Color(0.18, 0.11, 0.075, 0.40), 1)
	_food_bowl(Vector2(298, 270), false)
	_food_bowl(Vector2(404, 274), false)
	_food_bowl(Vector2(512, 270), false)
	_food_bowl(Vector2(70, 273), true)
	if art == "noodles":
		for center in [Vector2(298, 218), Vector2(404, 222), Vector2(512, 218)]:
			var drift := sin(clock * 1.8 + center.x) * 2.0
			draw_arc(center + Vector2(drift, 0), 8, -PI * 0.70, PI * 0.25, 18, Color(0.93, 0.88, 0.76, 0.26), 1.2, true)

func _food_bowl(bottom: Vector2, old: bool) -> void:
	var texture := prop_texture("old_bowl" if old else "noodles")
	if texture == null:
		return
	var dimensions := Vector2(texture.get_size())
	var width := 112.0 if old else 108.0
	var height := width * dimensions.y / dimensions.x
	draw_texture_rect(texture, Rect2(bottom.x - width * 0.5, bottom.y - height, width, height), false)

func _letter(changed: bool) -> void:
	_actor("hero", protagonist, Vector2(82, 307), 204)
	if actor_name not in ["", "主角", "旁白", "阿宁留言"]:
		_actor_for_name(actor_name, Vector2(198, 307), 174)
	var envelope := prop_texture("letter")
	if envelope != null:
		draw_texture_rect(envelope, Rect2(161, 218, 102, 82), false, Color(1, 1, 1, 0.88))
	# Accurate native copy stays editable and readable; the sealed prop sits beside it.
	draw_rect(Rect2(281, 35, 326, 264), Color(0, 0, 0, 0.35))
	var paper := PackedVector2Array([Vector2(271, 25), Vector2(594, 31), Vector2(588, 293), Vector2(276, 287)])
	draw_colored_polygon(paper, Color("ddcba7"))
	draw_polyline(PackedVector2Array([paper[0], paper[1], paper[2], paper[3], paper[0]]), Color("8d7658"), 2, true)
	draw_line(Vector2(277, 95), Vector2(591, 100), Color(0.43, 0.34, 0.25, 0.18), 1)
	draw_line(Vector2(430, 29), Vector2(424, 290), Color(0.43, 0.34, 0.25, 0.13), 1)
	for x in [286, 579]:
		draw_line(Vector2(x, 42), Vector2(x - 3, 278), Color(0.45, 0.35, 0.25, 0.08), 1)
	_text("青松留下的旧信", Vector2(296, 58), 15, Color("66503c"))
	draw_line(Vector2(296, 70), Vector2(565, 74), Color("a38a68"), 1)
	_text("孩子：", Vector2(298, 105), 17, Color("42382e"))
	_text("等爹回来，", Vector2(298, 143), 18, Color("514236"))
	_text("给你下碗面。", Vector2(298, 172), 18, Color("514236"))
	if changed:
		draw_line(Vector2(294, 136), Vector2(411, 139), Color("8c4c3e"), 2)
		draw_line(Vector2(294, 165), Vector2(429, 168), Color("8c4c3e"), 2)
		_text("按时吃饭。", Vector2(298, 222), 25, Color("743a32"))
	_text("—— 青松", Vector2(469, 267), 16, Color("58493a"))
	draw_circle(Vector2(556, 251), 18, Color("934b3e"))
	draw_arc(Vector2(556, 251), 13, 0, TAU, 28, Color("d2ae83"), 1.5, true)

func _text(value: String, position: Vector2, font_size: int, color: Color) -> void:
	draw_string(ThemeDB.fallback_font, position, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _ellipse(center: Vector2, radii: Vector2, color: Color, filled: bool) -> void:
	var points := PackedVector2Array()
	for index in range(32):
		var angle := TAU * float(index) / 32.0
		points.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	if filled:
		draw_colored_polygon(points, color)
	else:
		points.append(points[0])
		draw_polyline(points, color, 1.5, true)
