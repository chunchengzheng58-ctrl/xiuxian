extends Control
## 启动加载界面：先播一次开场 CG，再用可循环的小人跑步承接剩余加载时间。
## 主场景资源按队列逐帧加载（每帧一项），动画与真实加载并行，进度条反映真实进度。
## 不使用 ResourceLoader 线程加载：本工程脚本在常量中预加载 JSON，线程加载会导致编译失败。
## 调试参数：--splash-hold 停留在加载界面；--splash-shot=<path> 2.5 秒后截图并退出。

const Assets = preload("res://scripts/pixel_assets.gd")
const MAIN_SCENE := "res://scenes/main.tscn"
const CG_OGV := "res://cinematics/op-opening-cg.ogv"
const FRAME_PNG := "res://cinematics/op-opening-frame.png"
const TITLE_PNG := "res://cinematics/op-title-card-ui.png"
const RUNNER_ATLAS := "res://assets/pixel/cultivator-walk.png"
const RUNNER_FPS := 9.0
const CG_SKIP_DELAY := 1.2 # CG 播放超过该时间后允许点击跳过
const CG_MAX_WAIT := 6.0 # 场景已就绪时不强制看完整段 CG

# 分段加载队列：先脚本后贴图，重的依赖尽量在前面落地，主场景最后读取时大多命中缓存。
const LOAD_QUEUE := [
	"res://data/equipment-growth.v2.json",
	"res://scripts/game_state.gd",
	"res://scripts/family_roster.gd",
	"res://scripts/pixel_player.gd",
	"res://scripts/pixel_effects.gd",
	"res://scripts/companion_actor.gd",
	"res://scripts/companion_client.gd",
	"res://scripts/companion_task_client.gd",
	"res://scripts/net/backend_session.gd",
	"res://scripts/treasure_panel.gd",
	"res://scripts/combat_view.gd",
	"res://scripts/boss_corridor.gd",
	"res://scripts/gameplay_interface.gd",
	"res://assets/pixel/village-background.png",
	"res://assets/pixel/cultivator-walk.png",
	"res://assets/gameplay/female-walk-v2.png",
	"res://assets/pixel/village-npcs.png"
]

var _args: PackedStringArray = []
var _hold := false
var _stage := "cg"
var _backdrop: TextureRect
var _video: VideoStreamPlayer
var _wait_root: Control
var _title: TextureRect
var _runner: TextureRect
var _bar: ProgressBar
var _hint: Label
var _frames: Array[Texture2D] = []
var _clock := 0.0
var _cg_clock := 0.0
var _wait_clock := 0.0
var _loaded: PackedScene
var _progress := 0.0
var _queue_index := 0
var _load_failed := false
var _finishing := false

func _ready() -> void:
	_args = OS.get_cmdline_user_args()
	_hold = "--splash-hold" in _args or "--splash-cg-hold" in _args
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_build_backdrop()
	_build_wait_ui()
	if _skip_cg():
		_enter_wait()
	else:
		_start_cg()
	_schedule_shot()

func _skip_cg() -> bool:
	# 自动化预览与截图保持原有行为，不被开场动画延迟。
	for flag in ["--preview", "--skip-intro", "--skip-cg", "--splash-hold"]:
		if flag in _args:
			return true
	for arg in _args:
		if arg.begins_with("--capture="):
			return true
	return false

func _build_backdrop() -> void:
	_backdrop = TextureRect.new()
	_backdrop.texture = Assets.texture(FRAME_PNG)
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.07, 0.1, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

func _start_cg() -> void:
	if OS.has_feature("web") or not FileAccess.file_exists(CG_OGV):
		_enter_wait()
		return
	# 直接指定文件，避免依赖编辑器先行导入视频资源。
	var stream := VideoStreamTheora.new()
	stream.file = CG_OGV
	_video = VideoStreamPlayer.new()
	_video.stream = stream
	_video.expand = true
	_video.volume_db = -6.0
	_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_video)
	_video.finished.connect(_enter_wait)
	_video.play()

func _build_wait_ui() -> void:
	_wait_root = Control.new()
	_wait_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wait_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wait_root.modulate.a = 0.0
	_wait_root.visible = false
	add_child(_wait_root)

	_title = TextureRect.new()
	_title.texture = Assets.texture(TITLE_PNG)
	_title.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_title.stretch_mode = TextureRect.STRETCH_SCALE
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wait_root.add_child(_title)

	# 直接取图集第三行（朝右行走四帧），不做逐像素扫描，避免拖慢首帧。
	var atlas := Assets.texture(RUNNER_ATLAS)
	if atlas != null:
		var cell := Vector2(atlas.get_width() / 4.0, atlas.get_height() / 4.0)
		for i in range(4):
			var frame := AtlasTexture.new()
			frame.atlas = atlas
			frame.region = Rect2(Vector2(i, 2) * cell, cell)
			frame.filter_clip = true
			_frames.append(frame)
	_runner = TextureRect.new()
	_runner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_runner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_runner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wait_root.add_child(_runner)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := StyleBoxFlat.new()
	track.bg_color = Color("241d19")
	track.border_color = Color("6b5231")
	track.set_border_width_all(2)
	track.set_corner_radius_all(3)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	_bar.add_theme_stylebox_override("background", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("e7bf6d")
	fill.set_corner_radius_all(2)
	_bar.add_theme_stylebox_override("fill", fill)
	_wait_root.add_child(_bar)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_color", Color("f2ddae"))
	_hint.add_theme_color_override("font_outline_color", Color("2a2119"))
	_hint.add_theme_constant_override("outline_size", 5)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wait_root.add_child(_hint)
	_layout()

func _layout() -> void:
	var view := size
	if view.x < 1.0:
		view = Vector2(1440, 900)
	if is_instance_valid(_backdrop) and _backdrop.texture != null:
		# 手动等比铺满并居中裁切，避免窗口比例变化时拉伸画面。
		var tex_size: Vector2 = _backdrop.texture.get_size()
		var factor := maxf(view.x / tex_size.x, view.y / tex_size.y)
		_backdrop.size = tex_size * factor
		_backdrop.position = (view - _backdrop.size) * 0.5
	if is_instance_valid(_title) and _title.texture != null:
		# 标题卡整屏铺满，CG 的收尾画面直接延续为等待界面，不出现贴片边缘。
		var card_size: Vector2 = _title.texture.get_size()
		var card_factor := maxf(view.x / card_size.x, view.y / card_size.y)
		_title.size = card_size * card_factor
		_title.position = (view - _title.size) * 0.5
	if is_instance_valid(_bar):
		_bar.size = Vector2(minf(520.0, view.x * 0.46), 16)
		_bar.position = Vector2((view.x - _bar.size.x) * 0.5, view.y - 54)
	if is_instance_valid(_hint):
		_hint.size = Vector2(view.x, 32)
		_hint.position = Vector2(0, view.y - 96)
	if is_instance_valid(_runner) and not _frames.is_empty():
		var aspect: float = _frames[0].get_width() / float(_frames[0].get_height())
		_runner.size = Vector2(84.0 * aspect, 84.0)
		_runner.position = Vector2(0, _bar.position.y - _runner.size.y + 6)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _enter_wait() -> void:
	if _stage == "wait":
		return
	_stage = "wait"
	if is_instance_valid(_video):
		_video.stop()
		_video.hide()
	_wait_root.visible = true
	var tween := create_tween()
	tween.tween_property(_wait_root, "modulate:a", 1.0, 0.45)

func _process(delta: float) -> void:
	_clock += delta
	if _stage == "cg":
		_cg_clock += delta
		# 场景已就绪时提前结束 CG；未就绪则 CG 播完后进入循环等待。
		if _loaded != null and _cg_clock >= CG_MAX_WAIT:
			_enter_wait()
	else:
		_wait_clock += delta
		_tick_runner()
		_tick_hint()
	_load_step()
	if _stage == "wait" and _loaded != null and _wait_clock >= 0.8 and not _finishing:
		_finish()

## 每帧最多加载一项资源：加载期间动画继续播放，进度与真实资源对应。
func _load_step() -> void:
	if _hold or _loaded != null or _load_failed:
		return
	if _queue_index < LOAD_QUEUE.size():
		var path: String = LOAD_QUEUE[_queue_index]
		_queue_index += 1
		if ResourceLoader.exists(path) or FileAccess.file_exists(path):
			if path.ends_with(".png"):
				Assets.texture(path)
			else:
				load(path)
		_progress = float(_queue_index) / float(LOAD_QUEUE.size() + 1)
		return
	_loaded = load(MAIN_SCENE)
	_progress = 1.0
	_load_failed = _loaded == null

func _tick_runner() -> void:
	if _frames.is_empty():
		return
	_runner.texture = _frames[int(_clock * RUNNER_FPS) % _frames.size()]
	var left := _bar.position.x - 20.0
	var right := _bar.position.x + _bar.size.x - _runner.size.x + 20.0
	# 小人沿加载条匀速往返跑，进度条显示真实加载进度。
	var travel := maxf(1.0, right - left)
	var cycle := fmod(_clock * 150.0, travel * 2.0)
	_runner.flip_h = cycle > travel
	_runner.position.x = left + (cycle if cycle <= travel else travel * 2.0 - cycle)
	_runner.position.y = _bar.position.y - _runner.size.y + 6 + sin(_clock * 18.0) * 1.5
	_bar.value = _progress

func _tick_hint() -> void:
	var dots := ".".repeat(int(_clock * 2.0) % 4)
	if _load_failed:
		_hint.text = "场景加载失败，请查看日志后重试"
	elif _loaded != null:
		_hint.text = "修行已成 · 正在进入仙村"
	elif _progress > 0.02:
		_hint.text = "正在准备仙村 %d%%%s" % [int(_progress * 100.0), dots]
	else:
		_hint.text = "正在修行%s" % dots

func _finish() -> void:
	_finishing = true
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.5)
	tween.tween_callback(_swap_scene)

func _swap_scene() -> void:
	if _loaded == null:
		return
	get_tree().call_deferred("change_scene_to_packed", _loaded)

func _unhandled_input(event: InputEvent) -> void:
	if _stage != "cg" or _cg_clock < CG_SKIP_DELAY:
		return
	var skip := false
	if event is InputEventKey and event.pressed and not event.echo:
		skip = true
	if event is InputEventMouseButton and event.pressed:
		skip = true
	if event is InputEventScreenTouch and event.pressed:
		skip = true
	if skip:
		_enter_wait()
		get_viewport().set_input_as_handled()

func _schedule_shot() -> void:
	for arg in _args:
		if arg.begins_with("--splash-shot="):
			# 支持 path@秒，便于抽查视频不同时间点的画面。
			var spec := arg.trim_prefix("--splash-shot=")
			var parts := spec.split("@")
			_shot(parts[0], float(parts[1]) if parts.size() > 1 else 2.5)

func _shot(path: String, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	print("SPLASH_SHOT ", path, " result=", get_viewport().get_texture().get_image().save_png(path))
	get_tree().quit()
