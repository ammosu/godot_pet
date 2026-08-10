extends Node

## Speaks the pet's lines. Which voice does the speaking is a backend — the
## operating system's own (`OSVoice`, no dependency at all), a VoxCPM service
## (`VoxCPMVoice`), or a paid API (`ElevenVoice`) —
## swapped the same way `LLMService` swaps providers, so everything below this
## line is written once.
##
## Sentences are spoken as they arrive rather than after the whole reply lands,
## so the pet starts talking at roughly the moment the bubble starts typing. That
## split is also what makes a neural backend viable at all: the engine has no
## streaming, so an utterance is only as fast as it is short, and a sentence is
## exactly the unit that keeps the wait under half a second.

## Anything that ends a spoken sentence, in either script.
const TERMINATORS := ["。", "！", "？", "…", "\n", ".", "!", "?"]
## Speak an unterminated run once it gets this long, so a reply with no
## punctuation doesn't stay silent until the very end. It doubles as the upper
## bound on how long one neural utterance can take to synthesize.
const FLUSH_AFTER := 40

## Words this engine reads with the wrong 破音字 reading, and an unambiguous
## homophone to send instead. Loaded once, like every other prompt file.
const RESPELL_PATH := "res://prompts/pronunciation.json"

const BACKEND_OS := "os"
const BACKEND_ELEVEN := "eleven"
const BACKEND_VOXCPM := "voxcpm"

## What a machine that has never chosen gets, and where an unrecognised choice
## lands. VoxCPM rather than the OS voice: on Linux the latter is
## espeak, which reads Traditional Chinese as a string of syllables — usable as a
## fallback, not as a first impression. A machine without the service still ends
## up on the OS voice within a second, by the discovery below, and pays only a
## menu row that says why.
const DEFAULT_BACKEND := BACKEND_VOXCPM

## Something happened to the voice that the pet should say out loud. Carried on a
## signal rather than spoken here, because `pet.gd` is the only thing that
## decides how the pet reacts to anything.
signal remarked(text: String)
## The voice changed identity — a different backend, or a different voice from
## the one it offers — so the menu row naming it is stale.
signal voice_changed()

## A pre-render batch moved on. `left` reaching zero ends it, however it ended.
signal prerender_progress(done: int, left: int)

## A backend finished asking itself whether it can run here. Carried out so the
## settings UI can report whether a service address that was just typed actually
## reaches anything — the one moment where "it did not work" has to arrive while
## the user is still looking at what they changed.
##
## `explained` says this already went out on `remarked`, which happens whenever
## the failure took the *speaking* backend down with it. Without it both owners
## say the same sentence and the second cuts the first off half-typed — measured
## on screen. The listener still gets told, because it has to stop waiting either
## way; it just must not repeat it.
signal backend_checked(healthy: bool, reason: String, explained: bool)
## The explicit VoxCPM library refresh requested from the advanced speech menu
## finished. `explained` prevents the UI from repeating a failure that already
## made the speaking backend fall back and announce why.
signal voice_library_refreshed(healthy: bool, reason: String, voices: int, explained: bool)

var _enabled := false
var _buffer := ""
var _backend_name := BACKEND_OS
var _backend: TTSBackend
var _os_voice: OSVoice
var _eleven: ElevenVoice
var _voxcpm: VoxCPMVoice
var _voice_library_refreshing := false
## A newly pasted VoxCPM key is not usable until the protected voice-list
## request accepts it. Remember the user's choice across that asynchronous
## check instead of consulting the previous attempt's cached failure.
var _select_after_check := ""
## [[from, to], …] sorted longest-first — see _load_respellings().
var _respellings: Array = []


func _ready() -> void:
	_load_respellings()
	_os_voice = OSVoice.new()
	_os_voice.name = "OSVoice"
	add_child(_os_voice)
	_eleven = ElevenVoice.new()
	_eleven.name = "ElevenVoice"
	add_child(_eleven)
	_voxcpm = VoxCPMVoice.new()
	_voxcpm.name = "VoxCPMVoice"
	add_child(_voxcpm)
	for backend in [_os_voice, _voxcpm, _eleven]:
		backend.broke.connect(_on_backend_broke)
		backend.warned.connect(func(message: String) -> void: remarked.emit(message))
		backend.line_prerendered.connect(func(done: int, left: int) -> void:
			prerender_progress.emit(done, left))
		backend.checked.connect(_on_backend_checked.bind(backend))

	# Startup picks a backend but never writes one back — persisting what merely
	# happened to work on first run is how auto-detection gets permanently
	# defeated, the same rule LLMService.set_provider() follows. So a machine
	# without the engine falls back for this session only, and plugging it back
	# in restores the choice with nothing to re-select.
	_set_backend(str(Config.get_value("tts", "backend", DEFAULT_BACKEND)))
	_enabled = bool(Config.get_value("tts", "enabled", true)) and is_available()

	EventBus.reply_chunk.connect(_on_chunk)
	EventBus.reply_finished.connect(_on_finished)
	EventBus.reply_failed.connect(_on_interrupted)
	EventBus.user_said.connect(_on_user_said)
	EventBus.file_content_said.connect(_on_user_said)
	EventBus.image_content_said.connect(_on_user_said)


func _exit_tree() -> void:
	if _backend != null:
		_backend.shutdown()


## False when the current backend cannot speak here — no voices installed, no
## engine, no models.
func is_available() -> bool:
	return _backend != null and _backend.is_available()


## Empty when available; otherwise a finished sentence naming what is missing.
func unavailable_reason() -> String:
	return _backend.unavailable_reason() if _backend != null else ""


func is_enabled() -> bool:
	return _enabled


func set_enabled(enabled: bool) -> void:
	_enabled = enabled and is_available()
	Config.set_value("tts", "enabled", _enabled)
	if not _enabled:
		stop()


func get_voice_name() -> String:
	return _backend.voice_name() if _backend != null else ""


func stop() -> void:
	_buffer = ""
	if _backend != null:
		_backend.stop()


# --- Which voice --------------------------------------------------------------

func list_backends() -> PackedStringArray:
	return PackedStringArray([BACKEND_OS, BACKEND_VOXCPM, BACKEND_ELEVEN])


func backend_label(id: String) -> String:
	match id:
		BACKEND_VOXCPM:
			return "VoxCPM 語音服務"
		BACKEND_ELEVEN:
			return "ElevenLabs（雲端）"
		_:
			return "系統語音"


func get_backend_name() -> String:
	return _backend_name


## Re-run every backend's discovery. Called when the menu opens, so a library
## built or a model downloaded while the pet was running takes effect without a
## restart — the same courtesy the 造型 menu already extends to a pet pack
## installed by an external CLI.
##
## Note what it does *not* fix: an edit to `config.cfg`, which `Config` reads once
## at startup.
##
## Cheap: a handful of `file_exists` calls, plus at most one short-lived process
## if no well-known Python is where it should be.
func rediscover() -> void:
	# A key pasted through the menu or a VoxCPM service started/stopped since the
	# last look both need the backends to reconsider their cached availability.
	_eleven.refresh()
	_voxcpm.refresh()


## Re-check a backend after its credential changes and adopt it only once the
## new credential has actually been accepted. ElevenLabs discovery is local and
## synchronous; VoxCPM has to wait for the protected /v1/voices response.
func rediscover_and_select(id: String) -> void:
	if id == BACKEND_VOXCPM:
		_select_after_check = id
		_voxcpm.refresh_after_credentials_change()
		return
	if id == BACKEND_ELEVEN:
		_eleven.refresh()
		select_backend(id)


## A deliberate network refresh, unlike rediscover(), which only checks whether
## services are reachable. Returns false while the previous click is still in
## flight so the UI can make repeated clicks harmless.
func refresh_voice_library() -> bool:
	if _voice_library_refreshing:
		return false
	_voice_library_refreshing = true
	_voxcpm.refresh_voice_library()
	# request() can fail synchronously (for example, an invalid URL). In that
	# case the checked signal above already cleared the flag and reported why.
	return _voice_library_refreshing


func is_voice_library_refreshing() -> bool:
	return _voice_library_refreshing


func backend_is_available(id: String) -> bool:
	return _for(id).is_available()


## Where the VoxCPM service is, and where to point it instead. Read back from the
## backend rather than from config so the default shows through when nothing has
## been set — an empty box is not an address anyone can correct.
func voxcpm_url() -> String:
	return _voxcpm.base_url() if _voxcpm != null else ""


func set_voxcpm_url(url: String) -> void:
	Config.set_value("tts", "voxcpm_url", url)
	# `base_url()` reads config on every call, so there is nothing to restart —
	# but nothing has re-asked the service either, and until it does
	# `is_available()` still answers about the old address.
	_voxcpm.refresh()


func backend_unavailable_reason(id: String) -> String:
	return _for(id).unavailable_reason()


## Persisted, unlike `_set_backend` — this one is a choice.
func select_backend(id: String) -> void:
	if id == _backend_name:
		return
	# Asked for by name, so a refusal names *that* backend's reason and changes
	# nothing. Letting `_set_backend`'s fallback handle it here would both persist
	# a choice the user did not make and report whatever the fallback happens to
	# say about itself. (The menu disables an unavailable row, so this is the
	# programmatic path — but it is the one that would be silent.)
	var reason := backend_unavailable_reason(id)
	if not reason.is_empty():
		remarked.emit(reason)
		return
	_set_backend(id)
	Config.set_value("tts", "backend", _backend_name)
	_enabled = _enabled and is_available()
	voice_changed.emit()


func _set_backend(id: String) -> void:
	# A name that is no longer a backend, which is what `config.cfg` holds on every
	# machine that had selected one since removed. `_for()` already hands back the
	# OS voice for anything it does not know, but keeping the dead name in
	# `_backend_name` made that invisible: the menu ticked no row at all, the pet
	# spoke in espeak, and 先錄好固定台詞 asked the OS voice to pre-render — which
	# correctly answers "nothing to do", so the pet said 「都錄好了」 having rendered
	# nothing.
	#
	# It lands on the default, not on the OS voice, because the one name this
	# actually catches is `qwen3` — a local neural backend, replaced by a local
	# neural backend. Normalised here rather than persisted, so plugging a backend
	# back in still restores the choice with nothing to re-select.
	if not list_backends().has(id):
		id = DEFAULT_BACKEND
	var wanted := _for(id)
	# Order matters: the OS voice is the fallback and asking it is free, while
	# asking the neural one runs discovery. Nothing should pay for that at startup
	# on a machine that never selected it.
	if id != BACKEND_OS and not wanted.is_available():
		wanted = _os_voice
		id = BACKEND_OS
	if _backend == wanted:
		_backend_name = id
		return
	if _backend != null:
		_backend.shutdown()
	_backend = wanted
	_backend_name = id


func _for(id: String) -> TTSBackend:
	match id:
		BACKEND_VOXCPM:
			return _voxcpm
		BACKEND_ELEVEN:
			return _eleven
		_:
			return _os_voice


## A backend finished discovering. Two jobs, and the second is why this exists at
## all rather than being left to the first failed sentence.
##
## `checked` lands about a second after startup, which is *before* the pet has
## said anything — so a default that cannot run here is swapped out while nobody
## is listening, instead of the first nudge coming out half-spoken with an
## apology after it. That matters now that the default is VoxCPM:
## every machine without it would otherwise pay one botched line per run.
##
## It only speaks up when the backend that failed is the one in use. Discovery
## re-runs on every menu open, so reporting unconditionally would announce a
## service that has been down all along each time the user opens the menu for
## something else entirely.
func _on_backend_checked(healthy: bool, reason: String, backend: TTSBackend) -> void:
	var speaking := backend == _backend and backend != _os_voice
	if not healthy and speaking:
		_on_backend_broke(reason)
	var explained := not healthy and speaking
	if backend == _voxcpm and _select_after_check == BACKEND_VOXCPM:
		_select_after_check = ""
		if healthy:
			select_backend(BACKEND_VOXCPM)
		elif not explained:
			# The address dialog owns its own result, but a key submission does not.
			# Say why the saved key was refused instead of leaving only the generic
			# "saved" acknowledgement on screen.
			remarked.emit(reason)
			explained = true
	backend_checked.emit(healthy, reason, explained)
	if backend == _voxcpm and _voice_library_refreshing:
		_voice_library_refreshing = false
		voice_library_refreshed.emit(healthy, reason, _voxcpm.list_voices().size(), explained)


## The neural backend fell over. Falling back rather than going quiet, because
## silence is indistinguishable from the feature being switched off — and the
## choice is *not* persisted, so the next run tries again.
##
## **The reason is said whether or not there is anything to fall back from.**
## A backend can break while it is not the one speaking — the VoxCPM service is
## asked how it is on every menu open — and guarding the whole handler on "am I
## on it" would make those failures silent, which is how the user ends up with a
## disabled row and no idea why.
func _on_backend_broke(reason: String) -> void:
	if _backend == _os_voice:
		# Nothing to fall back *from*. The reason still has to be said.
		remarked.emit(reason)
		return
	_set_backend(BACKEND_OS)
	# Falling back to a voice that cannot speak here still leaves the pet silent,
	# and `_enabled` would go on claiming otherwise — 說話出聲 ticked in the menu
	# while nothing ever comes out.
	_enabled = _enabled and is_available()
	voice_changed.emit()
	# What happens next is said here rather than by the backend, because only this
	# knows whether there is a working voice to fall back to. Where speech was
	# simply switched off, nothing is added: a promise about a voice nobody asked
	# to hear is worse than saying only what broke.
	var next := ""
	if not is_available():
		next = "這台機器也沒有別的聲音可以用。"
	elif _enabled:
		next = "我先用系統的聲音講。"
	remarked.emit(reason + next)


# --- Which voice ---------------------------------------------------------------

## Every voice the speaking backend offers, by the id the user picks. Empty on a
## backend that has no such notion, which is what lets the menu ask without
## checking which one is in use first.
func list_voices() -> PackedStringArray:
	return _backend.list_voices() if _backend != null else PackedStringArray()


func active_voice() -> String:
	return _backend.active_voice() if _backend != null else ""


func select_voice(name: String) -> void:
	if _backend == null or name == _backend.active_voice():
		return
	_backend.select_voice(name)
	# Only the *next* sentence should be in the new voice; whatever is queued was
	# generated in the old one and would arrive as a jarring half-and-half.
	_backend.stop()
	voice_changed.emit()


# --- Speaking -----------------------------------------------------------------

func _on_chunk(text: String) -> void:
	if not _enabled:
		return
	_buffer += text
	var cut := _last_sentence_end(_buffer)
	if cut < 0:
		if _buffer.length() >= FLUSH_AFTER:
			_speak(_buffer)
			_buffer = ""
		return
	_speak(_buffer.substr(0, cut + 1))
	_buffer = _buffer.substr(cut + 1)


func _on_finished(_full_text: String) -> void:
	if _enabled and not _buffer.is_empty():
		_speak(_buffer)
	_buffer = ""


## A new message replaces whatever the pet was part-way through saying, the same
## way it replaces the in-flight reply.
func _on_user_said(_text: String) -> void:
	stop()


func _on_interrupted(_message: String) -> void:
	stop()


## Speak a complete companion-authored line. Presentation owns when a line is
## accepted rather than TTS listening to one particular source signal, so menu
## actions, games, work results and automatic nudges all follow the same rule.
func speak_line(text: String) -> void:
	if _enabled:
		_speak(text)


func _speak(text: String) -> void:
	var line := text.strip_edges()
	# Empty text is not harmless on every backend: measured, the neural engine
	# happily returns 1.6 seconds of audio for an empty string, because the chat
	# template it wraps the text in can never be short enough to trip its own
	# guard.
	if not line.is_empty() and _backend != null:
		_backend.speak(_respell(line))


## Swap 破音字 for homophones the engine cannot misread.
##
## **This is the only place the substituted text exists.** It is applied to the
## string on its way into a backend and nowhere else, so the bubble, the
## transcript, the memory store and the exported Markdown all keep what was
## actually written. A pet whose saved conversation said 「崇新」 because that is
## what it had to say out loud would be corrupting the record to fix the speaker.
##
## Applied to both backends. The substitutions are true homophones, so an engine
## that already read the word correctly reads the replacement identically; there
## is nothing here specific to the neural voice.
##
## Sequential and longest-first. Sequential means a replacement can in principle
## be matched again by a later rule — with a table of whole words that has not
## come up, and the alternative (one pass with a combined pattern) costs more
## than the problem.
## Every line the pet says aloud whose wording never changes.
##
## Streamed replies are written fresh every time. The reusable set is the current
## companion profile's nudge lines plus the fixed vision refusal, so changing a
## skin pack also changes what can be pre-rendered.
func fixed_lines() -> PackedStringArray:
	var lines := Nudger.fixed_lines()
	lines.append(VisionService.WALLPAPER_ONLY_LINE)
	return lines


## Render the fixed lines in advance so saying one costs a file read.
##
## **Every voice, not the selected one.** The cache is per voice, so rendering
## only the one that happens to be ticked means changing voice silently throws
## the whole benefit away and pays for the set again — and switching voice is
## something a user does while listening, which is exactly when a pause before
## every canned line is most obvious. The extra cost is bounded and paid once:
## seventeen nudges plus the vision refusal, at about a second a clip, and a
## second run only pays for whatever is new.
##
## Returns how many clips are being made, or -1 when the active backend cannot do
## it. The OS voice is not a failure to report: it has nothing to pre-render,
## since `DisplayServer.tts_speak()` has no file output and no model to load
## either.
func prerender_fixed_lines() -> int:
	if _backend == null or not _backend.is_available():
		return -1
	var spoken := PackedStringArray()
	for line in fixed_lines():
		# Through `_respell` exactly as speaking does, because that is the key
		# the lookup will use. Rendering the written form instead would cache
		# audio no lookup could ever find, and quietly render the whole feature
		# a no-op that still cost a minute of GPU.
		var text := _respell(line.strip_edges())
		if not text.is_empty():
			spoken.append(text)
	var voices := _backend.list_voices()
	# A backend with no notion of voices still has one cache to fill, and asking
	# for "" gets it rather than nothing.
	if voices.is_empty():
		_backend.forget_unlisted(spoken)
		return _backend.prerender(spoken)
	var total := 0
	for voice in voices:
		# Forgetting first, and only from here: this is the one caller that knows
		# `spoken` is the *complete* set, which is what makes pruning safe. See
		# `TTSBackend.forget_unlisted()`.
		_backend.forget_unlisted(spoken, voice)
		total += _backend.prerender(spoken, voice)
	return total


func _respell(line: String) -> String:
	for pair in _respellings:
		line = line.replace(pair[0], pair[1])
	return line


## Longest key first, so a rule on a whole word beats one on a fragment of it —
## 「重新」 has to win over any rule mentioning 「重」, or the specific correction
## never fires.
func _load_respellings() -> void:
	_respellings.clear()
	var raw := FileAccess.get_file_as_string(RESPELL_PATH)
	var data: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if typeof(data) != TYPE_DICTIONARY:
		if not raw.is_empty():
			push_warning("TTSService: %s is not readable JSON" % RESPELL_PATH)
		return
	var table: Variant = (data as Dictionary).get("replacements", {})
	if typeof(table) != TYPE_DICTIONARY:
		return
	for from: Variant in table:
		var to := str((table as Dictionary)[from])
		if str(from).is_empty() or to.is_empty():
			continue
		_respellings.append([str(from), to])
	_respellings.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0].length() > b[0].length())


func _last_sentence_end(text: String) -> int:
	var cut := -1
	for terminator in TERMINATORS:
		cut = maxi(cut, text.rfind(terminator))
	return cut
