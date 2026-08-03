extends Node

const PET_SCENE := preload("res://pet/pet.tscn")

var _failures := 0
var _checks := 0


func _ready() -> void:
	var original_model := LLMService.get_model()
	var original_effort := LLMService.get_reasoning_effort()
	var pet := PET_SCENE.instantiate()
	add_child(pet)
	await get_tree().process_frame

	var model_menu: PopupMenu = pet.get_node("Menu/Model")
	_expect(model_menu.item_count <= 7,
		"language-model submenu is still too long (%d rows)" % model_menu.item_count)
	_expect(_menu_has_text(model_menu, "目前：%s · 推理 %s" % [
		original_model, original_effort]), "submenu does not report the live settings")
	_expect(_menu_has_text(model_menu, "更換模型與推理程度…"),
		"submenu does not expose the settings window")

	pet.call("_open_model_settings")
	await get_tree().process_frame
	var dialog: ConfirmationDialog = pet.get_node("ModelSettings")
	var model_picker: OptionButton = pet.get_node("ModelSettings/Box/Grid/Model")
	var reasoning_picker: OptionButton = pet.get_node("ModelSettings/Box/Grid/Reasoning")
	_expect(dialog.visible, "model settings dialog did not open")
	_expect(model_picker.item_count >= 7, "model picker is missing registered models")
	_expect(reasoning_picker.item_count == 6,
		"reasoning picker should keep all six levels visible")
	_expect(_picker_value(model_picker) == original_model,
		"opening the dialog did not select the live model")
	_expect(_picker_value(reasoning_picker) == original_effort,
		"opening the dialog did not select the live reasoning effort")

	_select_picker_value(model_picker, "gpt-5.5")
	model_picker.item_selected.emit(model_picker.selected)
	_expect(_picker_item_disabled(reasoning_picker, "max"),
		"max reasoning remains selectable on gpt-5.5")
	_select_picker_value(model_picker, "gpt-5.6-luna")
	model_picker.item_selected.emit(model_picker.selected)
	_expect(not _picker_item_disabled(reasoning_picker, "max"),
		"max reasoning is disabled on gpt-5.6-luna")

	dialog.hide()
	_expect(LLMService.get_model() == original_model,
		"closing the staged dialog changed the live model")
	_expect(LLMService.get_reasoning_effort() == original_effort,
		"closing the staged dialog changed the live reasoning effort")

	if _failures == 0:
		print("Model settings dialog: %d checks passed" % _checks)
	else:
		push_error("Model settings dialog: %d/%d checks failed" % [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _menu_has_text(menu: PopupMenu, wanted: String) -> bool:
	for i in menu.item_count:
		if menu.get_item_text(i) == wanted:
			return true
	return false


func _picker_value(picker: OptionButton) -> String:
	return str(picker.get_item_metadata(picker.selected))


func _select_picker_value(picker: OptionButton, wanted: String) -> void:
	for i in picker.item_count:
		if str(picker.get_item_metadata(i)) == wanted:
			picker.select(i)
			return


func _picker_item_disabled(picker: OptionButton, wanted: String) -> bool:
	for i in picker.item_count:
		if str(picker.get_item_metadata(i)) == wanted:
			return picker.is_item_disabled(i)
	return true
