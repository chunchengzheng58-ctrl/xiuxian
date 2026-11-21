extends SceneTree

var passed := 0
var failed := 0

const ROADS = preload("res://scripts/village_roads.gd")
const PAINTED_PATHS := {
	"shopfront": [Vector2(400, 397), Vector2(279, 398), Vector2(197, 378), Vector2(84, 365), Vector2(46, 374)],
	"east_plaza": [Vector2(510, 423), Vector2(559, 400), Vector2(625, 422), Vector2(668, 439)],
	"southwest_steps": [Vector2(454, 451), Vector2(420, 473), Vector2(374, 510), Vector2(302, 546)],
	"practice_platform": [Vector2(528, 333), Vector2(576, 272), Vector2(613, 203), Vector2(620, 167), Vector2(653, 142), Vector2(705, 145)],
	"practice_lower_right": [Vector2(545, 328), Vector2(579, 314), Vector2(600, 281), Vector2(615, 251), Vector2(617, 223), Vector2(619, 195)],
	"east_court": [Vector2(854, 501), Vector2(893, 501), Vector2(932, 487)],
	"stele_right": [Vector2(861, 505), Vector2(899, 505), Vector2(928, 492), Vector2(949, 481), Vector2(971, 480)],
	"portal_stairs": [Vector2(854, 501), Vector2(881, 453), Vector2(910, 389), Vector2(940, 325), Vector2(967, 279)],
}

func check(value: bool, message: String) -> void:
	if value:
		passed += 1
		print("PASS: ", message)
	else:
		failed += 1
		push_error(message)

func _initialize() -> void:
	run.call_deferred()

func traversable(game: Node2D, path: PackedVector2Array) -> bool:
	if path.is_empty() or not game.can_stand(path[0]):
		return false
	for i in range(1, path.size()):
		var delta := path[i] - path[i - 1]
		var pieces := maxi(1, ceili(delta.length() / 3.4))
		var motion := delta / pieces
		for step in range(pieces):
			var origin := path[i - 1] + motion * step
			if game.walk_motion(origin, motion).distance_squared_to(motion) > 0.0036:
				return false
			if game.player.test_move(Transform2D(0.0, origin), motion):
				return false
	return true

func run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await physics_frame
	check(game.can_walk(game.SPAWN), "Village spawn remains walkable")
	for point in [Vector2(620, 820), Vector2(900, 820), Vector2(1080, 820)]:
		check(not game.can_walk(point), "Pond water blocks " + str(point))
	for point in [Vector2(700, 650), Vector2(840, 685), Vector2(920, 710), Vector2(1000, 738), Vector2(1060, 720)]:
		check(game.can_walk(point), "Stone bridge remains walkable at " + str(point))
	for point in [Vector2(760, 780), Vector2(900, 760), Vector2(1144, 796)]:
		check(not game.can_walk(point), "Bridge underside/channel blocks " + str(point))
	check(not game.can_stand(Vector2(520, 700)), "Water edge requires the full player footprint to stay on land")
	for name in PAINTED_PATHS:
		check(traversable(game, ROADS.map_points(PAINTED_PATHS[name])), "Painted road is continuous: " + name)
	var bridge: AStar2D = game.navigation
	check(traversable(game, bridge.get_point_path(0, 12)), "Bridge crosses from plaza to stele")
	check(traversable(game, bridge.get_point_path(12, 0)), "Bridge crosses from stele to plaza")
	for site in game.sites:
		check(traversable(game, bridge.get_point_path(0, site.node)), "A* reaches " + site.id)
		check(game.site_at_map_point(site.position + Vector2(53, 0)) == site.id, "Expanded entrance can be clicked: " + site.id)
		var label: Vector2 = site.label
		check(game.site_at_map_point(label + Vector2(21, 20)) == site.id, "Sign can be clicked: " + site.id)
	var inscription := game.get_node_or_null("PaintedVillageBackground/SteleInscription") as Label
	check(inscription != null, "Inscription is attached to the painted village")
	if inscription != null:
		var center := inscription.get_global_transform() * (inscription.size / 2.0)
		check(center.distance_to(ROADS.STELE_FACE.get_center()) < 1.0, "Inscription is centered on the stone face")
	game.queue_free()
	await process_frame
	print("TERRAIN COLLISION RESULT: ", passed, " passed, ", failed, " failed")
	quit(0 if failed == 0 else 1)
