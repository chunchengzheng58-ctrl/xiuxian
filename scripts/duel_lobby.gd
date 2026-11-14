extends VBoxContainer

const END_REASONS = {
	"knockout": "击倒", "time": "时间到", "forfeit": "认输", "disconnect": "掉线超时",
	"absent": "未能入场", "withdrawn": "退出准备", "interrupted": "服务中断", "unavailable": "角色状态变化",
}

var game: Node
var ui: Control
var cultivator_id: String
var initial_friend: String = ""
var content: VBoxContainer
var status_label: Label
var current: Dictionary = {}
var fetching := false
var busy := false
var refresh_again := false

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	add_child(bar)
	ui.button(bar, "匹配对战", ui.open_matchmaking_lobby)
	ui.button(bar, "返回同道录", ui.open_social)
	ui.button(bar, "刷新", refresh)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 320
	scroll.follow_focus = true
	add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 7)
	scroll.add_child(content)
	status_label = ui.paragraph(self, "正在读取约战…", 16)
	var poll := Timer.new()
	poll.wait_time = 5
	poll.timeout.connect(refresh)
	add_child(poll)
	poll.start()
	game.account_api.realtime.snapshot_received.connect(func(_snapshot): refresh())
	refresh()

func refresh() -> void:
	if is_queued_for_deletion():
		return
	if busy or fetching:
		refresh_again = true
		return
	fetching = true
	refresh_again = false
	var result := await command("lobby")
	if is_queued_for_deletion():
		return
	fetching = false
	if result.ok:
		if status_label.text == "正在读取约战…":
			status_label.text = ""
		if current != result.data:
			current = result.data
			render()
	else:
		status_label.text = result.message
	if refresh_again:
		refresh.call_deferred()

func render() -> void:
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var matches: Array = current.get("matches", [])
	var upcoming := matches.filter(func(item): return item.status != "finished")
	ui.label_into(content, "当前约战", 21)
	if upcoming.is_empty():
		ui.paragraph(content, "目前没有待处理的约战。", 17)
	for item in upcoming:
		var row := entry_row(item.opponent)
		var payload := {"match_id": item.match_id}
		if item.status == "active":
			ui.label_into(row, "双方已确认", 16)
			ui.button(row, "进入擂台", ui.open_duel_battle.bind(item.match_id), true)
		elif int(item.seat) == 1:
			ui.label_into(row, "邀请你切磋", 16)
			ui.button(row, "接受约战", reply.bind(item.match_id, "accept", "约战已确认，请进入擂台"), true)
			ui.button(row, "拒绝", reply.bind(item.match_id, "decline", "已拒绝约战"))
		else:
			ui.label_into(row, "等待对方回应", 16)
			ui.button(row, "撤回", mutate.bind("reply", payload.merged({"action": "cancel"}), "邀请已撤回"))
	ui.line(content)
	ui.label_into(content, "邀请好友", 21)
	var friends: Array = current.get("friends", [])
	if friends.is_empty():
		ui.paragraph(content, "在同道录互加好友后，即可发起切磋。", 17)
	for friend in friends:
		var row := entry_row(friend.alias)
		var is_selected: bool = friend.relation_id == initial_friend
		ui.button(row, "发送约战" if is_selected else "邀约", invite.bind(friend.relation_id), is_selected).disabled = not upcoming.is_empty()
	var history := matches.filter(func(item): return item.status == "finished")
	if not history.is_empty():
		ui.line(content)
		ui.label_into(content, "近期战绩", 21)
		for item in history:
			var row := entry_row(item.opponent)
			var mode_name: String = "匹配" if item.get("mode") == "ranked" else "切磋"
			ui.label_into(row, mode_name + " · " + result_text(item) + " · " + str(END_REASONS.get(item.reason, "结束")), 17)

func entry_row(alias: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	content.add_child(row)
	var label: Label = ui.label_into(row, alias, 19)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row

static func result_text(result: Dictionary) -> String:
	if result.reason in ["absent", "interrupted", "withdrawn", "unavailable"]:
		return "中断" if result.reason in ["interrupted", "unavailable"] else "未开打"
	if result.winner == null:
		return "平局"
	return "胜利" if int(result.winner) == int(result.seat) else "落败"

func invite(relation_id: String) -> void:
	await mutate("invite", {"relation_id": relation_id}, "约战已发送，对方可在 90 秒内回应")

func reply(match_id: String, action: String, note: String) -> void:
	await mutate("reply", {"match_id": match_id, "action": action}, note)

func mutate(kind: String, payload: Dictionary, note: String) -> void:
	if busy or is_queued_for_deletion():
		return
	busy = true
	status_label.text = "正在提交…"
	var result := await command(kind, payload)
	if is_queued_for_deletion():
		return
	busy = false
	status_label.text = note if result.ok else result.message
	refresh()

func command(kind: String, payload: Dictionary = {}) -> Dictionary:
	var core := get_tree().root.get_node("GameKernel")
	return await core.dispatch("combat.duel_" + kind, payload.merged({"cultivator_id": cultivator_id}))
