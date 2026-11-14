extends RefCounted
## 同一份正式冒险规则用于章节导航、等级解释及战场提示；结算仍由服务端执行。
const DATA = preload("res://data/adventure-campaign.v1.json")
const ATTRIBUTES = {"life": "生命", "attack": "攻击", "defense": "防御", "spirit": "灵力", "stamina": "体力"}

static func stage(id: String) -> Dictionary:
	for row in DATA.data.stages:
		if row.stage_id == id:
			return row.duplicate(true)
	return {}

static func chapter(id: String) -> Dictionary:
	for row in DATA.data.chapters:
		if row.id == id:
			return row.duplicate(true)
	return {}

static func level_text(adventure: Dictionary) -> String:
	return "冒险 Lv.%d · %s" % [int(adventure.get("level", 1)), str(adventure.get("title", "初识灯火"))]

static func stats_text(stats: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key in ATTRIBUTES:
		parts.append("%s %d" % [ATTRIBUTES[key], int(stats.get(key, 0))])
	return "   ".join(parts)

static func reward_text(reward: Dictionary) -> String:
	return "%d 灵气 · %d 锻材 · %d 历练" % [int(reward.get("spirit_stones", 0)), int(reward.get("materials", 0)), int(reward.get("adventure_xp", 0))]

static func progress_text(adventure: Dictionary) -> String:
	if int(adventure.get("xp_to_next", 0)) == 0:
		return "已达当前最高等级 · 累计历练 %d" % int(adventure.get("xp", 0))
	return "本级历练 %d / %d · 距下一级 %d" % [int(adventure.get("xp_into_level", 0)), int(adventure.get("xp_into_level", 0)) + int(adventure.get("xp_to_next", 0)), int(adventure.get("xp_to_next", 0))]
