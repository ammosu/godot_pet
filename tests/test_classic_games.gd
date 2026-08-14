extends Node

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"game registry": _test_game_registry,
		"snake collision": _test_snake_collision,
		"mine neighbours": _test_mine_neighbours,
		"first reveal safety": _test_first_reveal_safety,
		"bee flight path": _test_bee_flight_path,
		"survivor geometry": _test_survivor_geometry,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("ClassicGames: '%s' did not run to the end" % name)
	if _failures == 0:
		print("Classic games: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("Classic games: %d failures across %d checks"
			% [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _test_game_registry() -> void:
	_expect(GamePanel.game_count() == 12,
		"game registry does not expose all twelve games")
	_expect(GamePanel.GAMES[-4]["id"] == "snake",
		"snake record id moved or was not registered")
	_expect(GamePanel.GAMES[-3]["id"] == "minesweeper",
		"minesweeper record id moved or was not registered")
	_expect(GamePanel.GAMES[-2]["id"] == "bee",
		"bee-game record id moved or was not registered")
	_expect(GamePanel.GAMES[-1]["id"] == "survivor",
		"survivor-game record id moved or was not registered")
	_done("game registry")


func _test_snake_collision() -> void:
	var body: Array[Vector2i] = [
		Vector2i(3, 2), Vector2i(2, 2), Vector2i(1, 2), Vector2i(1, 3),
	]
	_expect(SnakeGame.hits_wall(Vector2i(-1, 2), Vector2i(8, 8)),
		"snake crossed the left wall")
	_expect(not SnakeGame.hits_wall(Vector2i(7, 7), Vector2i(8, 8)),
		"snake treated the last board cell as a wall")
	_expect(SnakeGame.hits_body(Vector2i(2, 2), body, false),
		"snake did not collide with its middle segment")
	_expect(not SnakeGame.hits_body(Vector2i(1, 3), body, false),
		"snake could not enter the tail cell as it vacated")
	_expect(SnakeGame.hits_body(Vector2i(1, 3), body, true),
		"growing snake incorrectly vacated its tail")
	_done("snake collision")


func _test_mine_neighbours() -> void:
	var corner := MinesweeperGame.neighbours_for(Vector2i.ZERO, Vector2i(4, 4))
	var centre := MinesweeperGame.neighbours_for(Vector2i(2, 2), Vector2i(5, 5))
	_expect(corner.size() == 3, "corner mine cell did not have three neighbours")
	_expect(centre.size() == 8, "centre mine cell did not have eight neighbours")
	_expect(corner.has(Vector2i(1, 1)), "diagonal mine neighbour was omitted")
	_expect(not corner.has(Vector2i(-1, 0)), "off-board mine neighbour was included")
	_done("mine neighbours")


func _test_first_reveal_safety() -> void:
	var game := MinesweeperGame.new()
	game._prepare()
	var first := Vector2i(4, 4)
	game._lay_mines(first)
	_expect(game._mines.size() == 16, "normal board did not lay sixteen mines")
	_expect(not game._mines.has(first), "first revealed mine cell was not safe")
	for neighbour in MinesweeperGame.neighbours_for(first, Vector2i(10, 10)):
		_expect(not game._mines.has(neighbour),
			"first reveal's surrounding safe ring contains a mine")
	game.free()
	_done("first reveal safety")


func _test_bee_flight_path() -> void:
	var start := Vector2(80.0, 60.0)
	var home := Vector2(100.0, 80.0)
	var opening := BeeGame.dive_position(start, home, 220.0, 0.0, 500.0, 60.0)
	var middle := BeeGame.dive_position(start, home, 220.0, 0.5, 500.0, 60.0)
	var returned := BeeGame.dive_position(start, home, 220.0, 1.0, 500.0, 60.0)
	_expect(opening.is_equal_approx(start), "diving bee did not leave from its formation cell")
	_expect(middle.is_equal_approx(Vector2(220.0, 500.0)),
		"diving bee did not reach the player-side target halfway through")
	_expect(returned.is_equal_approx(home),
		"diving bee did not rejoin its moving formation without a jump")
	_expect(BeeGame.circles_overlap(Vector2.ZERO, 4.0, Vector2(7.0, 0.0), 3.0),
		"touching bee and projectile circles did not collide")
	_expect(not BeeGame.circles_overlap(Vector2.ZERO, 4.0, Vector2(7.1, 0.0), 3.0),
		"separated bee and projectile circles collided")
	_expect(BeeGame.moving_circles_overlap(
		Vector2(0.0, 12.0), Vector2(0.0, -12.0), 4.0,
		Vector2(0.0, -12.0), Vector2(0.0, 12.0), 15.0),
		"projectile and diving bee crossed between frames without a hit")
	_expect(not BeeGame.moving_circles_overlap(
		Vector2(20.1, 12.0), Vector2(20.1, -12.0), 4.0,
		Vector2(0.0, -12.0), Vector2(0.0, 12.0), 15.0),
		"projectile beyond the combined radii hit a diving bee")
	_done("bee flight path")


func _test_survivor_geometry() -> void:
	var points: Array[Vector2] = [
		Vector2(90.0, 20.0), Vector2(12.0, 0.0), Vector2(30.0, 40.0),
	]
	_expect(SurvivorGame.nearest_point_index(Vector2.ZERO, points) == 1,
		"survivor auto-aim did not choose the closest enemy")
	_expect(SurvivorGame.nearest_point_index(Vector2.ZERO, []) == -1,
		"survivor auto-aim returned an enemy for an empty field")
	_expect(SurvivorGame.segment_hits_circle(
		Vector2(-20.0, 0.0), Vector2(20.0, 0.0), Vector2.ZERO, 3.0),
		"fast survivor projectile crossed an enemy without a hit")
	_expect(not SurvivorGame.segment_hits_circle(
		Vector2(-20.0, 3.1), Vector2(20.0, 3.1), Vector2.ZERO, 3.0),
		"survivor projectile outside the enemy radius registered a hit")
	_expect(SurvivorGame.circles_overlap(
		Vector2.ZERO, 10.0, Vector2(18.0, 0.0), 8.0),
		"touching survivor body circles did not register contact")
	_expect(not SurvivorGame.circles_overlap(
		Vector2.ZERO, 10.0, Vector2(18.1, 0.0), 8.0),
		"a visible gap between survivor body circles registered contact")
	_expect(SurvivorGame.project_to_screen(
		Vector2(250.0, -50.0), Vector2(200.0, -100.0), Vector2(660.0, 660.0))
		== Vector2(380.0, 380.0),
		"survivor world point was not projected relative to the centred player")
	_expect(SurvivorGame.project_to_screen(
		Vector2(123456.0, -98765.0), Vector2(123456.0, -98765.0),
		Vector2(660.0, 660.0)) == Vector2(330.0, 330.0),
		"survivor player stopped being centred at a distant world coordinate")
	_expect(SurvivorGame.experience_needed_for(4)
		> SurvivorGame.experience_needed_for(3),
		"survivor experience curve did not grow between levels")
	_expect(SurvivorGame.aura_damage_for(1) < SurvivorGame.BASE_DAMAGE,
		"survivor area weapon was not weaker per target than the basic bolt")
	_expect(SurvivorGame.aura_radius_for(2) > SurvivorGame.aura_radius_for(1),
		"survivor aura upgrade did not increase its range")
	_expect(SurvivorGame.aura_interval_for(2) < SurvivorGame.aura_interval_for(1),
		"survivor aura upgrade did not improve its pulse interval")
	_expect(SurvivorGame.ENEMY_PIG.get_size() == Vector2(32.0, 16.0),
		"survivor pig sprite is missing or no longer has two 16px frames")
	_expect(SurvivorGame.ENEMY_SAMURAI.get_size() == Vector2(64.0, 112.0),
		"survivor samurai sprite is missing or its 16px atlas layout changed")
	_expect(SurvivorGame.ENEMY_NINJA.get_size() == Vector2(64.0, 112.0),
		"survivor ninja sprite is missing or its 16px atlas layout changed")
	var game := SurvivorGame.new()
	add_child(game)
	game.size = Vector2(660.0, 660.0)
	game.setup(1.0, null, {})
	game.start()
	game._tick(0.0)
	game._player_position = Vector2(100000.0, -100000.0)
	game._spawn_enemy(0.5)
	_expect(game._enemies.size() == 1,
		"survivor runtime did not spawn an enemy")
	_expect(Vector2(game._enemies[0]["position"]).distance_to(game._player_position)
		> game.size.x * 0.5,
		"survivor enemy spawned at a viewport coordinate instead of around the player")
	_expect(float(game._enemies[0]["collision_radius"])
		< float(game._enemies[0]["radius"]),
		"survivor enemy contact area was not inset from its artwork")
	game._step_attack(1.0)
	_expect(not game._projectiles.is_empty(),
		"survivor runtime did not auto-fire at a spawned enemy")
	game._open_upgrade_choice()
	_expect(game._choosing_upgrade and game._upgrade_choices.size() == 3,
		"survivor level-up did not offer three upgrades")
	var aura_choice := -1
	for i in game._upgrade_choices.size():
		if StringName(game._upgrade_choices[i]["id"]) == &"aura_unlock":
			aura_choice = i
			break
	_expect(aura_choice >= 0,
		"survivor first weapon offer did not guarantee the area weapon")
	game._choose_upgrade(aura_choice)
	_expect(game._aura_level == 1,
		"survivor area weapon choice did not unlock the aura")
	game.queue_free()
	_done("survivor geometry")
