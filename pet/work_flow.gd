class_name WorkFlow
extends Node

## The walk from "幫我做事" to a job running, and what the pet says along it:
## the consent dialog, the uncommitted-work warning, the Codex login, the model's
## `[work]` offer, and the lines that report how the job went.
##
## It speaks only through `said`, which pet.gd routes to its single presentation
## gate — nothing here touches the bubble, the voice or the history directly. And
## it never opens the input itself: it asks with `wants_input`, because the chat
## field belongs to the pet window and its passthrough mask.
##
## The four dialogs stay direct children of `Pet` in pet.tscn and are handed in
## through setup(). They are Windows, and `_register_window_frame_rates()` only
## walks the pet's own children.

## Every line this flow says. Most pass `unprompted = false` — they answer
## something the user just asked for, and this flow opens the input itself, so
## the guard against talking over an open field would otherwise swallow them.
signal said(emotion: String, text: String, record: bool, unprompted: bool)
## Open the input in work mode with this placeholder; what is typed comes back
## through submit().
signal wants_input(placeholder: String)
## A job finished or failed, so whatever lists jobs is stale.
signal job_ended

const OPENAI_KEY: String = preload("res://llm/providers/openai_provider.gd").KEY_NAME

## How long between the pet mentioning that it is still working. Long enough that
## it reads as company rather than as a progress bar with a voice.
const WORK_CHATTER_EVERY := 120.0

const WORK_CHATTER := [
	"還在弄，別急。",
	"這個有點麻煩欸，再等我一下。",
	"快了快了。",
]

var _work_consent: ConfirmationDialog
var _work_offer: ConfirmationDialog
var _dirty_warning: ConfirmationDialog
var _codex_login: ConfirmationDialog

## Set once the user has been told a login is still in flight, so the next click
## on the same entry cancels it instead of repeating the message.
var _login_cancel_armed := false
## The workspace a job is being set up for, carried across the consent dialog, the
## uncommitted-work warning and the login prompt — any of which can interrupt the
## walk from "幫我做事" to a typed request.
var _pending_space := {}
## When the pet may next say something while a job runs. Reset per job; the point
## is one reassuring line every couple of minutes, not a running commentary.
var _work_chatter_at := 0.0
## A job the model proposed, held while the user decides.
var _pending_work := {}
## A request the user has already typed, so the walk through begin()'s gates
## ends by starting the job rather than asking them to type it a second time.
var _queued_request := ""


## Called from pet.gd's _ready(), once the UI scale is known.
func setup(scale: float, work_consent: ConfirmationDialog,
		work_offer: ConfirmationDialog, dirty_warning: ConfirmationDialog,
		codex_login: ConfirmationDialog) -> void:
	_work_consent = work_consent
	_work_offer = work_offer
	_dirty_warning = dirty_warning
	_codex_login = codex_login

	# The third consent shape in this app, and the questions are different again.
	# A screenshot's are how much, to whom, how long. A background poll's are what is
	# sampled and where it goes. This one's are the ones a folder full of your own
	# work raises: which folder, what can it change in there, and can I stop it.
	#
	# Note what this dialog does *not* promise. The screen-look one can say "只有這
	# 一次"; this one cannot, because an agent editing files is exactly the thing that
	# has to be allowed to write. So the honest answer is the allowlist itself —
	# nothing is touched but the folder you named — plus a stop button that works.
	_work_consent.dialog_text = "\n".join(PackedStringArray([
		"你可以叫我做事，我會請 %s 實際動手，用你已經登入的那個帳號。"
			% WorkService.runner_label(WorkService.runner()),
		"",
		"・我只在你指定的資料夾裡開工，一次一個，你沒加的資料夾我看不到",
		"・標成「可以改」的，它會真的改檔案、也會執行指令來驗證自己做對了",
		"・執行指令這件事，Codex 有系統層級的沙箱擋住資料夾以外；Claude Code 沒有，靠的是它自己守規矩",
		"・改壞了要靠版本控制救，所以資料夾裡有沒存的東西我會先提醒你",
		"・每個資料夾都能單獨改成「只能看」，那樣它連寫入和執行的工具都沒有",
		"・做到一半隨時可以在「工作」視窗按停下來，做完我會告訴你哪些檔案動過",
		"・這會用掉你的訂閱或 API 額度，一次可能要好幾分鐘",
	]))
	_work_consent.exclusive = false
	_work_consent.theme = PetStyle.dialog_theme(scale)
	_work_consent.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PetStyle.make_ghost_button(_work_consent.get_ok_button(), scale)
	_work_consent.confirmed.connect(_on_work_consent_confirmed)
	# Declining used to do nothing at all — no line, and `_pending_space` left
	# set. The pet went quiet, the input stayed in chat mode, and the next thing
	# the user typed became an ordinary conversation turn with no sign that the
	# job had been dropped. That is exactly how this feature looked broken.
	_work_consent.canceled.connect(_abandon_pending_work.bind("好，那我不動你的資料夾。"))

	# The one guard that stands between the level the user chose — edit in place —
	# and losing work git can't get back. Deliberately a question, not a notice: a
	# warning you can't act on is noise, and this one has an obvious action.
	#
	# Per job rather than per folder, because the answer changes every time. It is
	# only asked where it means something: an editable workspace, in a git repo, with
	# something uncommitted in it.
	_dirty_warning.exclusive = false
	_dirty_warning.theme = PetStyle.dialog_theme(scale)
	_dirty_warning.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PetStyle.make_ghost_button(_dirty_warning.get_ok_button(), scale)
	_dirty_warning.confirmed.connect(_on_dirty_warning_confirmed)
	_dirty_warning.canceled.connect(
		_abandon_pending_work.bind("好，那你先去存，弄好再叫我。"))

	_work_offer.exclusive = false
	_work_offer.theme = PetStyle.dialog_theme(scale)
	_work_offer.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_work_offer.ok_button_text = "好，去做"
	_work_offer.cancel_button_text = "不用，用講的就好"
	PetStyle.make_ghost_button(_work_offer.get_ok_button(), scale)
	_work_offer.confirmed.connect(_on_work_offer_accepted)
	# Backing out still owes them an answer: the question is already sitting in
	# history, and leaving it there reads as the pet having ignored them.
	_work_offer.canceled.connect(func() -> void:
		_pending_work = {}
		LLMService.answer_without_working())

	# Two ways in, because they answer different questions. The browser signs in a
	# ChatGPT account and spends its quota; the API key is the one this app may
	# already be holding, costs nothing extra to offer, and bills the API instead.
	#
	# The key route is only shown when there *is* a key — a button that explains it
	# can't do anything is worse than no button.
	_codex_login.dialog_text = "\n".join(PackedStringArray([
		"要我做東西得先讓 Codex 有個帳號。它是 OpenAI 自己的工具，我只是請它幫忙。",
		"",
		"・用 ChatGPT 帳號登入：我會開登入頁並給你一組一次性代碼，你輸入就好",
		"・登入頁是 OpenAI 自己的網站，我不會經手你的密碼或憑證",
		"・登入結果存在 Codex 自己的檔案裡，我不會去讀它",
		"・走 ChatGPT 帳號會用掉你的訂閱額度；走 API key 則算在 OpenAI 帳單上",
	]))
	_codex_login.exclusive = false
	_codex_login.theme = PetStyle.dialog_theme(scale)
	_codex_login.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# The main action gets the loud treatment, not the ghost one. Ghosting it made
	# both routes read as equally optional and the primary one look disabled —
	# the same mistake ChatLogPanel's 關閉 button already records, where the ghost
	# style hid the thing the window was for.
	PetStyle.make_primary_button(_codex_login.get_ok_button(), scale)

	# The quieter of the two routes, and only offered when there is a key to use.
	var with_key := _codex_login.add_button("用我存的 API key", false, "apikey")
	PetStyle.make_ghost_button(with_key, scale)
	with_key.visible = Config.has_secret(OPENAI_KEY)

	_codex_login.confirmed.connect(_start_browser_login)
	_codex_login.custom_action.connect(func(action: StringName) -> void:
		if action == &"apikey":
			_codex_login.hide()
			_login_with_stored_key())

	EventBus.work_requested.connect(_on_work_requested)
	WorkService.finished.connect(_on_work_finished)
	WorkService.failed.connect(_on_work_failed)
	WorkService.progress.connect(_on_work_progress)
	CodexCli.login_finished.connect(_on_codex_login_finished)
	CodexCli.login_hint.connect(_on_codex_login_hint)


## Lines this flow says are never recorded: they narrate an action or answer a
## step of it, and none is conversation the next reply should build on.
func _say(emotion: String, text: String, unprompted := false) -> void:
	said.emit(emotion, text, false, unprompted)


## The walk from picking a folder to typing a request. Every step that can
## interrupt it stashes the workspace in `_pending_space` and comes back here.
func begin(space: Dictionary) -> void:
	if space.is_empty():
		return
	_pending_space = space

	if not WorkService.has_consented():
		_work_consent.reset_size()
		_work_consent.popup_centered()
		return
	if WorkService.is_busy():
		_say("neutral", "我還在做上一件事啦，等我弄完。")
		return

	# Only the codex runner needs an account of its own; claude carries its own
	# login and is either working or not.
	if WorkService.runner() == WorkService.RUNNER_CODEX and not _codex_ready():
		return

	var path := str(space.get("path", ""))
	var editable := str(space.get("level", "")) == WorkspaceService.LEVEL_EDIT
	if editable:
		var dirty := WorkspaceService.dirty_count(path)
		if dirty > 0:
			_dirty_warning.title = "%s 還有沒存進版本控制的東西" % str(space.get("name", ""))
			_dirty_warning.dialog_text = "\n".join(PackedStringArray([
				"「%s」裡有 %d 個檔案改了還沒 commit。" % [str(space.get("name", "")), dirty],
				"",
				"我等一下會直接改這個資料夾裡的檔案。萬一改壞了，已經 commit 的東西 git 救得回來，這 %d 個救不回來。" % dirty,
				"",
				"要先去存一下，還是就這樣開始？",
			]))
			_dirty_warning.ok_button_text = "就這樣開始"
			_dirty_warning.cancel_button_text = "我先去存"
			_dirty_warning.reset_size()
			_dirty_warning.popup_centered()
			return

	_pending_space = {}
	_open_work_input(space)


## Returns false when a login is in the way and has been dealt with — the caller
## stops, and whatever the user does next comes back through _on_codex_login_*.
func _codex_ready() -> bool:
	if CodexCli.is_logging_in():
		# The armed-button idiom the panels already use, in the only place a menu
		# entry can hold it: told once, and acted on the second time. Without this
		# there is no way out of a login the user has abandoned except waiting for
		# CodexCli.BROWSER_TIMEOUT.
		if not _login_cancel_armed:
			_login_cancel_armed = true
			_say("neutral", "還在等你登入喔。再點一次就取消。")
			return false
		CodexCli.cancel_browser_login()
		return false
	# Having the CLI is checked when the menu is built; having an *account* is
	# recoverable, so it is asked about here rather than disabling the entry.
	if not CodexCli.is_logged_in():
		_codex_login.reset_size()
		_codex_login.popup_centered()
		return false
	return true


## The end of every route in. When the request is already known — the model
## proposed it and the user agreed — start straight away; making them retype what
## they just typed is the one thing that would make the chat trigger pointless.
func _open_work_input(space: Dictionary) -> void:
	_pending_space = space
	if not _queued_request.is_empty():
		var request := _queued_request
		_queued_request = ""
		submit(request)
		return
	var suffix := "" if str(space.get("level", "")) == WorkspaceService.LEVEL_EDIT \
		else "（只能看）"
	# Whether the last job's context carries over changes what is worth typing —
	# "再改一下" only means anything if it does. The placeholder is the one place
	# that answer is already in front of the user at the moment they need it, so it
	# costs no extra UI.
	var lead := "接著上次，" if WorkService.would_resume(space) else ""
	wants_input.emit("%s要我在 %s 做什麼？%s"
		% [lead, str(space.get("name", "")), suffix])


func submit(text: String) -> void:
	var space := _pending_space
	_pending_space = {}
	if space.is_empty():
		return
	if not WorkService.start(space, text):
		_say("sad", "咦，我叫不動 %s 欸。"
			% WorkService.runner_label(WorkService.runner()))
		return
	_work_chatter_at = WORK_CHATTER_EVERY
	# The brain would otherwise wander off mid-job, and the line below arrives
	# minutes later with the pet somewhere else entirely.
	_say("excited", "好，我去弄，可能要一下子。")


## Every way of backing out of a job, in one place. Two things have to happen
## besides saying so: the stashed workspace goes, or a later menu-driven job
## inherits it, and a request queued from chat goes with it — otherwise the next
## folder the user picks silently runs the sentence they abandoned.
func _abandon_pending_work(line: String) -> void:
	var was_typed := not _queued_request.is_empty()
	_pending_space = {}
	_queued_request = ""
	_say("neutral", line)
	if was_typed:
		# Their question is still in history unanswered. Answer it in words.
		LLMService.answer_without_working()


func _on_work_consent_confirmed() -> void:
	WorkService.grant_consent()
	begin(_pending_space)


func _on_dirty_warning_confirmed() -> void:
	var space := _pending_space
	_pending_space = {}
	if not space.is_empty():
		_open_work_input(space)


## The model decided a typed message was a job. It is put to the user rather than
## launched: unlike a screenshot, this spends money and can edit files, so a
## misread sentence must not be able to start one on its own.
##
## Naming the workspace and the request back to them is the whole point of the
## dialog — it is the only place they can see what the model concluded before it
## acts on it.
func _on_work_requested(space_name: String, request: String) -> void:
	var space := _resolve_space(space_name)
	if space.is_empty() or request.strip_edges().is_empty():
		# The model named a folder that isn't there. Don't leave the question
		# hanging — answer it in words.
		LLMService.answer_without_working()
		return
	_pending_work = {"space": space, "request": request.strip_edges()}
	_work_offer.title = "要我去做這件事嗎？"
	_work_offer.dialog_text = "\n".join(PackedStringArray([
		"你剛剛說：「%s」" % request.strip_edges(),
		"",
		"這件事我可以請 %s 進「%s」去做（%s）。"
			% [WorkService.runner_label(WorkService.runner()), str(space["name"]),
				WorkspaceService.level_label(str(space["level"]))],
		"",
		"要的話我就開工，可能要幾分鐘；不要的話我就直接用講的回你。",
	]))
	_work_offer.reset_size()
	_work_offer.popup_centered()


## Whichever folder the model named, or the only one there is. An unnamed tag is
## unambiguous exactly when there is a single workspace, which is the common case
## and the one worth not making the user disambiguate.
func _resolve_space(space_name: String) -> Dictionary:
	var spaces := WorkspaceService.list()
	var usable: Array[Dictionary] = []
	for space in spaces:
		if bool(space["exists"]):
			usable.append(space)
	if usable.is_empty():
		return {}
	var wanted := space_name.strip_edges().to_lower()
	if wanted.is_empty():
		return usable[0] if usable.size() == 1 else {}
	for space in usable:
		if str(space["name"]).to_lower() == wanted:
			return space
	# The model tends to paraphrase a name it half-remembers, so fall back to a
	# containment match before giving up.
	for space in usable:
		var name := str(space["name"]).to_lower()
		if wanted.contains(name) or name.contains(wanted):
			return space
	return usable[0] if usable.size() == 1 else {}


func _on_work_offer_accepted() -> void:
	var job := _pending_work
	_pending_work = {}
	if job.is_empty():
		return
	# Through _begin_work so the consent dialog, the busy check, the Codex login
	# prompt and the uncommitted-work warning all still apply — this is a second
	# way in, not a way around.
	_queued_request = str(job["request"])
	begin(job["space"])


func _start_browser_login() -> void:
	if not CodexCli.begin_browser_login():
		_say("sad", "咦，登入指令叫不起來欸。")
		return
	# The code takes a second or two to arrive; CodexCli emits it as a hint, and
	# that line is what actually tells the user what to do.
	_say("neutral", "等我一下，我去拿登入碼。")


## Blocking, but only for as long as the CLI takes to write a file — see
## CodexCli.login_with_api_key(). Nothing is said before it, because a "稍等"
## that resolves in the same frame just flickers.
func _login_with_stored_key() -> void:
	if CodexCli.login_with_api_key(Config.get_secret(OPENAI_KEY)):
		_say("happy", "用你的 API key 登好了，那我開始做。")
		begin(_pending_space)
		return
	_say("sad", "那把 key 好像不能用來登入 Codex，要不要改用瀏覽器？")


func _on_codex_login_hint(message: String) -> void:
	_say("neutral", message)


func _on_codex_login_finished(ok: bool, message: String) -> void:
	_login_cancel_armed = false
	_say("happy" if ok else "sad", message)
	if ok:
		# Straight on to the thing they actually asked for. The line above stays
		# in the bubble; opening the input doesn't clear it.
		begin(_pending_space)


## Driven off the progress signal rather than a timer of its own: steps arrive
## continuously while a job runs, so this needs no new process loop.
##
## Left `unprompted`, unlike everything else in this flow — a "still working" line
## has nothing to say that is worth talking over a reply or an open input, which is
## exactly the case pet.gd's unprompted guard exists for.
func _on_work_progress(_entry: Dictionary) -> void:
	var job := WorkService.current()
	if job.is_empty():
		return
	var seconds := float(job["seconds"])
	if seconds < _work_chatter_at:
		return
	_work_chatter_at = seconds + WORK_CHATTER_EVERY
	_say("neutral", WORK_CHATTER[randi() % WORK_CHATTER.size()], true)


## Not recorded, for the same reason the export line isn't: this is the pet
## narrating an action rather than answering anything, and a history whose newest
## turn is that would be re-sent with the next real question for nothing.
##
## What changed comes from git, not from the agent's own account of itself. An
## agent that believes it edited a file and didn't is a real failure mode, and the
## working tree is the truth either way.
func _on_work_finished(result: Dictionary) -> void:
	var line := str(result.get("message", ""))
	if line.is_empty():
		line = "弄完了！"
	var changes: PackedStringArray = result.get("changes", PackedStringArray())
	if changes.is_empty():
		line += "（沒有動到檔案）"
	else:
		line += "（動了 %d 個檔案，詳細在「工作」裡）" % changes.size()
	_say("happy" if bool(result.get("ok", false)) else "sad", line)
	job_ended.emit()


func _on_work_failed(reason: String) -> void:
	_say("sad", reason)
	job_ended.emit()

