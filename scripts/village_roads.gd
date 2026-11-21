extends RefCounted

const BRIDGE_DECK = [
	Vector2(696, 607), Vector2(768, 594), Vector2(840, 618), Vector2(897, 644),
	Vector2(956, 678), Vector2(1008, 716), Vector2(1051, 748), Vector2(1018, 784),
	Vector2(969, 778), Vector2(907, 726), Vector2(848, 685), Vector2(779, 656),
	Vector2(714, 638),
]
const EAST_LANDING = [
	Vector2(980, 749), Vector2(1018, 731), Vector2(1052, 752), Vector2(1104, 728),
	Vector2(1135, 711), Vector2(1100, 678), Vector2(1123, 648),
	Vector2(1194, 634), Vector2(1225, 647), Vector2(1247, 701),
	Vector2(1200, 725), Vector2(1123, 755), Vector2(1060, 785), Vector2(1011, 792),
]
const BRIDGE_ROUTE = [
	Vector2(747, 620), Vector2(831, 646), Vector2(909, 687), Vector2(997, 751),
	Vector2(1033, 770), Vector2(1100, 746), Vector2(1170, 716), Vector2(1211, 696),
	Vector2(1196, 659), Vector2(1144, 665),
]
# Measured between the inner gold borders, excluding the stone bevel.
const STELE_FACE := Rect2(1177, 493, 38, 105)

# Points trace the painted, 1080 x 675 village reference. The scene uses 1440 x 900.
const VILLAGE_ROADS = {
	"plaza_and_shopfront": [
		Vector2(25, 365), Vector2(100, 353), Vector2(150, 359), Vector2(197, 365),
		Vector2(232, 376), Vector2(260, 383), Vector2(365, 357), Vector2(436, 345),
		Vector2(499, 316), Vector2(551, 299), Vector2(580, 313), Vector2(585, 352),
		Vector2(563, 373), Vector2(553, 389), Vector2(598, 409), Vector2(665, 426),
		Vector2(700, 444), Vector2(680, 461), Vector2(608, 439), Vector2(551, 453),
		Vector2(513, 465), Vector2(464, 464), Vector2(410, 460), Vector2(366, 468),
		Vector2(319, 444), Vector2(279, 424), Vector2(238, 409), Vector2(189, 394),
		Vector2(146, 386), Vector2(100, 378), Vector2(28, 388),
	],
	"southwest_steps": [
		Vector2(406, 444), Vector2(466, 449), Vector2(449, 489), Vector2(413, 511),
		Vector2(380, 529), Vector2(356, 554), Vector2(312, 565), Vector2(286, 563),
		Vector2(268, 544), Vector2(278, 523), Vector2(325, 506), Vector2(361, 488),
		Vector2(380, 475), Vector2(384, 453),
	],
	"practice_stairs_and_platform": [
		Vector2(516, 331), Vector2(540, 303), Vector2(559, 278), Vector2(577, 248),
		Vector2(594, 214), Vector2(597, 185), Vector2(581, 166), Vector2(559, 152),
		Vector2(575, 131), Vector2(616, 112), Vector2(655, 110), Vector2(699, 118),
		Vector2(735, 135), Vector2(752, 148), Vector2(714, 165), Vector2(670, 164),
		Vector2(641, 177), Vector2(638, 202), Vector2(624, 225), Vector2(605, 260),
		Vector2(589, 289), Vector2(574, 318), Vector2(550, 342),
	],
	"practice_lower_approach": [
		Vector2(530, 321), Vector2(552, 297), Vector2(572, 282), Vector2(587, 258),
		Vector2(592, 233), Vector2(599, 208), Vector2(632, 207), Vector2(638, 228),
		Vector2(625, 257), Vector2(616, 282), Vector2(602, 307), Vector2(580, 332),
		Vector2(552, 349),
	],
	"east_court_and_portal_stairs": [
		Vector2(804, 487), Vector2(838, 466), Vector2(857, 450), Vector2(876, 420),
		Vector2(898, 385), Vector2(912, 348), Vector2(922, 320), Vector2(936, 292),
		Vector2(944, 270), Vector2(973, 264), Vector2(1004, 273), Vector2(1021, 285),
		Vector2(990, 293), Vector2(970, 314), Vector2(955, 345), Vector2(943, 373),
		Vector2(926, 407), Vector2(921, 444), Vector2(938, 463), Vector2(957, 476),
		Vector2(946, 504), Vector2(913, 520), Vector2(867, 532), Vector2(834, 532),
		Vector2(811, 515),
	],
	"stele_right_path": [
		Vector2(879, 498), Vector2(900, 480), Vector2(925, 475), Vector2(936, 461),
		Vector2(955, 457), Vector2(975, 468), Vector2(984, 484), Vector2(966, 497),
		Vector2(942, 509), Vector2(909, 521), Vector2(880, 526),
	],
}

static func map_points(points: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		result.append(point * (4.0 / 3.0))
	return result
