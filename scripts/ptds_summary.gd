extends RefCounted

const MAX_BYTES = 4096
const SCHEMA = "xiuxian.ptds-oura.v1"
const SOURCES = ["oura", "garmin", "somaloop", "whoop", "xiaomi", "generic"]
const METRICS = {
	"distance_km": ["距离", "km", 1000.0], "workout_minutes": ["运动时长", "分钟", 1440.0],
	"active_calories": ["活动热量", "kcal", 50000.0], "total_calories": ["总消耗", "kcal", 50000.0],
	"heart_rate": ["心率", "bpm", 500.0], "resting_hr": ["静息心率", "bpm", 500.0],
	"lowest_hr": ["最低心率", "bpm", 500.0], "highest_hr": ["最高心率", "bpm", 500.0],
	"night_lowest_hr": ["夜间最低心率", "bpm", 500.0], "hrv_ms": ["HRV（原厂算法）", "ms", 10000.0],
	"spo2_percent": ["平均血氧", "%", 100.0], "spo2_min": ["最低血氧", "%", 100.0],
	"respiration": ["呼吸频率", "次/分", 150.0], "sleep_respiration": ["睡眠呼吸频率", "次/分", 150.0],
	"skin_temperature": ["皮温", "℃", 100.0], "temperature_deviation": ["皮温偏差", "℃", 100.0],
	"deep_minutes": ["深睡", "分钟", 1440.0], "light_minutes": ["浅睡", "分钟", 1440.0],
	"rem_minutes": ["REM", "分钟", 1440.0], "awake_minutes": ["清醒", "分钟", 1440.0],
	"time_in_bed": ["卧床时长", "分钟", 1440.0], "stress": ["厂商压力指标", "分", 100.0],
	"body_battery_high": ["身体电量最高值", "分", 100.0], "body_battery_low": ["身体电量最低值", "分", 100.0],
	"readiness_score": ["准备度", "分", 100.0], "sleep_score": ["睡眠评分", "分", 100.0],
	"activity_score": ["活动评分", "分", 100.0], "load": ["厂商负荷", "", 1000000.0]
}


static func read_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"message": "无法打开摘要文件。"}
	if file.get_length() > MAX_BYTES:
		return {"message": "摘要文件过大，请选择 PTDS 导出工具生成的 JSON。"}
	return preview(file.get_buffer(MAX_BYTES + 1).get_string_from_utf8())


static func preview(json: String) -> Dictionary:
	if json.to_utf8_buffer().size() > MAX_BYTES:
		return {"message": "摘要文件过大，请选择 PTDS 导出工具生成的 JSON。"}
	var data: Variant = JSON.parse_string(json)
	if not data is Dictionary or not data.get("schema") in [SCHEMA, "xiuxian.wearable.v2"]:
		return {"message": "摘要格式不受支持，请使用项目提供的 PTDS 导出工具。"}
	var day: Variant = data.get("date")
	if not valid_date(day):
		return {"message": "摘要日期无效。"}
	var lines := PackedStringArray()
	var source: String = str(data.get("source", "oura"))
	if not source in SOURCES:
		return {"message": "摘要的设备来源不受支持。"}
	var movement_tier := 0
	var sleep_tier := 0
	var distance_zhang: Variant = null
	if data.has("steps"):
		var steps: Variant = data["steps"]
		if not valid_count(steps, 1000000):
			return {"message": "摘要中的步数无效。"}
		lines.append("步数：%d 步" % int(steps))
		distance_zhang = int(steps)
		movement_tier = 3 if steps >= 8000 else 2 if steps >= 5000 else 1 if steps >= 2000 else 0
	if data.has("sleep_minutes"):
		var minutes: Variant = data["sleep_minutes"]
		if not valid_count(minutes, 1440):
			return {"message": "摘要中的睡眠时长无效。"}
		lines.append("睡眠时长：%d 分钟" % int(minutes))
		sleep_tier = 3 if minutes >= 480 else 2 if minutes >= 420 else 1 if minutes >= 360 else 0
	var metrics: Variant = data.get("metrics", {})
	if not metrics is Dictionary or metrics.size() > METRICS.size():
		return {"message": "扩展指标格式无效。"}
	for key in metrics:
		if not METRICS.has(key):
			return {"message": "摘要含有尚未支持的指标：" + str(key)}
		var value: Variant = metrics[key]
		var minimum := -100.0 if key == "temperature_deviation" else 0.0
		if not (value is int or value is float) or not is_finite(float(value)) or value < minimum or value > METRICS[key][2]:
			return {"message": "扩展指标数值无效：" + str(key)}
		lines.append("%s：%s %s（仅本机）" % [METRICS[key][0], str(value), METRICS[key][1]])
	if distance_zhang == null:
		var km: float = float(metrics.get("distance_km", -1))
		var exercise: float = float(metrics.get("workout_minutes", 0))
		movement_tier = (3 if km >= 5.5 else 2 if km >= 3.5 else 1 if km >= 1.5 else 0) if km >= 0 else (3 if exercise >= 30 else 2 if exercise >= 20 else 1 if exercise >= 10 else 0)
	if lines.is_empty():
		return {"message": "摘要中没有可预览的穿戴记录。"}
	var regen: float = [0.0, 1.0, 2.5, 4.0][sleep_tier]
	var defense: float = [0.0, 0.5, 1.0, 2.0][sleep_tier]
	lines.append("\nPVE 轻身 +%d%% · 回气 +%s%% · 护体 +%s%%\n当天属性首次确认后锁定，PVP 不受影响。" % [movement_tier, str(regen), str(defense)])
	if distance_zhang != null:
		lines.append("神遁距离：%d 丈（1 步＝1 丈）" % distance_zhang)
	return {"date": day, "source": source, "distance_zhang": distance_zhang, "movement_tier": movement_tier, "sleep_tier": sleep_tier, "message": "%s · %s\n\n%s" % [source, day, "\n".join(lines)]}


static func valid_count(value: Variant, maximum: int) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and value >= 0 and value <= maximum and floorf(float(value)) == value


static func valid_date(value: Variant) -> bool:
	if not value is String or value.length() != 10:
		return false
	var pattern := RegEx.new()
	pattern.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
	if pattern.search(value) == null:
		return false
	var year := int(value.substr(0, 4))
	var month := int(value.substr(5, 2))
	var day := int(value.substr(8, 2))
	if year < 1 or month < 1 or month > 12 or day < 1:
		return false
	var leap := year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
	var days := [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	return day <= days[month - 1]
