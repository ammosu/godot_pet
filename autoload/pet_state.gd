extends Node

## The companion's persistent condition. `care` and `bond` are deliberately
## role-neutral: a pet can render them as fullness/affection, a robot as
## charge/trust, and another form can hide the care dimension entirely.
##
## Feeds two things: the system prompt (so the pet's mood colours what it says)
## and the brain (so an exhausted pet goes to sleep on its own).

const SAVE_PATH := "user://state.json"
const SAVE_INTERVAL := 30.0
const SAVE_VERSION := 2

## A new companion is rested but doesn't know you yet. The current role profile
## supplies care's starting value.
const STARTING := {
	&"care": 70.0,
	&"energy": 70.0,
	&"mood": 60.0,
	&"bond": 10.0,
}
const NEEDS: Array[StringName] = [&"care", &"energy", &"mood", &"bond"]

## Points lost per minute of wall-clock time.
const DECAY := {
	&"energy": 0.28,     # worn out after roughly six hours awake
	&"mood": 0.35,       # pulled toward `_mood_target()`, not toward zero
	&"bond": 0.02,       # familiarity fades very slowly
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
var _highest_bond_stage := 0
var _offline_minutes := 0.0


func _ready() -> void:
	for need in NEEDS:
		_needs[need] = float(STARTING[need])
	_needs[&"care"] = CompanionProfile.care_starting()
	_last_talk_at = Time.get_unix_time_from_system()
	_load()

	EventBus.pet_tapped.connect(_on_tapped)
	EventBus.pet_released.connect(_on_released)
	EventBus.user_said.connect(_on_user_said)
	EventBus.file_content_said.connect(_on_user_said)
	EventBus.image_content_said.connect(_on_user_said)
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


func offline_minutes() -> float:
	return _offline_minutes


## The block appended to the system prompt. Qualitative rather than raw numbers,
## which models act on far more reliably.
func describe() -> String:
	var lines := PackedStringArray()
	if CompanionProfile.care_enabled():
		lines.append("- %s：%s" % [CompanionProfile.care_label(),
			CompanionProfile.grade(&"care", get_need(&"care"))])
	for need: StringName in [&"energy", &"mood", &"bond"]:
		lines.append("- %s：%s" % [CompanionProfile.state_label(need),
			CompanionProfile.grade(need, get_need(need))])
	lines.append("- 距離上次講話：%s" % _describe_gap())
	return "\n".join(lines)


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

func care() -> void:
	if not CompanionProfile.care_enabled():
		return
	_add(&"care", CompanionProfile.care_amount())
	_add(&"mood", CompanionProfile.care_mood_amount())


## Compatibility for older callers while the UI migrates to role-neutral copy.
func feed() -> void:
	care()


## A run of the mini-game, played out to the end.
##
## Mood and bond are the point: this is time spent together, which is what
## those two measure, and they move whether or not the run went well — losing
## badly at something with someone is still doing it with them.
##
## Care moves too when this role treats caught objects as useful, but it is
## capped hard. A catch game that fully restores care would quietly replace the
## role's deliberate care action with a worse loop.
func play_session(caught: int, score: int) -> void:
	_add(&"mood", clampf(3.0 + float(score) * 0.25, 3.0, 12.0))
	_add(&"bond", 2.0)
	_add(&"care", minf(float(caught) * CompanionProfile.game_treat_amount(),
		CompanionProfile.game_treat_cap()))


func _on_tapped() -> void:
	_add(&"mood", 3.0)
	_add(&"bond", 0.4)


func _on_released() -> void:
	_add(&"mood", 2.0)
	_add(&"bond", 0.2)


func _on_user_said(_text: String) -> void:
	_last_talk_at = Time.get_unix_time_from_system()
	_add(&"mood", 2.0)
	_add(&"bond", 1.0)


func _on_activity_changed(activity: StringName) -> void:
	_asleep = activity == &"sleep"


func _add(need: StringName, amount: float) -> void:
	if need == &"care" and not CompanionProfile.care_enabled():
		return
	_needs[need] = clampf(get_need(need) + amount, 0.0, 100.0)
	if need == &"bond":
		var stage := CompanionProfile.bond_stage_index(get_need(&"bond"))
		if stage > _highest_bond_stage:
			_highest_bond_stage = stage
			EventBus.bond_stage_reached.emit(CompanionProfile.bond_stage(get_need(&"bond")))


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
	_add(&"care", -CompanionProfile.care_decay_per_minute() * minutes)
	_add(&"bond", -DECAY[&"bond"] * minutes)
	if resting:
		_add(&"energy", SLEEP_RECOVERY * minutes)
	else:
		_add(&"energy", -DECAY[&"energy"] * minutes)
	_needs[&"mood"] = move_toward(
		get_need(&"mood"), _mood_target(), DECAY[&"mood"] * minutes)


## Mood isn't independent: a hungry, tired pet is a grumpy one.
func _mood_target() -> float:
	if CompanionProfile.care_enabled():
		return MOOD_BASELINE * 0.4 + get_need(&"care") * 0.3 + get_need(&"energy") * 0.3
	return MOOD_BASELINE * 0.5 + get_need(&"energy") * 0.5


# --- Persistence --------------------------------------------------------------

func _save() -> void:
	_since_save = 0.0
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("PetState: cannot write %s" % SAVE_PATH)
		return
	var payload := _needs.duplicate()
	payload["version"] = SAVE_VERSION
	payload["saved_at"] = Time.get_unix_time_from_system()
	payload["last_talk_at"] = _last_talk_at
	payload["highest_bond_stage"] = _highest_bond_stage
	file.store_string(JSON.stringify(payload))


func _load() -> void:
	var raw := FileAccess.get_file_as_string(SAVE_PATH)
	if raw.is_empty():
		return
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("PetState: ignoring malformed %s" % SAVE_PATH)
		return

	# Version 1 called these fullness/affection. Read both spellings, then save
	# only the role-neutral keys on the next normal save.
	var migrated := migrate_saved_needs(data, _needs)
	for need in NEEDS:
		_needs[need] = migrated[need]
	_highest_bond_stage = int(data.get("highest_bond_stage",
		CompanionProfile.bond_stage_index(get_need(&"bond"))))
	_last_talk_at = float(data.get("last_talk_at", _last_talk_at))

	# Catch up on the time the app wasn't running, capped so a long absence
	# doesn't flatten everything to zero. Count it as sleep: coming back to a
	# rested but hungry pet reads better than a comatose one.
	var elapsed := Time.get_unix_time_from_system() - float(data.get("saved_at", 0.0))
	if elapsed > 0.0:
		_offline_minutes = minf(elapsed / 60.0, MAX_OFFLINE_MINUTES)
		_advance(_offline_minutes, true)


## Pure migration seam for regression tests. Version 1 values are accepted,
## while version 2 wins if a hand-edited file happens to contain both.
static func migrate_saved_needs(data: Dictionary, defaults: Dictionary) -> Dictionary:
	return {
		&"care": clampf(float(data.get("care",
			data.get("fullness", defaults.get(&"care", 70.0)))), 0.0, 100.0),
		&"energy": clampf(float(data.get("energy", defaults.get(&"energy", 70.0))), 0.0, 100.0),
		&"mood": clampf(float(data.get("mood", defaults.get(&"mood", 60.0))), 0.0, 100.0),
		&"bond": clampf(float(data.get("bond",
			data.get("affection", defaults.get(&"bond", 10.0)))), 0.0, 100.0),
	}
