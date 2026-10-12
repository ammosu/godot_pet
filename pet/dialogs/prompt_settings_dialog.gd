class_name PromptSettingsDialog
extends ConfirmationDialog

## One editor serves both levels of the inheritance chain:
##
##   bundled persona.md <- editable default <- current pet override
##
## Keeping inheritance explicit matters more than saving a click. Copying the
## default into every pet would make a later default edit appear to save while
## most characters quietly kept stale copies.

@onready var _current: Label = $Box/Current
@onready var _override: CheckBox = $Box/Override
@onready var _editor: TextEdit = $Box/Editor
@onready var _hint: Label = $Box/Hint

## The pet being edited, or empty for the default every un-customised pet uses.
var _target_id := ""
var _inherited_text := ""
var _draft := ""


func setup(scale: float) -> void:
	exclusive = false
	theme = PetStyle.dialog_theme(scale)
	_current.custom_minimum_size = Vector2(620.0 * scale, 0)
	_current.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_current.add_theme_font_size_override("font_size", roundi(17.0 * scale))
	_hint.custom_minimum_size = Vector2(620.0 * scale, 0)
	_hint.add_theme_color_override("font_color", PetStyle.NIGHT_MUTED)
	_hint.add_theme_font_size_override("font_size", roundi(13.0 * scale))
	_editor.custom_minimum_size = Vector2(620.0 * scale, 360.0 * scale)
	_editor.scroll_fit_content_height = false
	_editor.caret_blink = true
	_editor.caret_blink_interval = 0.6
	_editor.add_theme_font_size_override("font_size", roundi(14.0 * scale))
	_editor.add_theme_constant_override("line_spacing", roundi(4.0 * scale))
	var field_height := 38.0 * scale
	var pad_y := 10.0 * scale
	_editor.add_theme_stylebox_override("normal",
		PetStyle.input_style(scale, field_height, false, 0.0, pad_y))
	_editor.add_theme_stylebox_override("read_only",
		PetStyle.input_style(scale, field_height, false, 0.0, pad_y))
	_editor.add_theme_stylebox_override("focus",
		PetStyle.input_focus_style(scale, field_height, false, 0.0, pad_y))
	_editor.add_theme_color_override("font_color", PetStyle.INK)
	_editor.add_theme_color_override("font_readonly_color", PetStyle.INK_SOFT)
	_editor.add_theme_color_override("caret_color", PetStyle.input_caret_color(false))
	_editor.add_theme_color_override("selection_color",
		Color(PetStyle.input_caret_color(false), 0.20))
	_editor.add_theme_color_override("background_color", Color(0, 0, 0, 0))
	_editor.add_theme_color_override("current_line_color", Color(0, 0, 0, 0))
	_override.add_theme_color_override("font_color", PetStyle.NIGHT_TEXT)
	_override.add_theme_color_override("font_hover_color", PetStyle.NIGHT_TEXT)
	($Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(12.0 * scale))

	PetStyle.make_primary_button(get_ok_button(), scale)
	PetStyle.make_ghost_button(get_cancel_button(), scale)

	_override.toggled.connect(_on_override_toggled)
	_editor.text_changed.connect(_on_text_changed)
	confirmed.connect(_apply)


## `pet_id` empty edits the default; otherwise that pet's own override, shown
## under `pet_name`.
func open(pet_id: String, pet_name: String) -> void:
	_target_id = pet_id
	if not pet_id.is_empty():
		_current.text = "正在編輯：%s" % pet_name
		_override.text = "這個造型使用專屬個性與對話方式"
		_inherited_text = LLMService.get_default_persona()
		_draft = LLMService.get_persona_for_pet(pet_id)
		_override.set_pressed_no_signal(LLMService.has_pet_persona_override(pet_id))
	else:
		_current.text = "正在編輯：所有沒有專屬設定的造型"
		_override.text = "覆寫內建預設個性與對話方式"
		_inherited_text = LLMService.get_bundled_persona()
		_draft = LLMService.get_default_persona()
		_override.set_pressed_no_signal(LLMService.has_default_persona_override())

	_editor.editable = _override.button_pressed
	_editor.text = _draft if _editor.editable else _inherited_text
	_refresh()
	reset_size()
	popup_centered()
	if _editor.editable:
		_editor.call_deferred("grab_focus")


func _on_override_toggled(enabled: bool) -> void:
	if not enabled and _editor.editable:
		_draft = _editor.text
	_editor.editable = enabled
	_editor.text = _draft if enabled else _inherited_text
	_refresh()
	if enabled:
		_editor.call_deferred("grab_focus")


func _on_text_changed() -> void:
	if _editor.editable:
		_draft = _editor.text
	_refresh()


func _refresh() -> void:
	var custom := _override.button_pressed
	get_ok_button().disabled = custom and _editor.text.strip_edges().is_empty()
	var source := "內建預設" if _target_id.is_empty() else "目前的預設個性"
	_hint.text = "%s。按「套用」後，下一次對話就會生效。\n這裡只調整個性、語氣與常見對話；情緒標記、看螢幕和做事等功能規則由所有造型共用。" \
		% ["正在編輯自訂內容" if custom else "目前繼承%s；勾選後可修改" % source]


func _apply() -> void:
	var custom := _override.button_pressed
	if _target_id.is_empty():
		if custom:
			LLMService.set_default_persona(_editor.text)
		else:
			LLMService.reset_default_persona()
	elif custom:
		LLMService.set_persona_for_pet(_target_id, _editor.text)
	else:
		LLMService.reset_persona_for_pet(_target_id)
