extends "res://scripts/kernel/system_module.gd"
## 好友关系与私信由游戏服务管理，本地内核不持久化内容。

const WRITES = ["social.profile", "social.invite", "social.respond", "social.unblock", "social.send"]
const READS = ["social.home", "social.chat", "social.read"]
var _pending_keys: Dictionary = {}

func _init() -> void:
	super("social")

func on_backend_changed() -> void:
	_pending_keys.clear()

func execute(command: String, payload: Dictionary) -> Dictionary:
	if command in READS:
		return await request_backend(command, payload)
	if command not in WRITES:
		return await super.execute(command, payload)
	var signature := command + ":" + JSON.stringify(payload, "", true).sha256_text()
	if not _pending_keys.has(signature):
		_pending_keys[signature] = Crypto.new().generate_random_bytes(16).hex_encode()
	var key: String = _pending_keys[signature]
	var result := await request_backend(command, payload, key)
	if _pending_keys.get(signature) == key and result.code not in ["NETWORK_ERROR", "INTERNAL_ERROR", "BACKEND_UNAVAILABLE", "INVALID_RESPONSE", "HTTP_ERROR"]:
		_pending_keys.erase(signature)
	return result
