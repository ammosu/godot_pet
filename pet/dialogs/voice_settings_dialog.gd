class_name VoiceSettingsDialog
extends ConfirmationDialog

## Voice characters follow the model dialog's staged interaction: opening and
## browsing changes nothing, and the selected character takes effect only after
## 套用. The picker can grow and scroll without making the speech menu taller.

@onready var _current: Label = $Box/Current
@onready var _picker: OptionButton = $Box/Grid/Voice


func setup(scale: float) -> void:
	exclusive = false
	theme = PetStyle.dialog_theme(scale)
	_current.custom_minimum_size = Vector2(340.0 * scale, 0)
	_current.add_theme_color_override("font_color", PetStyle.ACCENT_TEXT)
	_current.add_theme_font_size_override("font_size", roundi(17.0 * scale))
	_picker.custom_minimum_size = Vector2(250.0 * scale, 0)
	($Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(14.0 * scale))
	($Box/Grid as GridContainer).add_theme_constant_override(
		"h_separation", roundi(18.0 * scale))
	($Box/Grid/VoiceLabel as Label).add_theme_color_override(
		"font_color", PetStyle.NIGHT_MUTED)
	_picker.get_popup().theme = PetStyle.menu_theme(scale)

	PetStyle.make_primary_button(get_ok_button(), scale)
	PetStyle.make_ghost_button(get_cancel_button(), scale)

	_picker.item_selected.connect(func(_index: int) -> void: _refresh_readout())
	confirmed.connect(_apply)


func open() -> void:
	var voices := TTSService.list_voices()
	if voices.is_empty():
		return
	fill(voices, TTSService.active_voice())
	reset_size()
	popup_centered()


## Separate from opening the window so a large synthetic library can exercise
## the scaling behaviour without depending on voices installed on the machine.
func fill(voices: PackedStringArray, active: String) -> void:
	_picker.clear()
	var selected := 0
	for i in voices.size():
		_picker.add_item(voices[i])
		_picker.set_item_metadata(i, voices[i])
		if voices[i] == active:
			selected = i
	if not voices.is_empty():
		_picker.select(selected)
	_refresh_readout()


func _refresh_readout() -> void:
	var selected := ModelSettingsDialog.selected_value(_picker)
	var changed := not selected.is_empty() and selected != TTSService.active_voice()
	_current.text = "%s　%s" % ["準備改成" if changed else "現在使用", selected]


## No signal of its own: select_voice() emits TTSService.voice_changed, which
## pet.gd already rebuilds the menu on.
func _apply() -> void:
	var voice := ModelSettingsDialog.selected_value(_picker)
	if not voice.is_empty():
		TTSService.select_voice(voice)
