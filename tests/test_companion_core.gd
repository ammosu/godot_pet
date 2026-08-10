extends Node

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"builtin profile": _test_builtin_profile,
		"fallback profile": _test_fallback_profile,
		"untrusted profile fallback": _test_untrusted_profile_fallback,
		"legacy state migration": _test_legacy_state_migration,
		"transcription multipart": _test_transcription_multipart,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("CompanionCore: '%s' did not reach its last line" % name)
	if _failures == 0:
		print("Companion core: %d checks passed, all %d tests completed"
			% [_checks, tests.size()])
	else:
		push_error("Companion core: %d failures across %d checks" % [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _test_builtin_profile() -> void:
	var before := PetState.snapshot()
	CompanionProfile.apply_pack(PetPack.load_builtin())
	_expect(CompanionProfile.self_name() == "芽尾", "built-in sidecar did not load")
	_expect(CompanionProfile.care_action_label() == "餵食", "built-in care verb drifted")
	_expect(CompanionProfile.state_label(&"bond") == "羈絆", "bond did not use neutral copy")
	_expect(CompanionProfile.bond_stage(55.0)["label"] == "信任", "bond stage threshold is wrong")
	_expect(not CompanionProfile.ambient_behaviours().is_empty(), "built-in ambient list is empty")
	_expect(PetState.snapshot() == before, "switching a form reset the shared companion state")
	_done("builtin profile")


func _test_fallback_profile() -> void:
	CompanionProfile.apply_pack(null)
	_expect(CompanionProfile.self_name() == "小夥伴", "missing sidecar did not use generic identity")
	_expect(CompanionProfile.care_enabled(), "compatible packs unexpectedly lost their care action")
	_expect(CompanionProfile.care_action_label() == "餵食", "legacy pack fallback changed behaviour")
	CompanionProfile.apply_pack(PetPack.load_builtin())
	_done("fallback profile")


func _test_untrusted_profile_fallback() -> void:
	var dir := "user://companion-profile-test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir.path_join(CompanionProfile.FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"schemaVersion": 1,
		"selfName": ["wrong type"],
		"care": ["wrong type"],
		"nudgesPath": "../../outside.json",
	}))
	file.close()
	var pack := PetPack.new()
	pack.base_dir = dir
	pack.id = "untrusted-test"
	pack.display_name = "安全造型"
	CompanionProfile.apply_pack(pack)
	_expect(CompanionProfile.self_name() == "安全造型",
		"wrong-typed external selfName replaced the pack name")
	_expect(CompanionProfile.care_enabled(), "wrong-typed care block disabled fallback care")
	_expect(CompanionProfile.care_action_label() == "餵食",
		"wrong-typed care block replaced the fallback action")
	_expect(not CompanionProfile.nudge_lines().is_empty(),
		"path traversal did not fall back to built-in nudge lines")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	CompanionProfile.apply_pack(PetPack.load_builtin())
	_done("untrusted profile fallback")


func _test_legacy_state_migration() -> void:
	var defaults := {&"care": 70.0, &"energy": 70.0, &"mood": 60.0, &"bond": 10.0}
	var old := {"fullness": 23.0, "energy": 44.0, "mood": 55.0, "affection": 66.0}
	var migrated := PetState.migrate_saved_needs(old, defaults)
	_expect(migrated[&"care"] == 23.0, "fullness was not migrated to care")
	_expect(migrated[&"bond"] == 66.0, "affection was not migrated to bond")
	var mixed := old.duplicate()
	mixed["care"] = 81.0
	mixed["bond"] = 82.0
	migrated = PetState.migrate_saved_needs(mixed, defaults)
	_expect(migrated[&"care"] == 81.0, "new care value did not win over legacy fullness")
	_expect(migrated[&"bond"] == 82.0, "new bond value did not win over legacy affection")
	_done("legacy state migration")


func _test_transcription_multipart() -> void:
	var wav := "RIFFtest-wave".to_utf8_buffer()
	var boundary := "boundary-test"
	var body := SpeechInputService.multipart_body(wav, boundary)
	var text := body.get_string_from_utf8()
	_expect(text.contains("name=\"model\""), "multipart body has no model field")
	_expect(text.contains(SpeechInputService.MODEL), "multipart body has the wrong model")
	_expect(text.contains("name=\"language\""), "multipart body has no language hint")
	_expect(text.contains("filename=\"speech.wav\""), "multipart body has no WAV file part")
	_expect(text.contains("RIFFtest-wave"), "multipart body dropped the WAV bytes")
	_expect(text.ends_with("--%s--\r\n" % boundary), "multipart body has no closing boundary")
	_done("transcription multipart")
