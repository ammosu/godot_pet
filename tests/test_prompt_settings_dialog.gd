extends Node

const PET_SCENE := preload("res://pet/pet.tscn")

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var pet := PET_SCENE.instantiate()
	add_child(pet)
	await get_tree().process_frame

	_test_menu_entries(pet)
	_test_default_editor(pet)
	_test_current_pet_editor(pet)

	for name in ["menu", "default editor", "pet editor"]:
		if not _finished.has(name):
			_failures += 1
			push_error("Prompt settings: the '%s' test did not run to the end" % name)

	if _failures == 0:
		print("Prompt settings dialog: %d checks passed, all %d tests ran to the end"
			% [_checks, _finished.size()])
	else:
		push_error("Prompt settings dialog: %d failed, %d checks ran, %d/3 tests completed"
			% [_failures, _checks, _finished.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _test_menu_entries(pet: Node) -> void:
	var menu: PopupMenu = pet.get_node("Menu/Looks")
	_expect(_menu_has_text(menu, "編輯這個造型的個性…"),
		"looks menu has no current-pet personality editor")
	_expect(_menu_has_text(menu, "編輯預設個性…"),
		"looks menu has no default personality editor")
	_done("menu")


func _test_default_editor(pet: Node) -> void:
	pet.call("_open_prompt_settings", false)
	var dialog: ConfirmationDialog = pet.get_node("PromptSettings")
	var toggle: CheckBox = pet.get_node("PromptSettings/Box/Override")
	var editor: TextEdit = pet.get_node("PromptSettings/Box/Editor")
	_expect(dialog.visible, "default prompt dialog did not open")
	_expect(toggle.button_pressed == LLMService.has_default_persona_override(),
		"default override toggle does not reflect saved state")
	_expect(editor.editable == toggle.button_pressed,
		"inherited default prompt remains editable")
	_expect(editor.text == LLMService.get_default_persona(),
		"default editor did not show the effective default prompt")
	_expect(not editor.text.contains("## 回話格式（一定要遵守）"),
		"shared response protocol leaked into the personality editor")
	_expect(not editor.text.contains("## 看螢幕"),
		"shared screen function leaked into the personality editor")

	var draft := editor.text + "\n\n測試中的草稿，不會儲存。"
	toggle.set_pressed_no_signal(true)
	pet.call("_on_prompt_override_toggled", true)
	editor.text = draft
	pet.call("_on_prompt_text_changed")
	toggle.set_pressed_no_signal(false)
	pet.call("_on_prompt_override_toggled", false)
	_expect(not editor.editable and editor.text == LLMService.get_bundled_persona(),
		"turning off the default override did not show inherited content")
	toggle.set_pressed_no_signal(true)
	pet.call("_on_prompt_override_toggled", true)
	_expect(editor.editable and editor.text == draft,
		"turning the override back on lost the unsaved draft")
	dialog.hide()
	_done("default editor")


func _test_current_pet_editor(pet: Node) -> void:
	var pet_id := str(Config.get_value("pet", "id", LLMService.DEFAULT_PET_ID))
	if pet_id.is_empty():
		pet_id = LLMService.DEFAULT_PET_ID
	_expect(LLMService.get_active_pet_id() == pet_id,
		"loaded art and active prompt belong to different pets")
	_expect(LLMService.build_system_prompt().begins_with(
		LLMService.get_persona_for_pet(pet_id)),
		"system prompt does not start with the active pet persona")
	_expect(LLMService.build_system_prompt().contains(LLMService.get_shared_functions()),
		"system prompt omitted the functions shared by every pet")
	var declined := LLMService.build_system_prompt(false)
	_expect(not declined.contains("系統會幫你截圖，然後把同一個問題"),
		"declined screen request kept the shared look instructions")
	_expect(declined.contains("使用者剛剛拒絕了截圖"),
		"declined screen request omitted its replacement rule")

	var legacy := "自訂個性\n\n## 回話格式（一定要遵守）\n舊格式\n\n## 看螢幕\n舊功能\n\n## 界線\n舊界線"
	var migrated := str(LLMService.call("_without_legacy_function_sections", legacy))
	_expect(migrated == "自訂個性",
		"legacy full-prompt override did not migrate to personality-only content")
	legacy = "自訂個性\n\n## 回話格式（一定要遵守）\n舊格式\n\n## 看螢幕\n舊功能\n\n## 界線\n- 使用者問技術問題時可以認真回答，但仍然保持你的語氣\n- 舊功能"
	migrated = str(LLMService.call("_without_legacy_function_sections", legacy))
	_expect(migrated.contains("使用者問技術問題時可以認真回答"),
		"legacy migration discarded the personality instruction from its boundary section")

	pet.call("_open_prompt_settings", true)
	var dialog: ConfirmationDialog = pet.get_node("PromptSettings")
	var toggle: CheckBox = pet.get_node("PromptSettings/Box/Override")
	var editor: TextEdit = pet.get_node("PromptSettings/Box/Editor")
	_expect(dialog.visible, "current-pet prompt dialog did not open")
	_expect(toggle.button_pressed == LLMService.has_pet_persona_override(pet_id),
		"pet override toggle does not reflect saved state")
	_expect(editor.editable == toggle.button_pressed,
		"inherited pet prompt remains editable")
	_expect(editor.text == LLMService.get_persona_for_pet(pet_id),
		"pet editor did not show its effective prompt")
	dialog.hide()
	_done("pet editor")


func _menu_has_text(menu: PopupMenu, wanted: String) -> bool:
	for i in menu.item_count:
		if menu.get_item_text(i) == wanted:
			return true
	return false


func _done(name: String) -> void:
	_finished.append(name)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	push_error(message)
