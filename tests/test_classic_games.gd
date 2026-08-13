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
	_expect(GamePanel.game_count() == 11,
		"game registry does not expose all eleven games")
	_expect(GamePanel.GAMES[-3]["id"] == "snake",
		"snake record id moved or was not registered")
	_expect(GamePanel.GAMES[-2]["id"] == "minesweeper",
		"minesweeper record id moved or was not registered")
	_expect(GamePanel.GAMES[-1]["id"] == "bee",
		"bee-game record id moved or was not registered")
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
