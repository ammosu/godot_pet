class_name EntryDialog
extends ConfirmationDialog

## Collect one setting in its own window.
##
## **Not in the speech bubble, which is where all of this used to happen.** Three
## reasons, in the order they matter: a key typed into the pet's own input is
## being typed into the *transparent, click-through* window, behind a passthrough
## mask that has to be kept in step with whatever the field is doing — the one
## surface in this app with a rule about not eating desktop clicks. It is also
## conversation-shaped, and pasting a credential is not something you say to a
## pet. And a bubble fades on a timer, so a dialog that asks a question the user
## has to go and find the answer to could time out mid-paste.
##
## A `ConfirmationDialog` like every other question here, so it is a real OS
## window (subwindow embedding is off project-wide) and touches no mask at all.
##
## One window for every setting of this shape, differing only in title, blurb
## and masking; several near-identical dialogs would be several places for a
## button style to drift.

## `what` is whatever `ask()` was given — a `Config` secret name, or a setting id.
signal submitted(what: String, value: String)

@onready var _field: LineEdit = $Box/Field
## The explanation, as a label of our own rather than `dialog_text`.
## **`AcceptDialog` gives every Control child the same content rect**, so the
## built-in label and the field were drawn on top of each other — measured on
## screen, the blurb struck through the middle of the text being typed. One child
## is the only arrangement that lays out, so both live in a VBox.
@onready var _blurb: Label = $Box/Blurb

var _what := ""


## `register_text_enter` is what makes Enter save, which is what everyone will
## try first — a settings field that only accepts a mouse click on 儲存 reads as
## broken to anyone who has ever used a password box.
func setup(scale: float) -> void:
	exclusive = false
	theme = PetStyle.dialog_theme(scale)
	# The primary treatment, not the ghost one: saving is the whole reason this
	# window opened, and ghosting it makes the main action look disabled — the
	# mistake ChatLogPanel's 關閉 button and the Codex login dialog both record.
	PetStyle.make_primary_button(get_ok_button(), scale)
	PetStyle.make_ghost_button(get_cancel_button(), scale)
	_blurb.custom_minimum_size = Vector2(300.0 * scale, 0)
	_blurb.add_theme_font_size_override("font_size", roundi(13.0 * scale))
	_field.custom_minimum_size = Vector2(300.0 * scale, 0)
	($Box as VBoxContainer).add_theme_constant_override(
		"separation", roundi(10.0 * scale))
	register_text_enter(_field)
	confirmed.connect(_on_confirmed)
	# Not left to sit in the field: a cancelled paste is still a credential in a
	# node that stays alive for the life of the app.
	canceled.connect(func() -> void: _field.text = "")


func ask(what: String, heading: String, blurb: String, masked: bool,
		current := "") -> void:
	_what = what
	title = heading
	_blurb.text = blurb
	_field.secret = masked
	_field.text = current
	_field.caret_column = current.length()
	reset_size()
	popup_centered()
	_field.grab_focus()


func _on_confirmed() -> void:
	var value := _field.text.strip_edges()
	# Cleared straight away rather than on close: the field is one node reused by
	# every setting, and a key left sitting in it is a key the next one opens
	# showing — in plain text, if that one happens to be the address.
	_field.text = ""
	if not value.is_empty():
		submitted.emit(_what, value)
