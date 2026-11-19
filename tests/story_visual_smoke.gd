extends SceneTree
const Player = preload("res://scripts/story_scene_player.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	print("SMOKE begin")
	root.size = Vector2i(1440, 900)
	var campaign: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/adventure-campaign.v1.json"))
	var row: Dictionary = campaign.stages[12]
	var player := Player.new()
	player.scene_data = {"scene_id": "stage.b12.resolution", "title": row.name, "kind": "resolution", "stage_id": "b12", "art": "letter", "dialogue": row.resolution}
	player.persist_marker = false
	player.variants = {"protagonist": "female", "companion": "male"}
	root.add_child(player)
	print("SMOKE player added")
	await process_frame
	print("SMOKE process frame")
	print("SMOKE before advance")
	player.advance()
	print("SMOKE after advance")
	await process_frame
	await RenderingServer.frame_post_draw
	print("SMOKE post draw")
	var image := root.get_texture().get_image()
	print("SMOKE capture ", image.save_png("res://output/story-refined-smoke.png"))
	player.queue_free()
	await process_frame
	print("SMOKE done")
	quit()
