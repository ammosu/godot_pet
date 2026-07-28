extends Node

## The pet's needs, and the only thing that makes it feel like it exists between
## conversations. Everything is 0-100 and "higher is better", so one decay rule
## covers all of them.
##
## Feeds two things: the system prompt (so the pet's mood colours what it says)
## and the brain (so an exhausted pet goes to sleep on its own).

const SAVE_PATH := "user://state.json"
const SAVE_INTERVAL := 30.0

## A new pet is fed and rested but doesn't know you yet.
const STARTING := {
	&"fullness": 70.0,
	&"energy": 70.0,
	&"mood": 60.0,
	&"affection": 10.0,
}
const NEEDS: Array[StringName] = [&"fullness", &"energy", &"mood", &"affection"]

## Points lost per minute of wall-clock time.
const DECAY := {
	## Roughly fourteen hours to empty. Faster than this and every morning
	## starts with a starving pet, since overnight is eight hours on its own.
	&"fullness": 0.12,
	&"energy": 0.28,     # worn out after roughly six hours awake
	&"mood": 0.35,       # pulled toward `_mood_target()`, not toward zero
	&"affection": 0.02,  # forgets you very slowly
}
## Sleeping restores energy far faster than being awake drains it.
const SLEEP_RECOVERY := 2.0

## Mood settles here when the pet is fed and rested.
const MOOD_BASELINE := 60.0

const EXHAUSTED_BELOW := 20.0
const RESTED_ABOVE := 55.0

## Come back after a fortnight and the pet should be hungry, not a corpse.
const MAX_OFFLINE_MINUTES := 24.0 * 60.0

var _needs := {}
var _asleep := false
var _last_talk_at := 0.0
var _since_save := 0.0


func _ready() -> void:
	for need in NEEDS:
		_needs[need] = float(STARTING[need])
	_last_talk_at = Time.get_unix_time_from_system()
	_load()

	EventBus.pet_tapped.connect(_on_tapped)
	EventBus.pet_released.connect(_on_released)
	EventBus.user_said.connect(_on_user_said)
	EventBus.file_content_said.connect(_on_user_said)
	EventBus.pet_activity_changed.connect(_on_activity_changed)

	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.timeout.connect(_tick)
	add_child(timer)
	timer.start()


func _exit_tree() -> void:
	_save()


# --- Reading ------------------------------------------------------------------

func get_need(need: StringName) -> float:
	return float(_needs.get(need, 0.0))


func snapshot() -> Dictionary:
	return _needs.duplicate()


func is_exhausted() -> bool:
	return get_need(&"energy") < EXHAUSTED_BELOW


func is_rested() -> bool:
	return get_need(&"energy") > RESTED_ABOVE


func minutes_since_talk() -> float:
	return (Time.get_unix_time_from_system() - _last_talk_at) / 60.0


## The block appended to the system prompt. Qualitative rather than raw numbers,
## which models act on far more reliably.
func describe() -> String:
	var lines := PackedStringArray([
		"- 飽食度：%s" % _grade(&"fullness", ["很餓，可以抱怨一下", "有點餓", "還好", "很飽"]),
		"- 精力：%s" % _grade(&"energy", ["快睡著了", "有點累", "還行", "精神很好"]),
		"- 心情：%s" % _grade(&"mood", ["很低落", "有點悶", "普通", "很好"]),
		"- 對使用者的熟悉度：%s" % _grade(&"affection", ["還不太熟", "還在觀察他", "算熟了", "很黏他"]),
		"- 距離上次講話：%s" % _describe_gap(),
	])
	return "\n".join(lines)


func _grade(need: StringName, labels: Array) -> String:
	var value := get_need(need)
	if value < 20.0:
		return labels[0]
	if value < 40.0:
		return labels[1]
	if value < 70.0:
		return labels[2]
	return labels[3]


func _describe_gap() -> String:
	var minutes := minutes_since_talk()
	if minutes < 5.0:
		return "剛剛才聊過"
	if minutes < 60.0:
		return "%d 分鐘前" % int(minutes)
	if minutes < 24.0 * 60.0:
		return "%d 小時前" % int(minutes / 60.0)
	return "超過一天了"


# --- Changing -----------------------------------------------------------------

func feed() -> void:
	_add(&"fullness", 35.0)
	_add(&"mood", 4.0)


func _on_tapped() -> void:
	_add(&"mood", 3.0)
	_add(&"affection", 0.4)


func _on_released() -> void:
	_add(&"mood", 2.0)
	_add(&"affection", 0.2)


func _on_user_said(_text: String) -> void:
	_last_talk_at = Time.get_unix_time_from_system()
	_add(&"mood", 2.0)
	_add(&"affection", 1.0)


func _on_activity_changed(activity: StringName) -> void:
	_asleep = activity == &"sleep"


func _add(need: StringName, amount: float) -> void:
	_needs[need] = clampf(get_need(need) + amount, 0.0, 100.0)


# --- Time ---------------------------------------------------------------------

func _tick() -> void:
	_advance(1.0 / 60.0, _asleep)
	EventBus.state_tick.emit(snapshot())

	_since_save += 1.0
	if _since_save >= SAVE_INTERVAL:
		_save()


## Advance the needs by `minutes`. While asleep — including while the app is
## closed — energy comes back instead of draining.
func _advance(minutes: float, resting: bool) -> void:
	_add(&"fullness", -DECAY[&"fullness"] * minutes)
	_add(&"affection", -DECAY[&"affection"] * minutes)
	if resting:
		_add(&"energy", SLEEP_RECOVERY * minutes)
	else:
		_add(&"energy", -DECAY[&"energy"] * minutes)
	_needs[&"mood"] = move_toward(
		get_need(&"mood"), _mood_target(), DECAY[&"mood"] * minutes)


## Mood isn't independent: a hungry, tired pet is a grumpy one.
func _mood_target() -> float:
	return MOOD_BASELINE * 0.4 + get_need(&"fullness") * 0.3 + get_need(&"energy") * 0.3


# --- Persistence --------------------------------------------------------------

func _save() -> void:
	_since_save = 0.0
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("PetState: cannot write %s" % SAVE_PATH)
		return
	var payload := _needs.duplicate()
	payload["saved_at"] = Time.get_unix_time_from_system()
	payload["last_talk_at"] = _last_talk_at
	file.store_string(JSON.stringify(payload))


func _load() -> void:
	var raw := FileAccess.get_file_as_string(SAVE_PATH)
	if raw.is_empty():
		return
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("PetState: ignoring malformed %s" % SAVE_PATH)
		return

	for need in NEEDS:
		if data.has(need):
			_needs[need] = clampf(float(data[need]), 0.0, 100.0)
	_last_talk_at = float(data.get("last_talk_at", _last_talk_at))

	# Catch up on the time the app wasn't running, capped so a long absence
	# doesn't flatten everything to zero. Count it as sleep: coming back to a
	# rested but hungry pet reads better than a comatose one.
	var elapsed := Time.get_unix_time_from_system() - float(data.get("saved_at", 0.0))
	if elapsed > 0.0:
		_advance(minf(elapsed / 60.0, MAX_OFFLINE_MINUTES), true)
