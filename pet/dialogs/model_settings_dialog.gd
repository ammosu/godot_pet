class_name ModelSettingsDialog
extends ConfirmationDialog

## Model and reasoning effort, staged: browsing changes nothing, and the pair
## takes effect only on 套用. Keeps the 語言模型 submenu short however long the
## registries grow.

## The choice was applied — the menu row reporting the live pair is now stale.
signal applied

@onready var _current: Label = $Box/Current
@onready var _model_picker: OptionButton = $Box/Grid/Model
@onready var _reasoning_picker: OptionButton = $Box/Grid/Reasoning
@onready var _hint: Label = $Box/Hint


## Called from pet.gd's _ready(), once the UI scale is known — not from this
## node's own _ready(), which runs before it is.
func setup(scale: float) -> void:
	exclusive = false
	theme = PetStyle.dialog_theme(scale)
	_current.custom_minimum_size = Vector2(380.0 * scale, 0)
	_current.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_current.add_theme_font_size_override("font_size", roundi(17.0 * scale))
	_hint.custom_minimum_size = Vector2(380.0 * scale, 0)
	_hint.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_hint.add_theme_font_size_override("font_size", roundi(13.0 * scale))
	_model_picker.custom_minimum_size = Vector2(250.0 * scale, 0)
	_reasoning_picker.custom_minimum_size = Vector2(250.0 * scale, 0)
	($Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(14.0 * scale))
	($Box/Grid as GridContainer).add_theme_constant_override(
		"h_separation", roundi(18.0 * scale))
	($Box/Grid as GridContainer).add_theme_constant_override(
		"v_separation", roundi(12.0 * scale))
	for label in [$Box/Grid/ModelLabel, $Box/Grid/ReasoningLabel]:
		(label as Label).add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_model_picker.get_popup().theme = PetStyle.menu_theme(scale)
	_reasoning_picker.get_popup().theme = PetStyle.menu_theme(scale)

	PetStyle.make_primary_button(get_ok_button(), scale)
	PetStyle.make_ghost_button(get_cancel_button(), scale)

	_model_picker.item_selected.connect(_on_model_selected)
	_reasoning_picker.item_selected.connect(_on_reasoning_selected)
	confirmed.connect(_apply)


func open() -> void:
	var models := LLMService.list_models()
	var efforts := LLMService.list_reasoning_efforts()
	if models.is_empty() or efforts.is_empty():
		return

	_model_picker.clear()
	var current_model := LLMService.get_model()
	var current_index := -1
	for model in models:
		_model_picker.add_item(_model_label(model))
		var index := _model_picker.item_count - 1
		_model_picker.set_item_metadata(index, str(model["id"]))
		if str(model["id"]) == current_model:
			current_index = index
	# Preserve a model entered directly in config instead of silently replacing
	# it merely because the settings window was opened.
	if current_index < 0:
		_model_picker.add_item("%s（自訂）" % current_model)
		current_index = _model_picker.item_count - 1
		_model_picker.set_item_metadata(current_index, current_model)
	_model_picker.select(current_index)

	_reasoning_picker.clear()
	for effort in efforts:
		_reasoning_picker.add_item(_reasoning_label(effort))
		var index := _reasoning_picker.item_count - 1
		_reasoning_picker.set_item_metadata(index, str(effort["id"]))
	_sync_reasoning_picker(LLMService.get_reasoning_effort())
	reset_size()
	popup_centered()


static func selected_value(picker: OptionButton) -> String:
	if picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


## The id is what matters, so it leads; the note is a parenthetical and only some
## models have one.
func _model_label(model: Dictionary) -> String:
	var note := str(model.get("note", ""))
	if note.is_empty():
		return str(model["id"])
	return "%s（%s）" % [model["id"], note]


func _reasoning_label(effort: Dictionary) -> String:
	return "%s（%s）" % [effort["label"], effort["id"]]


## Keep all six levels visible, but make the selected model's capability
## obvious. A newly incompatible choice is clamped only in the staged UI.
func _sync_reasoning_picker(preferred: String) -> void:
	var model := selected_value(_model_picker)
	var supported := LLMService.get_supported_reasoning_efforts_for_model(model)
	var effective := LLMService.effective_reasoning_effort_for_model(model, preferred)
	for i in _reasoning_picker.item_count:
		var effort_id := str(_reasoning_picker.get_item_metadata(i))
		_reasoning_picker.set_item_disabled(i, not supported.has(effort_id))
		if effort_id == effective:
			_reasoning_picker.select(i)
	_refresh_readout()


func _on_model_selected(_index: int) -> void:
	_sync_reasoning_picker(selected_value(_reasoning_picker))


func _on_reasoning_selected(_index: int) -> void:
	_refresh_readout()


func _refresh_readout() -> void:
	var model := selected_value(_model_picker)
	var effort := selected_value(_reasoning_picker)
	var changed := model != LLMService.get_model() \
		or effort != LLMService.get_reasoning_effort()
	_current.text = "%s　%s · 推理 %s" % [
		"準備改成" if changed else "現在使用", model, effort]
	var note := ""
	for entry in LLMService.list_reasoning_efforts():
		if str(entry["id"]) == effort:
			note = str(entry.get("note", ""))
			break
	_hint.text = "%s%s" % [
		note, "。按「套用」後，下一次對話就會使用新設定。" if changed else "。"]


func _apply() -> void:
	var model := selected_value(_model_picker)
	var effort := selected_value(_reasoning_picker)
	if model.is_empty() or effort.is_empty():
		return
	LLMService.select_model(model)
	LLMService.select_reasoning_effort(effort)
	applied.emit()
