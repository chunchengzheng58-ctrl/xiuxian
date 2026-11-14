extends SceneTree

const Roster = preload("res://scripts/family_roster.gd")
const State = preload("res://scripts/game_state.gd")
var scene: Node
var failures := 0
var work: String
var output: String

func _initialize() -> void:
	root.position = Vector2i(-12000, -12000)
	root.size = Vector2i(1440, 900)
	work = OS.get_environment("XIUXIAN_LEGACY_WORK")
	output = OS.get_environment("XIUXIAN_LEGACY_OUTPUT")
	run.call_deferred()

func check(value: bool, label: String) -> bool:
	print("REMOTE_LEGACY ", "PASS " if value else "FAIL ", label)
	if not value:
		failures += 1
	return value

func wait_for(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func finish() -> void:
	print("REMOTE_LEGACY_TEST: ", failures, " failures")
	if is_instance_valid(scene):
		scene.queue_free()
		await process_frame
	quit(1 if failures else 0)

func run() -> void:
	var source_path := work.path_join("legacy-source.json")
	var legacy := Roster.new()
	legacy.persist_enabled = false
	legacy.owner_state.equipment.qi = 99999
	legacy.owner_state.equipment.materials = 99999
	legacy.owner_state.equipment.inventory = [{"id": "gear_000001", "template": 0, "rarity": 4, "upgrade_level": 10}]
	legacy.owner_state.cultivation = 88888
	legacy.owner_state.complete_boss("b00", {"time": 1})
	legacy.add_member({"name": "旧档家人", "relation": "父亲", "age": 60, "sex": "男", "title": "旧档家人", "avatar": "male", "mode": "family", "consent": true})
	write_json(source_path, legacy.to_data())
	legacy.dispose()
	var source_text := FileAccess.get_file_as_string(source_path)
	scene = load("res://scenes/main.tscn").instantiate()
	scene.account_cache_root_override = work.path_join("cache")
	scene.account_legacy_source_override = source_path
	root.add_child(scene)
	current_scene = scene
	scene.account_ready = false
	scene.account_api.allow_autostart = false
	var original_family = scene.family
	scene.ui.open_login()
	var login = scene.ui.account_panel
	login.username_input.text = "legacy_safety"
	login.password_input.text = "legacy-fixture-password"
	login.submit()
	if not check(await wait_for(func(): return scene.pending_account_roster != null and is_instance_valid(scene.ui.account_panel) and scene.ui.account_panel.migration_mode), "Authenticated login offers an explicit legacy archive choice"):
		await finish()
		return
	check(not scene.account_ready and scene.family == original_family, "Staged account remains separate from the live roster")
	var pending = scene.pending_account_roster
	var remote_id: String = pending.owner_state.cultivator_id
	check(pending.is_remote() and pending.owner_state.equipment.qi == 321, "Staged roster starts from the server wallet")
	scene.ui.import_old_account()
	if not check(await wait_for(func(): return not pending.setup_in_progress and not pending.legacy_archive.is_empty() and scene.ui.account_panel.status_label.text.contains("旧档已备份")), "Injected post-archive server failure remains recoverable on the account panel"):
		await finish()
		return
	check(not scene.account_ready and scene.family == original_family and scene.pending_account_roster == pending, "Failed synchronization cannot activate a partially prepared account")
	check(pending.is_remote() and pending.owner_state.cultivator_id == remote_id, "Archiving cannot erase the authoritative cultivator identity")
	check(pending.owner_state.equipment.qi == 321 and pending.owner_state.equipment.inventory.size() == 1, "Local rewards never replace the authoritative wallet or gear")
	var archive_path: String = pending.legacy_archive.path
	check(FileAccess.file_exists(archive_path) and FileAccess.get_file_as_string(archive_path) == source_text, "A complete independent backup preserves the legacy game save")
	check(FileAccess.get_file_as_string(source_path) == source_text, "The original legacy file remains intact")
	var restored := Roster.new()
	restored.persist_enabled = false
	restored.save_file_override = archive_path
	restored.load_game(State.new())
	check(not restored.load_blocked and restored.owner_state.equipment.qi == 99999 and restored.members.size() == 1, "Archived data can actually restore the old roster offline")
	restored.dispose()
	var rejected: Dictionary = await pending.apply_remote([], null)
	check(not rejected.ok and pending.owner_state.cultivator_id == remote_id, "An incomplete server roster is rejected without removing the remote owner")
	scene.ui.import_old_account()
	if not check(await wait_for(func(): return scene.account_ready), "Retry enters the game only after fresh authoritative synchronization"):
		await finish()
		return
	check(scene.family.is_remote() and scene.state.is_remote() and scene.state.cultivator_id == remote_id, "The active formal account remains remote after legacy confirmation")
	check(scene.state.equipment.qi == 321 and scene.state.equipment.materials == 17 and scene.state.equipment.inventory.size() == 1, "Existing server resources survive confirmation exactly")
	check(scene.family.members.is_empty() and not scene.state.boss_cleared("b00"), "Archived elders and local boss clears stay outside the online roster")
	check(not scene.state.record_task("planned_record", true).ok and not scene.state.draw_equipment(1, "cannot-mint-locally").ok, "Formal accounts cannot mint offline task rewards or gacha after archiving")
	scene.ui.open_family()
	scene.ui.family_panel.show_legacy_archive()
	await process_frame
	var dialogs = scene.ui.family_panel.find_children("*", "AcceptDialog", true, false)
	check(dialogs.size() == 1 and dialogs[0].visible, "The family screen exposes the saved archive location")
	if not output.is_empty():
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(output.path_join("legacy-archive.png")) == OK, "Saved archive location preview")
	var reopened := Roster.new()
	reopened.cache_root_override = scene.family.cache_root_override
	reopened.legacy_source_override = source_path
	var opened: Dictionary = reopened.open_account(scene.family.account)
	check(opened.ok and not opened.needs_import and reopened.legacy_archive.path == archive_path and reopened.owner_state.is_remote(), "Relogin retains the archive record and remote owner in its cache")
	reopened.dispose()
	var blocked := Roster.new()
	blocked.cache_root_override = work.path_join("blocked")
	blocked.legacy_source_override = source_path
	blocked.open_account(scene.family.account)
	var blocker := FileAccess.open(blocked.cache_root_override, FileAccess.WRITE)
	blocker.store_string("fixture blocks archive directory creation")
	blocker.close()
	blocked.owner_state.cultivator_id = remote_id
	check(not blocked.import_legacy() and blocked.owner_state.cultivator_id == remote_id and FileAccess.get_file_as_string(source_path) == source_text, "Backup write failure preserves both remote identity and original file")
	blocked.dispose()
	await finish()
