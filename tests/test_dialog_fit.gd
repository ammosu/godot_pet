extends Node

## A question dialog opened by PetStyle.popup_fitted() is as tall as its text and
## as wide as the width it was given — no blank band under the text, no
## two-button warning shrunk to a column. Measured against the screen-look
## consent's shape, the one whose text changes per open and which came up 104px
## too tall before this.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"height follows the text": _test_height_follows_text,
		"width follows the given width": _test_width_follows_given,
	}
	for name: String in tests:
		await (tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("DialogFit: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("DialogFit: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("DialogFit: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _dialog(text: String, width: float) -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	dialog.exclusive = false
	dialog.theme = PetStyle.dialog_theme(1.0)
	add_child(dialog)
	PetStyle.fit_dialog_text(dialog, width, 1.0)
	dialog.dialog_text = text
	return dialog


## Opened twice with different text, the way the consent is: once short, then
## with a long question in front. Each time the dialog must end up exactly as
## tall as what is in it.
func _test_height_follows_text() -> void:
	var dialog := _dialog("要回答這個，我得把整個螢幕拍成一張圖。", PetStyle.DIALOG_TEXT_WIDTH)
	for text in ["要回答這個，我得把整個螢幕拍成一張圖。\n\n・只有這一次",
			"你剛剛問：「看一下我在幹嘛，這個錯誤訊息是什麼意思」\n\n要回答這個，我得把整個螢幕拍成一張圖，傳給 OpenAI 讀。\n\n・只有這一次，我不會在背景一直看\n・看到的內容不會寫進我的長期記憶\n・拍的那一瞬間，我會先把自己藏起來"]:
		dialog.dialog_text = text
		await PetStyle.popup_fitted(dialog)
		var wanted := dialog.get_contents_minimum_size().y
		_expect(absf(dialog.size.y - wanted) <= 2.0,
			"dialog is %dpx tall for %dpx of content" % [dialog.size.y, wanted])
		dialog.hide()
		await get_tree().process_frame
	dialog.queue_free()
	_done("height follows the text")


func _test_width_follows_given() -> void:
	var dialog := _dialog("「proj」裡有 3 個檔案改了還沒 commit。\n\n我等一下會直接改這個資料夾裡的檔案。萬一改壞了，已經 commit 的東西 git 救得回來，這 3 個救不回來。",
		PetStyle.DIALOG_TEXT_WIDTH)
	await PetStyle.popup_fitted(dialog)
	_expect(dialog.size.x >= PetStyle.DIALOG_TEXT_WIDTH,
		"a two-button dialog shrank to %dpx, under its %dpx text width"
			% [dialog.size.x, PetStyle.DIALOG_TEXT_WIDTH])
	dialog.queue_free()
	_done("width follows the given width")
