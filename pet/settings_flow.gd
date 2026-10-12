class_name SettingsFlow
extends Node

## What happens after you change a setting the pet has to act on: a key or a
## service address typed into the entry window, the voice service answering (or
## not), the voice library refreshing, the fixed lines being pre-rendered, and
## anything the voice layer has to say about itself.
##
## Speaks only through `said`, which pet.gd routes to its presentation gate. The
## entry window stays a direct child of `Pet` and is handed in by setup().

## `speak` exists for one caller: a notice from the voice layer, which is often
## about speech having just broken and must not be routed back through it.
signal said(emotion: String, text: String, record: bool, unprompted: bool, speak: bool)
signal check_changed(id: int, on: bool)
## A row's label or state depends on something that just changed.
signal menu_stale
## How many pre-rendered lines are still outstanding, for the menu row.
signal prerender_changed(left: int)

const MenuId := PetMenu.MenuId
const OPENAI_KEY: String = preload("res://llm/providers/openai_provider.gd").KEY_NAME

## What the entry window collects besides `Config` secret names: the one thing
## it asks for that is not a secret. The window is one node serving four
## settings, so each ask says which — otherwise the handler could only ever store
## one, and the rest would quietly land under its name.
const URL_ENTRY := "voxcpm_url"

var _entry: EntryDialog
## Whether the next discovery result is one the user is waiting on. Discovery
## re-runs on every menu open, so without this the pet would report the state of
## the voice service every time the menu is touched for anything at all.
var _awaiting_url_check := false
var _prerender_left := 0


func setup(entry: EntryDialog) -> void:
	_entry = entry
	_entry.submitted.connect(_on_entry_submitted)
	TTSService.backend_checked.connect(_on_backend_checked)
	TTSService.voice_library_refreshed.connect(_on_voice_library_refreshed)
	TTSService.remarked.connect(_on_voice_remarked)
	TTSService.prerender_progress.connect(_on_prerender_progress)


## The four rows that open the entry window. Each names what it is for, and
## where the value will be kept.
func ask(id: int) -> void:
	match id:
		MenuId.SET_KEY:
			_entry.ask(OPENAI_KEY, "OpenAI API key",
				"用來聊天跟看螢幕的。%s" % _entry_storage_note(), true)
		MenuId.SET_ELEVEN_KEY:
			_entry.ask(ElevenVoice.KEY_NAME, "ElevenLabs API key",
				"雲端語音要用的。%s" % _entry_storage_note(), true)
		MenuId.SET_VOXCPM_KEY:
			_entry.ask(VoxCPMVoice.KEY_NAME, "VoxCPM 服務的 API key",
				"只有在服務開了驗證時才需要。%s" % _entry_storage_note(), true)
		MenuId.SET_VOXCPM_URL:
			# The one entry here that is not a secret, so it is not masked and it
			# opens showing the current value: editing an address is a different
			# act from retyping one from memory, and retyping is how a working
			# setting becomes a typo.
			_entry.ask(URL_ENTRY, "VoxCPM 服務位置",
				"語音服務在哪裡。存好之後我會馬上連連看，連不上會跟你說。",
				false, TTSService.voxcpm_url())


## The pet answering something the user just did: shown even with the input
## open, and not recorded — it is feedback about the app, not conversation.
func _answer(emotion: String, text: String) -> void:
	said.emit(emotion, text, false, false, true)


## The gate's defaults: recorded, and held back while the user is typing.
func _volunteer(emotion: String, text: String) -> void:
	said.emit(emotion, text, true, true, true)


func _say(emotion: String, text: String, speak: bool) -> void:
	said.emit(emotion, text, false, false, speak)


func _set_prerender_left(left: int) -> void:
	_prerender_left = left
	prerender_changed.emit(left)


func _on_entry_submitted(what: String, value: String) -> void:
	if what == URL_ENTRY:
		_on_url_submitted(value)
	else:
		_on_secret_submitted(what, value)


## A service address the user typed.
##
## Normalised rather than validated: a bare `127.0.0.1:8080` is what people type
## and what every tunnel's own instructions print, and refusing it to teach a
## lesson about schemes helps nobody. Anything genuinely wrong is caught by the
## thing that decides it — the service either answers or it does not — and that
## answer arrives below.
func _on_url_submitted(value: String) -> void:
	var url := value.strip_edges()
	if not url.contains("://"):
		url = "http://" + url
	url = url.rstrip("/")
	_awaiting_url_check = true
	TTSService.set_voxcpm_url(url)
	menu_stale.emit()
	_answer("neutral", "好，我改連 %s，等我看看……" % url)


## What the service said back, once. Reported here rather than assumed after a
## timer: a tunnel answers slower than localhost, and a fixed wait long enough
## for one is a wait nobody sits through for the other. `TTSService` swaps the
## backend out by itself when this fails, so this only has to say so.
func _on_backend_checked(healthy: bool, reason: String, explained: bool) -> void:
	if not _awaiting_url_check:
		return
	_awaiting_url_check = false
	menu_stale.emit()
	if healthy:
		# Adopted right away, the same way pasting a key is — and here it is what
		# makes the sentence true. A wrong address takes the backend down with it,
		# so by the time the right one is typed the pet is on the OS voice and
		# nothing switches back; 「連上了，有 5 種聲音」 would then be describing a
		# service the pet is not using.
		TTSService.select_backend(TTSService.BACKEND_VOXCPM)
		_answer("happy", "連上了！有 %d 種聲音可以用。"
			% TTSService.list_voices().size())
	elif not explained:
		# Only when nothing else did. Where this address belongs to the voice the
		# pet is speaking in, `TTSService` has already said so *and* said what it
		# is falling back to, which is strictly more than this could.
		_answer("sad", reason)


func _on_secret_submitted(key: String, value: String) -> void:
	# Almost always a stray character from a bad paste — API keys are ASCII, and
	# the Keychain can't round-trip anything else. See SecretStore.write().
	if not SecretStore.is_ascii(value):
		_volunteer("sad", "這個 key 有奇怪的字元，是不是貼到多餘的東西了？")
		return

	var secured := Config.set_secret(key, value)
	# Adopted right away rather than sending the user back to the menu — a key is
	# the only thing standing between the mock and the real thing in both cases.
	# VoxCPM adoption waits for its protected endpoint to accept the new key;
	# selecting synchronously here would still see the previous 401 result.
	if key == VoxCPMVoice.KEY_NAME:
		TTSService.rediscover_and_select(TTSService.BACKEND_VOXCPM)
	elif key == ElevenVoice.KEY_NAME:
		# The backend caches its availability reason, so it has to reconsider the
		# newly stored key before the row can stop being disabled.
		TTSService.rediscover_and_select(TTSService.BACKEND_ELEVEN)
	elif LLMService.get_provider_name() != "openai":
		LLMService.select_provider("openai")
	menu_stale.emit()

	var note := "收到！鑰匙我幫你收在 %s 了。" % Config.secret_backend_name()
	if not secured:
		note = "存好了，不過這台機器沒有安全儲存，我只能放在設定檔裡。"
	_volunteer("happy", note)


func _entry_storage_note() -> String:
	var where := Config.secret_backend_name()
	return "會存進 %s。" % where if not where.is_empty() \
		else "這台機器沒有安全儲存，只能存成明文設定檔。"


func refresh_voice_library() -> void:
	if not TTSService.refresh_voice_library():
		return
	menu_stale.emit()
	_answer("neutral", "好，我重新讀一次聲音庫……")


func _on_voice_library_refreshed(healthy: bool, reason: String, voices: int,
		explained: bool) -> void:
	menu_stale.emit()
	if healthy:
		_answer("happy", "聲音庫更新好了，現在有 %d 種聲音可以用。" % voices)
	elif not explained:
		_answer("sad", reason)


func toggle_speech() -> void:
	TTSService.set_enabled(not TTSService.is_enabled())
	check_changed.emit(MenuId.SPEAK, TTSService.is_enabled())


## Anything the voice layer has to tell the user: a backend that fell over, a
## machine too slow for it, a cloning attempt that worked or didn't.
##
## A direct call rather than EventBus.pet_nudged, like every other line the pet
## says about itself — these must be *shown*, not spoken. Half of them exist
## precisely because speech just stopped working, and routing them through the
## thing that broke is how a failure notice becomes silence.
func _on_voice_remarked(text: String) -> void:
	# This line exists because speech failed; do not feed it back through the
	# subsystem that just reported the failure.
	_say("neutral", text, false)


## Render every fixed line, in every voice the speaking backend offers.
##
## Speaks its own progress rather than putting a bar anywhere: this takes about
## a second a clip and the pet is standing right there. Both lines go through
## `_answer(…)` — the pet answering something the user just
## clicked has to appear even while the chat input is open, and must not be
## recorded as something it said.
func start_prerender() -> void:
	var count := TTSService.prerender_fixed_lines()
	if count < 0:
		_answer("sad", "這個要用本機服務的聲音才行喔。")
		return
	if count == 0:
		_answer("happy", "都錄好了，不用再錄一次。")
		return
	_set_prerender_left(count)
	# Naming the voices matters: the number is several times what the user can
	# see in the menu, and 「17 句」 against 「85 段」 otherwise reads as a bug.
	var voices := TTSService.list_voices().size()
	var scope := "（%d 個聲音都錄）" % voices if voices > 1 else ""
	_answer("neutral", "好，我把 %d 段先錄起來%s，等我一下。" % [count, scope])


func _on_prerender_progress(done: int, left: int) -> void:
	_set_prerender_left(left)
	if left > 0:
		return
	# Said only at the end, and only about what actually landed: a batch cut
	# short by the user typing still leaves everything it finished in the cache,
	# so "none" and "some" are different outcomes and claiming the whole set
	# would be a lie the next silence exposes.
	_answer("happy" if done > 0 else "sad",
		"錄好 %d 段了，以後這幾句我馬上就能講。" % done if done > 0
		else "一段都沒錄成，等一下再試試看？")
