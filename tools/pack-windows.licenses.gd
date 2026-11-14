extends SceneTree
func _initialize() -> void:
	var file := FileAccess.open(OS.get_environment("XIUXIAN_GODOT_LICENSE_OUTPUT"), FileAccess.WRITE)
	file.store_string(Engine.get_license_text() + "\n\nThird-party copyright notices\n" + JSON.stringify(Engine.get_copyright_info(), "  ") + "\n\nThird-party license texts\n" + JSON.stringify(Engine.get_license_info(), "  ") + "\n")
	file.close()
	print("GODOT_LICENSES_EXTRACTED ", Engine.get_version_info().string)
	quit()
