extends Node2D
## Observe confirmed snapshots only. Missing/reconnected packets establish a new
## baseline rather than replaying everything which happened while disconnected.
signal feedback(kind: String)
var previous: Dictionary = {}
var observed_id := ""
var last_tick := -1
var terminal_seen := false
var font: Font

func _ready() -> void:
	z_index = 8
	font = preload("res://assets/fonts/NotoSansSC-Regular.otf")
	var options := get_node_or_null("/root/GameOptions")
	if options != null:
		options.changed.connect(_options_changed)

func _options_changed() -> void:
	if not option("show_damage_numbers", true):
		for child in get_children():
			child.queue_free()

func option(key: String, fallback: Variant) -> Variant:
	if not is_inside_tree():
		return fallback
	var options := get_node_or_null("/root/GameOptions")
	return options.get_value(key, fallback) if options != null else fallback

func suspend() -> void:
	previous.clear()

func observe(snapshot: Dictionary, duel := false) -> void:
	var id := str(snapshot.get("match_id" if duel else "run_id", ""))
	var tick := int(snapshot.get("tick", -1))
	if id != observed_id:
		observed_id = id
		last_tick = -1
		terminal_seen = false
		previous.clear()
	var result: Variant = snapshot.get("result")
	if tick <= last_tick and not result is Dictionary:
		return
	var baseline: bool = previous.is_empty() or previous.get("phase") not in ["fighting", "finished"] or snapshot.get("phase") not in ["fighting", "finished"]
	# A >2s gap is reconnection/late delivery, not a fresh cluster of hits.
	baseline = baseline or (last_tick >= 0 and tick - last_tick > 50)
	if not baseline:
		var fighters: Array = snapshot.get("players", []) if duel else [snapshot.player, snapshot.enemy]
		var old: Array = previous.get("players", []) if duel else [previous.player, previous.enemy]
		for index in range(mini(fighters.size(), old.size())):
			var player: Dictionary = fighters[index]
			var before: Dictionary = old[index]
			var friendly: bool = index == int(snapshot.get("seat", 0)) if duel else index == 0
			var damage := int(before.hp) - int(player.hp)
			if damage > 0:
				cue("hurt" if friendly else "hit")
				floating("-%d" % damage, Vector2(player.x, player.y - 155), Color("ffb7a2") if friendly else Color("ffe0a0"))
			elif damage < 0:
				floating("+%d" % -damage, Vector2(player.x, player.y - 155), Color("a9e6bf"))
			if int(before.get("shield", 0)) > int(player.get("shield", 0)) and damage == 0:
				cue("block")
			if friendly and player.get("cd") is Array and before.get("cd") is Array:
				for action in range(1, mini(player.cd.size(), before.cd.size())):
					if float(player.cd[action]) > float(before.cd[action]) + 1:
						cue(["", "attack", "sword", "dash", "guard", "heal"][action])
		if not duel:
			var mechanic: Dictionary = snapshot.get("mechanic", {})
			var old_mechanic: Dictionary = previous.get("mechanic", {})
			if int(mechanic.get("stage", 0)) > int(old_mechanic.get("stage", 0)):
				cue("phase")
			elif mechanic.get("phase") == "windup" and (old_mechanic.get("phase") != "windup" or mechanic.get("move_id") != old_mechanic.get("move_id")):
				cue("warning")
	if result is Dictionary and not terminal_seen:
		terminal_seen = true
		if not baseline and result.get("reason") in ["knockout", "time", "disconnect", "forfeit"]:
			if duel:
				if result.get("winner") != null:
					cue("victory" if int(result.winner) == int(snapshot.get("seat", 0)) else "defeat")
			elif result.get("won", false):
				cue("victory")
			elif result.get("reason") != "disconnect":
				cue("defeat")
	last_tick = maxi(last_tick, tick)
	previous = snapshot.duplicate(true)

func cue(kind: String) -> void:
	feedback.emit(kind)
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.play(kind)

func floating(text: String, at: Vector2, color: Color) -> void:
	if not option("show_damage_numbers", true):
		return
	if get_child_count() >= 16:
		var oldest := get_child(0)
		remove_child(oldest)
		oldest.queue_free()
	var number := Label.new()
	number.text = text
	number.position = at + Vector2(-30, -get_child_count() % 3 * 12)
	number.add_theme_font_override("font", font)
	number.add_theme_font_size_override("font_size", 25)
	number.add_theme_color_override("font_color", color)
	number.add_theme_color_override("font_outline_color", Color("31271f"))
	number.add_theme_constant_override("outline_size", 4)
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(number)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(number, "position:y", number.position.y - 40, 0.7)
	tween.tween_property(number, "modulate:a", 0.0, 0.25).set_delay(0.45)
	tween.chain().tween_callback(number.queue_free)
