extends Node

const PET_SCENE := preload("res://pet/pet.tscn")

var _failures := 0
var _checks := 0


func _ready() -> void:
	var pet := PET_SCENE.instantiate()
	add_child(pet)
	await get_tree().process_frame

	# A deliberately oversized library: the speech menu must remain a summary,
	# while the picker is allowed to contain the complete set.
	var voices := PackedStringArray()
	for i in 50:
		voices.append("角色 %02d" % (i + 1))

	var summary := PopupMenu.new()
	pet.call("_append_voice_summary", summary, voices, voices[36])
	_expect(summary.item_count == 3,
		"50 voices expanded the speech-menu summary to %d rows" % summary.item_count)
	_expect(summary.get_item_text(1) == "目前角色：角色 37",
		"summary does not report the active character")
	_expect(summary.is_item_disabled(1), "current-character status is selectable")
	_expect(summary.get_item_text(2) == "更換角色…",
		"summary is missing the change-character action")

	pet.call("_fill_voice_picker", voices, voices[36])
	var picker: OptionButton = pet.get_node("VoiceSettings/Box/Grid/Voice")
	_expect(picker.item_count == 50, "voice picker dropped entries from a large library")
	_expect(str(picker.get_item_metadata(picker.selected)) == "角色 37",
		"voice picker did not stage the active character")
	summary.free()

	if _failures == 0:
		print("Voice settings dialog: %d checks passed" % _checks)
	else:
		push_error("Voice settings dialog: %d/%d checks failed" % [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
