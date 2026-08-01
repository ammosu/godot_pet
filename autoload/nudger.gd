extends Node

## Decides when the pet should say something without being asked.
##
## Lines come from a fixed pool rather than the LLM. An idle pet that calls the
## API every few minutes costs real money for no benefit, and the difference is
## invisible: what makes a nudge feel alive is the timing, not the wording. The
## model only gets involved once the user actually replies.
##
## One reason, "memory", is a template rather than a fixed line: {fact} is
## filled in from MemoryStore's durable facts at pick time, still without
## calling the model. Facts are free text a model wrote at some point, so
## _usable_facts() filters out anything that doesn't look like a short,
## unpunctuated predicate before it's allowed near a template.

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

## How long an unbroken stretch in one foreground app earns a break line.
## Long enough that it isn't just "you alt-tabbed slowly" — a Pomodoro-style
## session is the closest real-world analogue.
const FOCUS_MINUTES := 45.0

## Placeholder inside a "memory" template that gets replaced with one durable
## fact from MemoryStore. A literal token rather than e.g. String.format, so
## nudges.json stays readable without reading this file.
const FACT_SLOT := "{fact}"
## A fact this long has stopped reading as a short predicate and started
## reading as its own sentence. Facts are supposed to stay under 20 characters
## (see memory_store.gd's CONDENSE_SYSTEM prompt); this only catches the model
## overshooting that, with some slack.
const MAX_FACT_CHARS := 30
## Punctuation that means a fact is already a complete clause of its own.
## Splicing that into "你記得你{fact}耶" glues two sentences together with no
## connector, so a fact carrying any of these is skipped rather than risked.
const FACT_BREAK_CHARS := ["。", "！", "？", "…", "\n"]
## Roll the dice for a memory callback instead of the generic lonely/cheerful
## line, once the cooldown and a usable fact both allow one. Not every idle
## beat, or the same handful of facts turn into a tic.
const MEMORY_CHANCE := 0.4
## How many of the most recent picks to steer away from repeating. A pet with
## only one or two facts stored still has to be able to reuse them — see the
## fallback in _pick_memory_line().
const RECENT_FACTS_TO_AVOID := 3

var _lines := {}
var _enabled := true
var _last_nudge_at := 0.0
var _last_reason_at := {}
var _quiet_target := 0.0
## Last few facts a memory nudge used, oldest first, so the same one isn't
## picked twice running. Not persisted, same as _last_nudge_at — restarting
## the app is an acceptable place to forget which facts were recently said.
var _recent_facts: Array[String] = []


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
	# Like the needs above, and unlike lonely/cheerful below, a break
	# suggestion doesn't wait on the quiet-since-last-chat gate — whether the
	# pet talked to you ten minutes ago has nothing to do with whether you
	# need to get up.
	if _available("focus") and _long_unbroken_focus():
		return "focus"
	if PetState.minutes_since_talk() < _quiet_target:
		return ""
	# A flavour of the idle lonely/cheerful beat, not a separate urgency tier —
	# gated the same way (cooldown, quiet period) and only taken part of the
	# time so a remembered fact doesn't crowd out the plain lines.
	if _available("memory") and randf() < MEMORY_CHANCE and not _usable_facts().is_empty():
		return "memory"
	var cheerful := PetState.get_need(&"mood") >= CHEERFUL_ABOVE
	var reason := "cheerful" if cheerful else "lonely"
	return reason if _available(reason) else ""


## PresenceService reports -1.0 when it has nothing to say — not consented,
## not supported, or no sample has landed yet — which this treats the same
## as "not focused long enough" rather than special-casing it.
func _long_unbroken_focus() -> bool:
	return PresenceService.seconds_in_current_app() >= FOCUS_MINUTES * 60.0


func _available(reason: String) -> bool:
	return _minutes_since(float(_last_reason_at.get(reason, 0.0))) >= REASON_COOLDOWN_MINUTES


func _pick_line(reason: String) -> Dictionary:
	if reason == "memory":
		return _pick_memory_line()
	var pool: Array = _lines.get(reason, [])
	if pool.is_empty():
		return {}
	var line: Variant = pool[randi() % pool.size()]
	return line if typeof(line) == TYPE_DICTIONARY else {}


## Fill a "memory" template with one durable fact and remember which one was
## used, so the next pick can steer away from it. Split from _pick_line()
## because this reason needs a fact substituted in, not just a line picked
## verbatim.
func _pick_memory_line() -> Dictionary:
	var pool: Array = _lines.get("memory", [])
	if pool.is_empty():
		return {}
	var facts := _usable_facts()
	if facts.is_empty():
		return {}

	var candidates: Array[String] = []
	for fact in facts:
		if not _recent_facts.has(fact):
			candidates.append(fact)
	if candidates.is_empty():
		candidates = facts  # everything usable was said recently — repeat beats silence

	var fact: String = candidates[randi() % candidates.size()]

	var line: Variant = pool[randi() % pool.size()]
	if typeof(line) != TYPE_DICTIONARY:
		return {}
	var template := str(line.get("text", ""))
	if not template.contains(FACT_SLOT):
		return {}

	# Only now, once the line is certain to be said. Marking it above would let a
	# hand-edited entry with no {fact} slot burn a fact out of the rotation while
	# emitting nothing — and the validation above exists precisely because this
	# file is meant to be edited without touching code.
	_recent_facts.append(fact)
	while _recent_facts.size() > RECENT_FACTS_TO_AVOID:
		_recent_facts.pop_front()
	return {"emotion": line.get("emotion", "neutral"), "text": template.replace(FACT_SLOT, fact)}


## Facts are free text a model wrote (MemoryStore.facts(), owned there — this
## reads it fresh each time rather than keeping a copy), not something this
## template engine controls, so anything that doesn't look like a short
## dropped-in predicate is skipped rather than risking a malformed line.
func _usable_facts() -> Array[String]:
	var out: Array[String] = []
	for fact in MemoryStore.facts():
		var text := fact.strip_edges()
		if text.is_empty() or text.length() > MAX_FACT_CHARS:
			continue
		var breaks_template := false
		for ch in FACT_BREAK_CHARS:
			if text.contains(ch):
				breaks_template = true
				break
		if not breaks_template:
			out.append(text)
	return out


func _reroll_quiet_target() -> void:
	_quiet_target = randf_range(QUIET_MINUTES.x, QUIET_MINUTES.y)


func _minutes_since(unix_time: float) -> float:
	return (Time.get_unix_time_from_system() - unix_time) / 60.0


## Every line the pet can say unprompted whose wording is fixed, for pre-rendering.
##
## The `memory` pool is left out on purpose: those are `{fact}` templates filled
## at pick time, so the string here is not one anybody ever hears. Anything else
## carrying a brace is skipped for the same reason rather than by pool name — a
## template added to another pool would otherwise be cached with its brace intact
## and then played instead of the filled version, which is the one failure a
## cache of fixed lines must not have.
func fixed_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	for name in _lines:
		var pool: Variant = _lines[name]
		if str(name).begins_with("_") or typeof(pool) != TYPE_ARRAY:
			continue
		for entry: Variant in pool:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var text := str((entry as Dictionary).get("text", "")).strip_edges()
			if not text.is_empty() and not text.contains("{"):
				lines.append(text)
	return lines


func _load_lines() -> Dictionary:
	var raw := FileAccess.get_file_as_string(LINES_PATH)
	var data: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("Nudger: cannot read %s, the pet will never speak up on its own" % LINES_PATH)
		return {}
	return data
