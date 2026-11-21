class_name MobileUi
extends RefCounted
## Shared mobile input behavior for the Godot/Web and native touch clients.
## Keep focus user-driven so opening a modal does not summon the keyboard by itself.

static func is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web") or DisplayServer.is_touchscreen_available()

static func configure_text_input(control: Control) -> void:
	if control == null:
		return
	control.focus_mode = Control.FOCUS_ALL
	control.mouse_filter = Control.MOUSE_FILTER_STOP
	# LineEdit and TextEdit expose this property in Godot 4. Use set() so this
	# helper can accept both controls without duplicating the setup.
	control.set("virtual_keyboard_enabled", true)
	if is_mobile():
		control.custom_minimum_size.y = maxf(control.custom_minimum_size.y, 52.0)
	control.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and event.pressed:
			control.grab_focus()
			_ensure_visible(control)
	)
	control.focus_entered.connect(func() -> void:
		_ensure_visible(control)
	)

static func _ensure_visible(control: Control) -> void:
	var parent := control.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			(parent as ScrollContainer).ensure_control_visible(control)
			return
		parent = parent.get_parent()
