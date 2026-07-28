extends MiniGame
class_name MemoryGame

## 翻翻看 — turn two cards over, keep them if they match.
##
## The third verb. 接東西 asks where, 跳過去 asks when, and this one asks nothing
## of your hands at all: it is the only game here you can play badly by being
## fast. That is why it exists — three reflex games would have been one game with
## three coats of paint, and a desk pet is something you look at while thinking,
## not only while twitching.
##
## It is also the only one that **ends by being finished** rather than by running
## out of lives, so there is no life row: the run is over when the board is, and
## the score is what it cost you to get there. Every wrong pair is a point, so
## the ceiling is fixed per board size and the record is a record of how few
## mistakes you made — which is the thing a memory game is actually measuring.
##
## Mouse and keyboard reach the same cursor. The pointer moves it by hovering and
## commits by clicking; the arrows move it and space commits. Neither is a mode:
## moving the mouse over the board mid-keyboard is not an error, it just moves
## the cursor.

const MATCH_POINTS := 10
const MISS_PENALTY := 1
## `back` is how long a wrong pair stays face up. It is the difficulty dial that
## isn't board size — a bigger board is more to remember, a shorter look is less
## chance to.
const LEVELS: Array[Dictionary] = [
	{"cols": 3, "rows": 4, "back": 1.15},
	{"cols": 4, "rows": 4, "back": 0.90},
	{"cols": 4, "rows": 5, "back": 0.65},
]

const PAD := 14.0
const GAP := 8.0
## Room kept under the board for the pet. It has nothing to do with the game and
## is the reason the game is worth having: you are doing this *with* something.
const PET_STRIP := 96.0
const REACT_TIME := 0.6

var _cards: Array[Dictionary] = []
var _first := -1
var _second := -1
var _hide_in := 0.0
var _cursor := 0
var _react_left := 0.0
var _react_good := true

## Geometry, recomputed each frame — the Control has no size until it has been
## laid out, and the window is resizable.
var _card := 40.0
var _origin := Vector2.ZERO

var _down: StyleBoxFlat = null
var _up: StyleBoxFlat = null
var _done: StyleBoxFlat = null
var _ring: StyleBoxFlat = null


func design_size() -> Vector2i:
	# Tall: five rows of cards plus a strip for the pet.
	return Vector2i(460, 640)


func ready_hint() -> String:
	return "空白鍵或點一下開始\n方向鍵移動 ・ 空白鍵翻牌\n翻錯一次扣一分，全部配完就結束"


func level_labels() -> PackedStringArray:
	# Named after what actually changes. 悠哉／普通／手忙腳亂 would be a lie here:
	# nothing about this gets faster.
	return PackedStringArray(["3×4", "4×4", "4×5"])


func uses_lives() -> bool:
	return false


func pet_design_height() -> float:
	return 76.0


func setup(ui_scale: float, pack: PetPack, rows: Dictionary) -> void:
	# Before super, which resets and repaints.
	_down = PetStyle.game_card_style(ui_scale, false)
	_up = PetStyle.game_card_style(ui_scale, true)
	_done = PetStyle.game_card_done_style(ui_scale)
	_ring = PetStyle.game_card_cursor_style(ui_scale)
	super.setup(ui_scale, pack, rows)


func _prepare() -> void:
	var pairs := _cols() * _rows() / 2
	var faces := GameArt.ALL.duplicate()
	faces.shuffle()
	var deck: Array[int] = []
	for i in pairs:
		deck.append(faces[i])
		deck.append(faces[i])
	deck.shuffle()

	_cards.clear()
	for face in deck:
		_cards.append({"face": face, "up": false, "done": false})
	_first = -1
	_second = -1
	_hide_in = 0.0
	_cursor = 0
	_react_left = 0.0


func _cols() -> int:
	return int(LEVELS[_level]["cols"])


func _rows() -> int:
	return int(LEVELS[_level]["rows"])


# --- Frame --------------------------------------------------------------------

func _tick(delta: float) -> void:
	_measure()
	if _hide_in > 0.0:
		_hide_in -= delta
		if _hide_in <= 0.0:
			_turn_back()
	if _react_left > 0.0:
		_react_left = maxf(0.0, _react_left - delta)
		var ease_out := _react_left / REACT_TIME
		_pet.set_state(&"happy" if _react_good else &"sad")
		_pet.set_squash((0.12 if _react_good else -0.09) * ease_out)
	else:
		_pet.set_state(&"idle")
		_pet.set_squash(0.0)
	_pet.stand_on(_ground_y(), size.x * 0.5)


## Cards are sized to fit whatever is left after the padding and the pet strip,
## rather than being a fixed size the window has to be big enough for. That is
## what lets one layout serve a 12-card board and a 20-card one.
func _measure() -> void:
	var pad := PAD * _scale
	var gap := GAP * _scale
	var cols := _cols()
	var rows := _rows()
	var avail := Vector2(
		size.x - pad * 2.0,
		size.y - pad * 2.0 - PET_STRIP * _scale)
	_card = maxf(8.0, minf(
		(avail.x - gap * float(cols - 1)) / float(cols),
		(avail.y - gap * float(rows - 1)) / float(rows)))
	var grid := Vector2(
		float(cols) * _card + gap * float(cols - 1),
		float(rows) * _card + gap * float(rows - 1))
	_origin = Vector2((size.x - grid.x) * 0.5, pad + (avail.y - grid.y) * 0.5)


func _card_rect(index: int) -> Rect2:
	var step := _card + GAP * _scale
	var col := index % _cols()
	var row := index / _cols()
	return Rect2(_origin + Vector2(float(col) * step, float(row) * step),
		Vector2(_card, _card))


func _index_at(pos: Vector2) -> int:
	for i in _cards.size():
		if _card_rect(i).has_point(pos):
			return i
	return -1


# --- Turning cards ------------------------------------------------------------

func _flip(index: int) -> void:
	if not is_playing() or index < 0 or index >= _cards.size():
		return
	# A wrong pair still on show is turned back *now* rather than the click being
	# swallowed. Waiting out someone else's timer is the most annoying thing a
	# memory game can do, and the pair has already been seen by then anyway.
	if _hide_in > 0.0:
		_turn_back()

	var card: Dictionary = _cards[index]
	if bool(card["done"]) or bool(card["up"]):
		return
	card["up"] = true

	if _first < 0:
		_first = index
		return

	if int(_cards[_first]["face"]) == int(card["face"]):
		_cards[_first]["done"] = true
		card["done"] = true
		_first = -1
		_add_score(MATCH_POINTS)
		_react(true)
		if _solved():
			_finish()
		return

	_second = index
	_hide_in = float(LEVELS[_level]["back"])
	_add_score(-MISS_PENALTY)
	_react(false)


func _turn_back() -> void:
	if _first >= 0:
		_cards[_first]["up"] = false
	if _second >= 0:
		_cards[_second]["up"] = false
	_first = -1
	_second = -1
	_hide_in = 0.0


func _solved() -> bool:
	for card in _cards:
		if not bool(card["done"]):
			return false
	return true


func _react(good: bool) -> void:
	_react_left = REACT_TIME
	_react_good = good


# --- Input --------------------------------------------------------------------

func _key_pressed(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_A:
			_move_cursor(-1, 0)
		KEY_RIGHT, KEY_D:
			_move_cursor(1, 0)
		KEY_UP, KEY_W:
			_move_cursor(0, -1)
		KEY_DOWN, KEY_S:
			_move_cursor(0, 1)
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_flip(_cursor)
		_:
			return false
	return true


## Stops at the edges rather than wrapping. A grid this small is read as a shape,
## and a cursor that reappears on the far side reads as a bug.
func _move_cursor(dx: int, dy: int) -> void:
	var cols := _cols()
	var col := clampi(_cursor % cols + dx, 0, cols - 1)
	var row := clampi(_cursor / cols + dy, 0, _rows() - 1)
	_cursor = row * cols + col


func _pointer_moved(pos: Vector2) -> void:
	var hit := _index_at(pos)
	if hit >= 0:
		_cursor = hit


func _pointer_clicked(pos: Vector2) -> void:
	var hit := _index_at(pos)
	if hit >= 0:
		_cursor = hit
		_flip(hit)


# --- Drawing ------------------------------------------------------------------

func _paint() -> void:
	# The same line the other two games stand on. Without it the pet reads as
	# floating in the bottom of the box rather than waiting under the board, and
	# it doubles as the rule between the board and the part that isn't the game.
	_draw_ground()
	if _down == null:
		return
	for i in _cards.size():
		var rect := _card_rect(i)
		var card: Dictionary = _cards[i]
		var shown := bool(card["up"]) or bool(card["done"])
		draw_style_box(_done if bool(card["done"]) else (_up if shown else _down), rect)
		if shown:
			GameArt.draw_item(self, int(card["face"]), rect.get_center(), _card * 0.30)
	# The cursor last, so it sits over whatever state the card under it is in.
	if is_playing() and _cursor >= 0 and _cursor < _cards.size():
		draw_style_box(_ring, _card_rect(_cursor))
