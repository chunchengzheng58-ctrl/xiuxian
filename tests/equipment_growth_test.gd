extends SceneTree

const Rules = preload("res://scripts/equipment_rules.gd")
const State = preload("res://scripts/game_state.gd")
var failures := 0

func check(ok: bool, description: String) -> void:
	print(("PASS " if ok else "FAIL ") + description)
	if not ok:
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var state = State.new()
	state.persist_enabled = false
	state.apply_health_profile(state.HealthProfile.mock(40, 1))
	var baseline: Dictionary = state.battle_stats()
	for index in [0, 1, 3, 4]:
		var item := {"id": "gear_%06d" % (index + 1), "template": index, "rarity": 0, "school": 1, "upgrade_level": 0}
		state.equipment.inventory.append(item)
		state.equip_item(item.id)
	var stats: Dictionary = state.battle_stats()
	check(stats.attack == baseline.attack + 7, "Two-piece attack bonus reaches the normal PvE battle snapshot")
	check(stats.max_mp == baseline.max_mp + 17, "Four-piece spirit bonus reaches the normal PvE battle snapshot")
	check(Rules.detail({"id": "gear_999999", "template": 0, "rarity": 0, "upgrade_level": 10}).amount == 14, "Ten upgrades improve a common weapon to fourteen attack")
	var restored := Rules.normalize(state.equipment)
	check(restored.inventory[0].school == 1 and restored.equipped.size() == 4, "Saved set identities and equipped slots survive reload")
	state.equipment.legendary_pity = 49
	state.equipment.qi = 70
	state.equipment.wish_school = 2
	state.equipment_rng.seed = 0
	var pull: Dictionary = state.draw_equipment(1, "growth-pity")
	check(pull.ok and pull.items[0].rarity >= 3 and pull.items[0].school == 2, "A local fiftieth wish awards the chosen school at legendary or above")
	check(state.equipment.legendary_pity == 0, "The legendary counter resets after receiving legendary gear")
	print("EQUIPMENT_GROWTH_TEST: ", failures, " failures")
	quit(0 if failures == 0 else 1)
