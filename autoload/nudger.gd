extends Node

## Decides when the pet should say something without being asked.
##
## Lines come from a fixed pool rather than the LLM. An idle pet that calls the
## API every few minutes costs real money for no benefit, and the difference is
## invisible: what makes a nudge feel alive is the timing, not the wording. The
## model only gets involved once the user actually replies.

const LINES_PATH := "res://prompts/nudges.json"
const CHECK_INTERVAL := 20.0

## Nothing unprompted more often than this, whatever the reason.
const COOLDOWN_MINUTES := 8.0
## And don't repeat the same complaint within this.
const REASON_COOLDOWN_MINUTES := 35.0
## How long the user has to be quiet before the pet pipes up. Randomised so it
## doesn't feel like a cron job.
const QUIET_MINUTES := Vector2(12.0, 25.0)

const HUNGRY_BELOW := 25.0
const TIRED_BELOW := 22.0
const CHEERFUL_ABOVE := 60.0

var _lines := {}
var _enabled := true
var _last_nudge_at := 0.0
var _last_reason_at := {}
var _quiet_target := 0.0


func _ready() -> void:
	_lines = _load_lines()
	_enabled = bool(Config.get_value("pet", "nudges", true))
	_last_nudge_at = Time.get_unix_time_from_system()
	_reroll_quiet_target()

	var timer := Timer.new()
	timer.wait_time = CHECK_INTERVAL
	timer.timeout.connect(_check)
	add_child(timer)
	timer.start()


func is_enabled() -> bool:
	return _enabled


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	Config.set_value("pet", "nudges", enabled)
	if enabled:
		_last_nudge_at = Time.get_unix_time_from_system()
		_reroll_quiet_target()


func _check() -> void:
	if not _enabled or LLMService.is_busy():
		return
	if _minutes_since(_last_nudge_at) < COOLDOWN_MINUTES:
		return

	var reason := _pick_reason()
	if reason.is_empty():
		return
	var line := _pick_line(reason)
	if line.is_empty():
		return

	_last_nudge_at = Time.get_unix_time_from_system()
	_last_reason_at[reason] = _last_nudge_at
	_reroll_quiet_target()
	EventBus.pet_nudged.emit(str(line.get("emotion", "neutral")), str(line.get("text", "")))


## Needs first — being hungry is more urgent than being bored.
func _pick_reason() -> String:
	if _available("hungry") and PetState.get_need(&"fullness") < HUNGRY_BELOW:
		return "hungry"
	if _available("tired") and PetState.get_need(&"energy") < TIRED_BELOW:
		return "tired"
	if PetState.minutes_since_talk() < _quiet_target:
		return ""
	var cheerful := PetState.get_need(&"mood") >= CHEERFUL_ABOVE
	var reason := "cheerful" if cheerful else "lonely"
	return reason if _available(reason) else ""


func _available(reason: String) -> bool:
	return _minutes_since(float(_last_reason_at.get(reason, 0.0))) >= REASON_COOLDOWN_MINUTES


func _pick_line(reason: String) -> Dictionary:
	var pool: Array = _lines.get(reason, [])
	if pool.is_empty():
		return {}
	var line: Variant = pool[randi() % pool.size()]
	return line if typeof(line) == TYPE_DICTIONARY else {}


func _reroll_quiet_target() -> void:
	_quiet_target = randf_range(QUIET_MINUTES.x, QUIET_MINUTES.y)


func _minutes_since(unix_time: float) -> float:
	return (Time.get_unix_time_from_system() - unix_time) / 60.0


func _load_lines() -> Dictionary:
	var raw := FileAccess.get_file_as_string(LINES_PATH)
	var data: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("Nudger: cannot read %s, the pet will never speak up on its own" % LINES_PATH)
		return {}
	return data
