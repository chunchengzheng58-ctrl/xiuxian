extends VBoxContainer

const DuelLobby = preload("res://scripts/duel_lobby.gd")
var game: Node
var ui: Control
var cultivator_id: String
var current: Dictionary = {}
var rendered: Dictionary = {}
var content: VBoxContainer
var status_label: Label
var queue_label: Label
var alias_input: LineEdit
var action_button: Button
var alias_draft := ""
var busy := false
var fetching := false
var refresh_again := false
var auto_enter := false
var entering := false
var received_ms := 0

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tabs := HBoxContainer.new()
	add_child(tabs)
	ui.button(tabs, "匹配对战", func(): pass, true).disabled = true
	ui.button(tabs, "好友切磋", ui.open_duel_lobby)
	ui.button(tabs, "刷新", refresh)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 320
	scroll.follow_focus = true
	add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)
	status_label = ui.paragraph(self, "正在读取论剑榜…", 16)
	var poll := Timer.new()
	poll.wait_time = 2
	poll.timeout.connect(refresh)
	add_child(poll)
	poll.start()
	game.account_api.realtime.snapshot_received.connect(func(_snapshot): refresh())
	refresh()

func refresh() -> void:
	if is_queued_for_deletion() or entering:
		return
	if fetching or busy:
		refresh_again = true
		return
	fetching = true
	refresh_again = false
	var result := await command("lobby")
	if is_queued_for_deletion():
		return
	fetching = false
	if result.ok:
		current = result.data
		received_ms = Time.get_ticks_msec()
		if status_label.text == "正在读取论剑榜…":
			status_label.text = ""
		var projection := current.duplicate(true)
		projection.erase("server_now")
		if projection != rendered:
			rendered = projection
			render()
		if current.get("queue") is Dictionary:
			auto_enter = true
		var active: Variant = current.get("active")
		if auto_enter and active is Dictionary and active.get("mode", "ranked") == "ranked":
			entering = true
			ui.open_duel_battle.call_deferred(str(active.match_id))
	else:
		status_label.text = result.message
	if refresh_again:
		refresh.call_deferred()

func render() -> void:
	if is_instance_valid(alias_input):
		alias_draft = alias_input.text
	alias_input = null
	queue_label = null
	action_button = null
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var profile: Variant = current.get("profile")
	if not profile is Dictionary:
		ui.label_into(content, "先为你的论剑名片起个名字", 23)
		ui.paragraph(content, "对手和积分榜只会显示这个昵称，可在同道录修改。", 17)
		var form := HBoxContainer.new()
		content.add_child(form)
		alias_input = LineEdit.new()
		alias_input.placeholder_text = "论剑昵称 · 1–12 个字符"
		alias_input.max_length = 12
		alias_input.text = alias_draft
		alias_input.custom_minimum_size.y = 46
		alias_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		alias_input.add_theme_font_size_override("font_size", 20)
		form.add_child(alias_input)
		alias_input.text_submitted.connect(func(_text): save_alias())
		action_button = ui.button(form, "保存论剑昵称", save_alias, true)
		action_button.disabled = busy
	else:
		build_match_controls()
	ui.line(content)
	var rating: Dictionary = current.get("rating", {})
	ui.label_into(content, "我的积分 %d" % int(rating.get("rating", 1000)), 26)
	var rank := int(rating.rank) if rating.get("rank") != null else 0
	ui.paragraph(content, "%d 胜  ·  %d 负  ·  %d 平  ·  %s" % [int(rating.get("wins", 0)), int(rating.get("losses", 0)), int(rating.get("draws", 0)), "第 %d 名" % rank if rank > 0 else "完成比赛后上榜"], 18)
	ui.paragraph(content, "匹配对战每局 90 秒。对战结束后可查看战果。", 17)
	ui.line(content)
	ui.label_into(content, "论剑积分榜", 23)
	var leaders: Array = current.get("leaderboard", [])
	if leaders.is_empty():
		ui.paragraph(content, "暂无战绩，完成首场匹配即可留下你的名字。", 17)
	for leader in leaders:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		content.add_child(row)
		ui.label_into(row, "%02d" % int(leader.rank), 19).custom_minimum_size.x = 40
		var name_label: Label = ui.label_into(row, str(leader.alias), 19)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.tooltip_text = str(leader.alias)
		ui.label_into(row, "%d 分" % int(leader.rating), 19).custom_minimum_size.x = 100
		ui.label_into(row, "%d 胜 %d 负 %d 平" % [int(leader.wins), int(leader.losses), int(leader.draws)], 17).custom_minimum_size.x = 190
	var recent: Array = current.get("recent", [])
	if not recent.is_empty():
		ui.line(content)
		ui.label_into(content, "近期匹配战绩", 23)
		for match_data in recent:
			var row := HBoxContainer.new()
			content.add_child(row)
			var name_label: Label = ui.label_into(row, str(match_data.opponent), 18)
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_label.clip_text = true
			var delta := int(match_data.rating_delta) if match_data.get("rating_delta") != null else 0
			var suffix := " · 积分 %+d" % delta if match_data.get("rating_before") != null else ""
			ui.label_into(row, DuelLobby.result_text(match_data) + suffix, 18)

func build_match_controls() -> void:
	var active: Variant = current.get("active")
	var queue: Variant = current.get("queue")
	if active is Dictionary:
		ui.label_into(content, "匹配成功 · " + str(active.get("opponent", "同道")), 24)
		ui.paragraph(content, "请尽快入场，倒计时结束后开始战斗。", 17)
		action_button = ui.button(content, "进入匹配擂台" if active.get("mode") == "ranked" else "进入好友擂台", ui.open_duel_battle.bind(str(active.match_id)), true)
	elif queue is Dictionary:
		queue_label = ui.label_into(content, "正在寻找对手…", 25)
		ui.paragraph(content, "停留此页将在匹配成功后自动入场。离开页面后，可从论剑台继续或取消匹配。", 17)
		action_button = ui.button(content, "取消匹配", cancel)
	else:
		ui.label_into(content, "寻找对手", 24)
		ui.paragraph(content, "开始匹配后，可在入场前随时取消。", 17)
		action_button = ui.button(content, "开始匹配", join, true)
	if is_instance_valid(action_button):
		action_button.disabled = busy

func _process(_delta: float) -> void:
	if is_instance_valid(queue_label) and current.get("queue") is Dictionary:
		var elapsed := float(Time.get_ticks_msec() - received_ms) / 1000
		var now := float(current.get("server_now", 0)) + elapsed
		var remaining := maxi(0, int(ceil(float(current.queue.expires_at) - now)))
		queue_label.text = "正在寻找对手 · %d 秒" % remaining if remaining > 0 else "正在更新匹配状态…"

func save_alias() -> void:
	if busy or not is_instance_valid(alias_input):
		return
	var alias := alias_input.text.strip_edges()
	if alias.is_empty():
		status_label.text = "请输入论剑昵称。"
		return
	busy = true
	if is_instance_valid(action_button):
		action_button.disabled = true
	var core := get_tree().root.get_node("GameKernel")
	var result: Dictionary = await core.dispatch("social.profile", {"cultivator_id": cultivator_id, "alias": alias, "rotate_code": false})
	if is_queued_for_deletion():
		return
	busy = false
	status_label.text = "昵称已保存，可以开始匹配。" if result.ok else result.message
	rendered.clear()
	refresh()

func join() -> void:
	auto_enter = true
	await mutate("join", "正在寻找对手…")

func cancel() -> void:
	auto_enter = false
	await mutate("cancel", "已取消匹配")

func mutate(kind: String, note: String) -> void:
	if busy or is_queued_for_deletion():
		return
	busy = true
	if is_instance_valid(action_button):
		action_button.disabled = true
	status_label.text = "正在提交…"
	var result := await command(kind)
	if is_queued_for_deletion():
		return
	busy = false
	status_label.text = note if result.ok else result.message
	rendered.clear()
	refresh()

func command(kind: String) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	return await core.dispatch("combat.matchmaking_" + kind, {"cultivator_id": cultivator_id})
