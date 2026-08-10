extends Node

## The role-specific half of the desktop companion.
##
## Sprite packs keep the public Codex Pets `pet.json` format untouched. A pack
## may add a project-owned `companion.json` beside it to describe how that form
## talks about its condition, what its main care action is, and which ambient
## animations suit it. Packs without the sidecar retain the original pet
## behaviour, so every existing community pack remains compatible.

signal changed

const FILE_NAME := "companion.json"
const DEFAULT_NUDGES_PATH := "res://prompts/nudges.json"
const MAX_PROFILE_BYTES := 64 * 1024
const MAX_NUDGES_BYTES := 128 * 1024
const MAX_TEXT_CHARS := 240
const MAX_NUDGE_POOLS := 16
const MAX_LINES_PER_POOL := 24

const DEFAULT_PROFILE := {
	"schemaVersion": 1,
	"selfName": "小夥伴",
	"nudgesPath": "",
	"states": {
		"energy": {
			"label": "精力",
			"grades": ["快睡著了", "有點累", "還行", "精神很好"],
		},
		"mood": {
			"label": "心情",
			"grades": ["很低落", "有點悶", "普通", "很好"],
		},
		"bond": {
			"label": "羈絆",
			"grades": ["初識", "熟悉", "信任", "默契"],
		},
	},
	"care": {
		"enabled": true,
		"label": "飽足",
		"grades": ["很餓，可以抱怨一下", "有點餓", "還好", "很飽"],
		"actionLabel": "餵食",
		"starting": 70.0,
		"decayPerMinute": 0.12,
		"amount": 35.0,
		"moodAmount": 4.0,
		"gameTreatAmount": 0.6,
		"gameTreatCap": 10.0,
		"replies": [
			{"emotion": "happy", "text": "謝謝！這個好吃。"},
		],
	},
	"bondStages": [
		{"minimum": 0.0, "label": "初識"},
		{"minimum": 25.0, "label": "熟悉", "emotion": "happy",
			"line": "我好像越來越習慣有你在旁邊了。"},
		{"minimum": 50.0, "label": "信任", "emotion": "happy",
			"line": "有些事不用說完，我好像也開始懂了。"},
		{"minimum": 75.0, "label": "默契", "emotion": "excited",
			"line": "我們現在是不是很有默契？"},
	],
	"returnGreeting": {
		"minimumMinutes": 60.0,
		"emotion": "greeting",
		"lines": ["你回來啦。", "嗨，好一陣子沒看到你了。"],
	},
	"ambientBehaviours": [
		{"state": "wave", "minimumBond": 25.0, "weight": 1.0, "duration": 2.2},
		{"state": "happy", "minimumBond": 50.0, "weight": 0.7, "duration": 2.0},
	],
}

var _profile: Dictionary = DEFAULT_PROFILE.duplicate(true)
var _pack_dir := ""
var _pet_id := ""


func _ready() -> void:
	# Autoload order puts this before PetState, so select the saved form here.
	# PetState can then catch up offline time using the correct role semantics
	# instead of briefly assuming every companion needs food.
	var selected := str(Config.get_value("pet", "id", "__default__"))
	var pack := PetPack.load_builtin() if selected.is_empty() or selected == "__default__" \
		else PetPack.load_installed(selected)
	if pack == null and selected != "__default__":
		pack = PetPack.load_builtin()
	apply_pack(pack)


## Apply the role sidecar belonging to `pack`. A null pack is the emergency
## visual and uses the same safe default behaviour as a pack with no sidecar.
func apply_pack(pack: PetPack) -> void:
	_profile = DEFAULT_PROFILE.duplicate(true)
	_pack_dir = ""
	_pet_id = ""
	var fallback_name := str(DEFAULT_PROFILE["selfName"])
	if pack != null:
		_pack_dir = pack.base_dir
		_pet_id = pack.id
		fallback_name = pack.display_name
		_profile["selfName"] = fallback_name
		var path := _pack_dir.path_join(FILE_NAME)
		var raw := _read_bounded(path, MAX_PROFILE_BYTES)
		if not raw.is_empty():
			var parsed: Variant = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_DICTIONARY:
				_merge_known(_profile, parsed)
			else:
				push_warning("CompanionProfile: malformed %s; using defaults" % path)
	_validate(fallback_name)
	_load_nudges(_nudge_path())
	changed.emit()


func pet_id() -> String:
	return _pet_id


func self_name() -> String:
	return str(_profile.get("selfName", DEFAULT_PROFILE["selfName"]))


func care_enabled() -> bool:
	return bool(_care().get("enabled", true))


func care_label() -> String:
	return str(_care().get("label", "飽足"))


func care_action_label() -> String:
	return str(_care().get("actionLabel", "照顧"))


func care_amount() -> float:
	return float(_care().get("amount", 0.0))


func care_mood_amount() -> float:
	return float(_care().get("moodAmount", 0.0))


func care_starting() -> float:
	return float(_care().get("starting", 70.0))


func care_decay_per_minute() -> float:
	return float(_care().get("decayPerMinute", 0.0)) if care_enabled() else 0.0


func game_treat_amount() -> float:
	return float(_care().get("gameTreatAmount", 0.0)) if care_enabled() else 0.0


func game_treat_cap() -> float:
	return float(_care().get("gameTreatCap", 0.0)) if care_enabled() else 0.0


func care_reply() -> Dictionary:
	var replies: Array = _care().get("replies", [])
	if replies.is_empty():
		return {"emotion": "happy", "text": "謝謝你陪我。"}
	var picked: Variant = replies[randi() % replies.size()]
	return picked.duplicate(true) if typeof(picked) == TYPE_DICTIONARY \
		else {"emotion": "happy", "text": str(picked)}


func state_label(state: StringName) -> String:
	if state == &"care":
		return care_label()
	var states: Dictionary = _profile.get("states", {})
	var entry: Dictionary = states.get(str(state), {})
	return str(entry.get("label", str(state)))


func grade(state: StringName, value: float) -> String:
	var grades: Array
	if state == &"care":
		grades = _care().get("grades", [])
	else:
		var states: Dictionary = _profile.get("states", {})
		var entry: Dictionary = states.get(str(state), {})
		grades = entry.get("grades", [])
	if grades.size() != 4:
		return "普通"
	if value < 20.0:
		return str(grades[0])
	if value < 40.0:
		return str(grades[1])
	if value < 70.0:
		return str(grades[2])
	return str(grades[3])


func bond_stage(value: float) -> Dictionary:
	var stages: Array = _profile.get("bondStages", [])
	var current: Dictionary = {"minimum": 0.0, "label": grade(&"bond", value)}
	for candidate: Variant in stages:
		if typeof(candidate) != TYPE_DICTIONARY:
			continue
		if value >= float(candidate.get("minimum", 0.0)):
			current = candidate
		else:
			break
	return current.duplicate(true)


func bond_stage_index(value: float) -> int:
	var stages: Array = _profile.get("bondStages", [])
	var index := 0
	for i in stages.size():
		var candidate: Variant = stages[i]
		if typeof(candidate) == TYPE_DICTIONARY \
				and value >= float(candidate.get("minimum", 0.0)):
			index = i
		else:
			break
	return index


func ambient_behaviours() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Variant in _profile.get("ambientBehaviours", []):
		if typeof(entry) == TYPE_DICTIONARY:
			out.append((entry as Dictionary).duplicate(true))
	return out


func return_greeting(minutes_away: float) -> Dictionary:
	var greeting: Dictionary = _profile.get("returnGreeting", {})
	if minutes_away < float(greeting.get("minimumMinutes", INF)):
		return {}
	var lines: Array = greeting.get("lines", [])
	if lines.is_empty():
		return {}
	return {
		"emotion": str(greeting.get("emotion", "greeting")),
		"text": str(lines[randi() % lines.size()]),
	}


func nudge_lines() -> Dictionary:
	return (_profile.get("_nudgeLines", {}) as Dictionary).duplicate(true)


func _care() -> Dictionary:
	return _profile.get("care", {})


## Merge only keys already declared by the defaults. This keeps a typo from
## silently becoming live configuration and leaves room to add schema versions
## deliberately later.
func _merge_known(target: Dictionary, incoming: Dictionary) -> void:
	for key: Variant in incoming:
		if not target.has(key):
			continue
		var before: Variant = target[key]
		var after: Variant = incoming[key]
		if typeof(before) == TYPE_DICTIONARY and typeof(after) == TYPE_DICTIONARY:
			_merge_known(before, after)
		elif _compatible_type(before, after):
			target[key] = after


func _compatible_type(before: Variant, after: Variant) -> bool:
	var expected := typeof(before)
	var received := typeof(after)
	if expected == TYPE_INT or expected == TYPE_FLOAT:
		return received == TYPE_INT or received == TYPE_FLOAT
	return expected == received


func _validate(fallback_name: String) -> void:
	var version := int(_profile.get("schemaVersion", 0))
	if version != 1:
		push_warning("CompanionProfile: unsupported schemaVersion %d; using defaults" % version)
		_profile = DEFAULT_PROFILE.duplicate(true)
		_profile["selfName"] = fallback_name
		return
	_profile["selfName"] = _bounded_text(str(_profile.get("selfName", fallback_name)),
		fallback_name, 40)
	_profile["nudgesPath"] = _bounded_text(str(_profile.get("nudgesPath", "")), "", 240)
	var states: Dictionary = _profile.get("states", {})
	var default_states: Dictionary = DEFAULT_PROFILE["states"]
	for state: String in states:
		_validate_state_entry(states[state], default_states[state])
	var care := _care()
	_validate_state_entry(care, DEFAULT_PROFILE["care"])
	care["actionLabel"] = _bounded_text(str(care.get("actionLabel", "照顧")), "照顧", 40)
	care["amount"] = clampf(float(care.get("amount", 0.0)), 0.0, 100.0)
	care["moodAmount"] = clampf(float(care.get("moodAmount", 0.0)), -100.0, 100.0)
	care["starting"] = clampf(float(care.get("starting", 70.0)), 0.0, 100.0)
	care["decayPerMinute"] = clampf(float(care.get("decayPerMinute", 0.0)), 0.0, 10.0)
	care["gameTreatAmount"] = clampf(float(care.get("gameTreatAmount", 0.0)), 0.0, 100.0)
	care["gameTreatCap"] = clampf(float(care.get("gameTreatCap", 0.0)), 0.0, 100.0)
	care["replies"] = _sanitise_lines(care.get("replies", []), 8)
	_profile["bondStages"] = _sanitise_bond_stages(_profile.get("bondStages", []))
	var greeting: Dictionary = _profile.get("returnGreeting", {})
	greeting["minimumMinutes"] = clampf(float(greeting.get("minimumMinutes", 60.0)), 0.0,
		365.0 * 24.0 * 60.0)
	greeting["emotion"] = _bounded_text(str(greeting.get("emotion", "greeting")), "greeting", 32)
	var greeting_lines: Array = []
	for line: Variant in greeting.get("lines", []):
		if greeting_lines.size() >= 8:
			break
		var text := _bounded_text(str(line), "", MAX_TEXT_CHARS)
		if not text.is_empty():
			greeting_lines.append(text)
	greeting["lines"] = greeting_lines
	_profile["ambientBehaviours"] = _sanitise_ambient(_profile.get("ambientBehaviours", []))


func _validate_state_entry(entry: Dictionary, fallback: Dictionary) -> void:
	entry["label"] = _bounded_text(str(entry.get("label", fallback.get("label", "狀態"))),
		str(fallback.get("label", "狀態")), 40)
	var grades: Array = entry.get("grades", [])
	if grades.size() != 4:
		entry["grades"] = (fallback.get("grades", ["低", "稍低", "普通", "很好"]) as Array).duplicate()
		return
	var clean: Array = []
	var defaults: Array = fallback.get("grades", [])
	for i in 4:
		clean.append(_bounded_text(str(grades[i]), str(defaults[i]), 80))
	entry["grades"] = clean


func _sanitise_lines(raw: Variant, limit: int) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item: Variant in raw:
		if out.size() >= limit:
			break
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var text := _bounded_text(str(item.get("text", "")), "", MAX_TEXT_CHARS)
		if text.is_empty():
			continue
		out.append({
			"emotion": _bounded_text(str(item.get("emotion", "neutral")), "neutral", 32),
			"text": text,
		})
	return out


func _sanitise_bond_stages(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) == TYPE_ARRAY:
		for item: Variant in raw:
			if out.size() >= 8:
				break
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var stage := {
				"minimum": clampf(float(item.get("minimum", 0.0)), 0.0, 100.0),
				"label": _bounded_text(str(item.get("label", "熟悉")), "熟悉", 40),
			}
			var line := _bounded_text(str(item.get("line", "")), "", MAX_TEXT_CHARS)
			if not line.is_empty():
				stage["emotion"] = _bounded_text(str(item.get("emotion", "happy")), "happy", 32)
				stage["line"] = line
			out.append(stage)
	if out.is_empty():
		return (DEFAULT_PROFILE["bondStages"] as Array).duplicate(true)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["minimum"]) < float(b["minimum"]))
	return out


func _sanitise_ambient(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item: Variant in raw:
		if out.size() >= 16:
			break
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var state := _bounded_text(str(item.get("state", "")), "", 32)
		if state.is_empty():
			continue
		out.append({
			"state": state,
			"minimumBond": clampf(float(item.get("minimumBond", 0.0)), 0.0, 100.0),
			"weight": clampf(float(item.get("weight", 1.0)), 0.0, 100.0),
			"duration": clampf(float(item.get("duration", 2.0)), 0.4, 10.0),
		})
	return out


func _bounded_text(value: String, fallback: String, limit: int) -> String:
	var clean := value.strip_edges()
	if clean.is_empty():
		clean = fallback
	return clean.left(limit)


func _nudge_path() -> String:
	var path := _sidecar_path("nudgesPath")
	return DEFAULT_NUDGES_PATH if path.is_empty() else path


func _sidecar_path(field: String) -> String:
	var relative := str(_profile.get(field, "")).replace("\\", "/").strip_edges()
	if relative.is_empty():
		return ""
	# A role file can select a sibling file, never turn a visual pack into an
	# arbitrary file reader.
	if _pack_dir.is_empty() or relative.is_absolute_path() or relative.contains(".."):
		push_warning("CompanionProfile: refusing %s outside the pack" % field)
		return ""
	return _pack_dir.path_join(relative)


func _load_nudges(path: String) -> void:
	var raw := _read_bounded(path, MAX_NUDGES_BYTES)
	var parsed: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if typeof(parsed) != TYPE_DICTIONARY:
		if path != DEFAULT_NUDGES_PATH:
			push_warning("CompanionProfile: cannot read %s; using default nudges" % path)
			_load_nudges(DEFAULT_NUDGES_PATH)
			return
	_profile["_nudgeLines"] = _sanitise_nudges(parsed)


func _sanitise_nudges(raw: Dictionary) -> Dictionary:
	var out := {}
	for pool_name: Variant in raw:
		if out.size() >= MAX_NUDGE_POOLS:
			break
		var source: Variant = raw[pool_name]
		if typeof(source) != TYPE_ARRAY:
			continue
		var lines := _sanitise_lines(source, MAX_LINES_PER_POOL)
		if not lines.is_empty():
			out[_bounded_text(str(pool_name), "", 40)] = lines
	return out


func _read_bounded(path: String, maximum: int) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	if file.get_length() > maximum:
		push_warning("CompanionProfile: refusing oversized %s" % path)
		return ""
	return file.get_as_text()
