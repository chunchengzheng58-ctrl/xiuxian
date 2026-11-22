extends "res://scripts/kernel/system_module.gd"
## 正式冒险剧情以服务端为准；不将本地演武胜利当作剧情条件。
var _pending_keys: Dictionary = {}
var _session := 0

func _init() -> void:
	super("story")

func on_backend_changed() -> void:
	_session += 1
	_pending_keys.clear()

func execute(command: String, payload: Dictionary) -> Dictionary:
	if command not in ["story.snapshot", "story.advance", "story.variant"]:
		return await super.execute(command, payload)
	var session := _session
	var signature := JSON.stringify(payload, "", true)
	var key := ""
	if command in ["story.advance", "story.variant"]:
		if not _pending_keys.has(signature):
			_pending_keys[signature] = Crypto.new().generate_random_bytes(16).hex_encode()
		key = _pending_keys[signature]
	var result := await request_backend(command, payload, key)
	if session != _session:
		return Result.failure("SESSION_CHANGED", "账号已切换，请重新读取剧情")
	if not key.is_empty() and result.code not in ["NETWORK_ERROR", "INTERNAL_ERROR", "BACKEND_UNAVAILABLE", "INVALID_RESPONSE", "HTTP_ERROR"]:
		_pending_keys.erase(signature)
	return result
