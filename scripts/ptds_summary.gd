extends RefCounted

const MAX_BYTES = 4096
const SCHEMA = "xiuxian.ptds-oura.v1"


static func read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "无法打开摘要文件。"
	if file.get_length() > MAX_BYTES:
		return "摘要文件过大，请选择 PTDS 导出工具生成的 JSON。"
	return preview(file.get_buffer(MAX_BYTES + 1).get_string_from_utf8())


static func preview(json: String) -> String:
	if json.to_utf8_buffer().size() > MAX_BYTES:
		return "摘要文件过大，请选择 PTDS 导出工具生成的 JSON。"
	var data: Variant = JSON.parse_string(json)
	if not data is Dictionary or data.get("schema") != SCHEMA:
		return "摘要格式不受支持，请使用项目提供的 PTDS 导出工具。"
	var day: Variant = data.get("date")
	if not valid_date(day):
		return "摘要日期无效。"
	var lines := PackedStringArray()
	if data.has("steps"):
		var steps: Variant = data["steps"]
		if not valid_count(steps, 1000000):
			return "摘要中的步数无效。"
		lines.append("步数：%d 步" % int(steps))
	if data.has("sleep_minutes"):
		var minutes: Variant = data["sleep_minutes"]
		if not valid_count(minutes, 1440):
			return "摘要中的睡眠时长无效。"
		lines.append("睡眠时长：%d 分钟" % int(minutes))
	if lines.is_empty():
		return "摘要中没有可预览的穿戴记录。"
	return "Oura · %s\n\n%s" % [day, "\n".join(lines)]


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
