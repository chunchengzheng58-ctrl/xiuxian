extends SceneTree
## Extract the already-created front-view story identities without redrawing them.
const JOBS = [
	{"source": "res://assets/story_concepts/qingsong-three-view.png", "rect": Rect2i(170, 125, 510, 915), "output": "res://assets/story_characters/qingsong.png"},
	{"source": "res://assets/story_concepts/mother-three-view.png", "rect": Rect2i(85, 55, 620, 1040), "output": "res://assets/story_characters/mother.png"},
	{"source": "res://assets/story_concepts/aning-three-view.png", "rect": Rect2i(280, 165, 510, 865), "output": "res://assets/story_characters/aning.png"}
]

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/story_characters"))
	for job in JOBS:
		extract(job)
	quit()

func background_like(color: Color) -> bool:
	var high := maxf(color.r, maxf(color.g, color.b))
	var low := minf(color.r, minf(color.g, color.b))
	var brightness := (color.r + color.g + color.b) / 3.0
	return high - low < 0.17 and brightness > 0.48

func extract(job: Dictionary) -> void:
	var source := Image.load_from_file(job.source)
	if source == null or source.is_empty():
		printerr("Missing story identity: ", job.source)
		return
	var image := source.get_region(job.rect)
	image.convert(Image.FORMAT_RGBA8)
	var width := image.get_width()
	var height := image.get_height()
	var masked := PackedByteArray()
	masked.resize(width * height)
	var queue: Array[Vector2i] = []
	for x in range(width):
		for y in [0, height - 1]:
			if background_like(image.get_pixel(x, y)):
				masked[y * width + x] = 1
				queue.append(Vector2i(x, y))
	for y in range(height):
		for x in [0, width - 1]:
			if background_like(image.get_pixel(x, y)) and masked[y * width + x] == 0:
				masked[y * width + x] = 1
				queue.append(Vector2i(x, y))
	var cursor := 0
	while cursor < queue.size():
		var point := queue[cursor]
		cursor += 1
		for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = point + direction
			if next.x < 0 or next.y < 0 or next.x >= width or next.y >= height:
				continue
			var offset: int = next.y * width + next.x
			if masked[offset] == 0 and background_like(image.get_pixel(next.x, next.y)):
				masked[offset] = 1
				queue.append(next)
	for y in range(height):
		for x in range(width):
			var offset := y * width + x
			if masked[offset] == 1:
				var color := image.get_pixel(x, y)
				color.a = 0.0
				image.set_pixel(x, y, color)
	var error := image.save_png(job.output)
	print("STORY_ART ", job.output, " ", image.get_size(), " error=", error, " visible=", image.get_used_rect())
