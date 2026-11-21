extends SceneTree
## Compose only individually validated prop cells; failed source cells are never used.
const Assets = preload("res://scripts/pixel_assets.gd")
const NAMES = ["lamp", "tree", "rations", "rope", "boat", "map", "chess", "compass", "letter", "noodle_bowl", "old_bowl", "travel_pack"]

func clean_residue(image: Image) -> void:
	var width := image.get_width()
	var height := image.get_height()
	var visited := PackedByteArray()
	visited.resize(width * height)
	for y in range(height):
		for x in range(width):
			var start := y * width + x
			if visited[start] == 1 or image.get_pixel(x, y).a <= 0.08:
				continue
			var queue: Array[Vector2i] = [Vector2i(x, y)]
			visited[start] = 1
			var cursor := 0
			while cursor < queue.size():
				var point := queue[cursor]
				cursor += 1
				for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					var next: Vector2i = point + direction
					if next.x < 0 or next.y < 0 or next.x >= width or next.y >= height:
						continue
					var offset: int = next.y * width + next.x
					if visited[offset] == 0 and image.get_pixel(next.x, next.y).a > 0.08:
						visited[offset] = 1
						queue.append(next)
			if queue.size() < 96:
				for point in queue:
					var color := image.get_pixel(point.x, point.y)
					color.a = 0.0
					image.set_pixel(point.x, point.y, color)

func _initialize() -> void:
	var first := Image.load_from_file("res://assets/story_props/story-prop-atlas-v1.png")
	var second := Image.load_from_file("res://assets/story_props/story-prop-atlas-v2.png")
	if first == null or second == null or first.is_empty() or second.is_empty():
		printerr("Missing story prop source atlas")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/story_props/cells"))
	var atlas := Image.create(first.get_width(), first.get_height(), false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for index in range(NAMES.size()):
		var source := second if index == 9 else first
		var column := index % 4
		var row := index / 4
		var x0 := int(floor(column * source.get_width() / 4.0))
		var x1 := int(floor((column + 1) * source.get_width() / 4.0))
		var y0 := int(floor(row * source.get_height() / 3.0))
		var y1 := int(floor((row + 1) * source.get_height() / 3.0))
		var cell := source.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))
		for y in range(cell.get_height()):
			for x in range(cell.get_width()):
				if x < 24 or x >= cell.get_width() - 24:
					var edge := cell.get_pixel(x, y)
					edge.a = 0.0
					cell.set_pixel(x, y, edge)
		clean_residue(cell)
		var used := Assets.visible_rect(cell, 0.025)
		if used.size != Vector2i.ZERO:
			cell = cell.get_region(used)
		var destination := Vector2i(x0 + (x1 - x0 - cell.get_width()) / 2, y0 + (y1 - y0 - cell.get_height()) / 2)
		atlas.blit_rect(cell, Rect2i(Vector2i.ZERO, cell.get_size()), destination)
		var path := "res://assets/story_props/cells/%02d-%s.png" % [index, NAMES[index]]
		print("PROP_CELL ", path, " ", cell.get_size(), " error=", cell.save_png(path))
	print("VALIDATED_ATLAS error=", atlas.save_png("res://assets/story_props/story-prop-atlas.png"))
	quit()
