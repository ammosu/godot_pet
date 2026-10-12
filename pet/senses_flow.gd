class_name SensesFlow
extends Node

## The three things the pet can watch, and the consent each one needs: the
## screen (asked per look, or once for good), which app is in front (asked once,
## then a switch), and what the machine is doing (no dialog — see
## toggle_monitor()). Also the line the pet says when the machine is struggling.
##
## Speaks only through `said`, which pet.gd routes to its presentation gate, and
## reports menu ticks through `check_changed` rather than reaching for the menu.
## The two dialogs stay direct children of `Pet` and are handed in by setup().

signal said(emotion: String, text: String, record: bool, unprompted: bool)
signal check_changed(id: int, on: bool)

const MenuId := PetMenu.MenuId

## Screenshots are the one thing here that can hand something private to a
## third party, so nothing is captured until the user says so. "每次都可以"
## exists because being asked every time is how people learn to click through
## the prompt without reading it.
const CONSENT_ALWAYS := "always"

var _consent: ConfirmationDialog
var _presence_consent: ConfirmationDialog
var _pending_look := {}


func setup(scale: float, consent: ConfirmationDialog,
		presence_consent: ConfirmationDialog) -> void:
	_consent = consent
	_presence_consent = presence_consent

	_consent.title = "看一下你的螢幕"
	_consent.dialog_text = ""
	_consent.exclusive = false
	# Native window, laid out in physical pixels, so the stock theme comes out
	# undersized. A Theme on the dialog reaches the label and the buttons alike;
	# per-node font overrides only reach the node they're on.
	_consent.theme = PetStyle.dialog_theme(scale)
	_consent.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# "好" and "不要" said nothing about what was about to happen. Name the action
	# in the button, so the dialog is still readable to someone who skipped the
	# paragraph — which is most people, most of the time.
	_consent.ok_button_text = "好，看這一次"
	_consent.cancel_button_text = "不要"
	PetStyle.make_primary_button(_consent.get_ok_button(), scale)

	# Standing consent is the one answer here that can't be taken back by simply
	# not clicking it again, so it's the quietest thing in the window.
	var always := _consent.add_button("以後都不用問我", false, "always")
	PetStyle.make_ghost_button(always, scale)

	_consent.confirmed.connect(func() -> void: _resolve_look(true, false))
	_consent.canceled.connect(func() -> void: _resolve_look(false, false))
	_consent.custom_action.connect(func(action: StringName) -> void:
		if action == &"always":
			_consent.hide()
			_resolve_look(true, true))

	# Modelled on the screen-look consent above: nothing is sampled until the
	# user agrees, and the one way to agree here already *is* the standing
	# consent — there's no "just this once" for a background poll — so the
	# accept button gets the quiet treatment the vision dialog reserves for
	# "以後都不用問我", not the loud one it gives its one-off "看這一次".
	_presence_consent.title = "留意你切換 App 的節奏"
	_presence_consent.dialog_text = "\n".join(PackedStringArray([
		"我想多留意一點你的作息，這樣主動找你聊天才不會挑錯時間。",
		"",
		"・只記錄目前最上層 App 的名稱，還有你留在同一個 App 多久",
		"・不會看視窗標題、內容，或是你打的字",
		"・這些資料只留在這台電腦，不會送出網路，也不會寫進任何檔案",
		"・關掉開關，我就完全不會再讀",
	]))
	_presence_consent.exclusive = false
	_presence_consent.theme = PetStyle.dialog_theme(scale)
	_presence_consent.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_presence_consent.ok_button_text = "好，開始留意"
	_presence_consent.cancel_button_text = "不用了"
	PetStyle.make_ghost_button(_presence_consent.get_ok_button(), scale)
	_presence_consent.confirmed.connect(_on_presence_consent_confirmed)

	EventBus.screen_look_requested.connect(_on_screen_look_requested)
	EventBus.resource_alert.connect(_on_resource_alert)


## Both lines this flow says are the pet volunteering something — a menu refusal
## nobody is waiting on, a load alert — so they keep the gate's defaults: recorded,
## and held back while the user is typing.
func _say(emotion: String, text: String) -> void:
	said.emit(emotion, text, true, true)


## The old wording — "畫面會傳給語言模型" — left the three things people actually
## want to know unanswered: how much of the screen, to whom, and for how long.
func _on_screen_look_requested(question: String, record_question: bool) -> void:
	_pending_look = {"question": question, "record": record_question}
	if Config.get_value("vision", "consent", "") == CONSENT_ALWAYS:
		_resolve_look(true, false)
		return

	var lines := PackedStringArray()
	# A look the user asked for by typing: show them which question triggered it,
	# because a dialog appearing out of a normal sentence is startling otherwise.
	if not record_question:
		lines.append("你剛剛問：「%s」\n" % question.strip_edges())
	lines.append("要回答這個，我得把整個螢幕拍成一張圖，傳給 %s 讀。"
		% LLMService.provider_label(LLMService.get_provider_name()))
	lines.append("")
	lines.append("・只有這一次，我不會在背景一直看")
	lines.append("・看到的內容不會寫進我的長期記憶")
	lines.append("・拍的那一瞬間，我會先把自己藏起來")
	_consent.dialog_text = "\n".join(lines)
	_consent.reset_size()
	_consent.popup_centered()


func _resolve_look(allowed: bool, remember: bool) -> void:
	var pending := _pending_look
	_pending_look = {}
	if pending.is_empty():
		return
	if remember:
		Config.set_value("vision", "consent", CONSENT_ALWAYS)
	if allowed:
		VisionService.look(str(pending["question"]), bool(pending["record"]))
	elif bool(pending["record"]):
		# Nobody is waiting on an answer — this came from the menu.
		_say("neutral", "好啦，那我不看。")
	else:
		# The question is already sitting in history unanswered. Leaving it there
		# would look like the pet ignored it, so answer it blind instead.
		LLMService.answer_without_looking()


func _on_presence_consent_confirmed() -> void:
	PresenceService.grant_consent()
	check_changed.emit(MenuId.PRESENCE, true)


## Consent, once given, is sticky — re-checking the box after turning it off
## doesn't re-ask something already agreed to (same durability as vision's
## "always"). Turning it off needs no dialog at all; it's pure withdrawal.
func toggle_presence() -> void:
	if PresenceService.is_enabled():
		PresenceService.set_enabled(false)
		check_changed.emit(MenuId.PRESENCE, false)
	elif PresenceService.has_consented():
		PresenceService.set_enabled(true)
		check_changed.emit(MenuId.PRESENCE, true)
	else:
		_presence_consent.reset_size()
		_presence_consent.popup_centered()


## No consent dialog, unlike the two above, and the difference is what is being
## looked at. A screenshot leaves the machine and a presence poll is a record of
## what *you* were doing; a process list is what the computer is doing, read
## locally, never written down and never sent. The switch being off by default is
## the opt-in, and the row's tooltip carries the one consequence that isn't
## obvious from its name — see PetMenu._build_behaviour_menu().
func toggle_monitor() -> void:
	MonitorService.set_enabled(not MonitorService.is_enabled())
	check_changed.emit(MenuId.MONITOR, MonitorService.is_enabled())


## The service knows the numbers; it is not where the pet decides how it
## reacts to anything — the same split the mini-game scores and the work results
## already use, and the reason MonitorService emits a kind rather than a sentence.
##
## Gated on 主動說話 as well as on its own switch. This is the pet opening its
## mouth without being asked, which is exactly what that switch is for; leaving
## it out would give the one setting that means "don't do that" a hole in it.
func _on_resource_alert(kind: String, detail: Dictionary) -> void:
	if not Nudger.is_enabled():
		return
	var percent := roundi(float(detail.get("percent", 0.0)))
	var name := str(detail.get("name", ""))
	var emotion := "sad"
	var line := ""
	match kind:
		MonitorService.ALERT_MEM_TIGHT:
			line = "記憶體只剩 %d%% 可用了，要不要關掉幾個東西？" % percent
		MonitorService.ALERT_PROC_MEM:
			emotion = "neutral"
			line = "%s 一個就吃掉 %d%% 的記憶體耶。" % [name, percent]
		MonitorService.ALERT_CPU_BUSY:
			emotion = "neutral"
			line = "CPU 現在衝到 %d%%，跑最兇的是 %s。" % [percent, name] if not name.is_empty() \
				else "CPU 現在衝到 %d%%，風扇應該很忙。" % percent
	if line.is_empty():
		return
	_say(emotion, line)
