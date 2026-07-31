extends Node

## Speaks the pet's lines. Which voice does the speaking is a backend — the
## operating system's own (`OSVoice`, no dependency at all) or a local neural
## model (`Qwen3Voice`, several) — swapped the same way `LLMService` swaps
## providers, so everything below this line is written once.
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
const BACKEND_QWEN3 := "qwen3"

## Something happened to the voice that the pet should say out loud. Carried on a
## signal rather than spoken here, because `pet.gd` is the only thing that
## decides how the pet reacts to anything.
signal remarked(text: String)
## The voice changed identity — a different backend, or a newly cloned voice —
## so the menu row naming it is stale.
signal voice_changed()

var _enabled := false
var _buffer := ""
var _backend_name := BACKEND_OS
var _backend: TTSBackend
var _os_voice: OSVoice
var _qwen3: Qwen3Voice
## [[from, to], …] sorted longest-first — see _load_respellings().
var _respellings: Array = []


func _ready() -> void:
	_load_respellings()
	_os_voice = OSVoice.new()
	_os_voice.name = "OSVoice"
	add_child(_os_voice)
	_qwen3 = Qwen3Voice.new()
	_qwen3.name = "Qwen3Voice"
	_qwen3.voice_cloned.connect(_on_voice_cloned)
	add_child(_qwen3)
	for backend in [_os_voice, _qwen3]:
		backend.broke.connect(_on_backend_broke)
		backend.warned.connect(func(message: String) -> void: remarked.emit(message))

	# Startup picks a backend but never writes one back — persisting what merely
	# happened to work on first run is how auto-detection gets permanently
	# defeated, the same rule LLMService.set_provider() follows. So a machine
	# without the engine falls back for this session only, and plugging it back
	# in restores the choice with nothing to re-select.
	_set_backend(str(Config.get_value("tts", "backend", BACKEND_OS)))
	_enabled = bool(Config.get_value("tts", "enabled", true)) and is_available()

	EventBus.reply_chunk.connect(_on_chunk)
	EventBus.reply_finished.connect(_on_finished)
	EventBus.reply_failed.connect(_on_interrupted)
	EventBus.user_said.connect(_on_user_said)
	EventBus.file_content_said.connect(_on_user_said)
	EventBus.pet_nudged.connect(_on_nudged)


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
	return PackedStringArray([BACKEND_OS, BACKEND_QWEN3])


func backend_label(id: String) -> String:
	return "系統語音" if id == BACKEND_OS else "本機模型（Qwen3）"


func get_backend_name() -> String:
	return _backend_name


## Re-run every backend's discovery. Called when the menu opens, so a library
## built or a model downloaded while the pet was running takes effect without a
## restart — the same courtesy the 造型 menu already extends to a pet pack
## installed by an external CLI.
##
## Note what it does *not* fix: an edit to `config.cfg`, which `Config` reads once
## at startup. See `Qwen3Voice.refresh()`.
##
## Cheap: a handful of `file_exists` calls, plus at most one short-lived process
## if no well-known Python is where it should be.
func rediscover() -> void:
	_qwen3.refresh()


func backend_is_available(id: String) -> bool:
	return _for(id).is_available()


func backend_unavailable_reason(id: String) -> String:
	return _for(id).unavailable_reason()


## Persisted, unlike `_set_backend` — this one is a choice.
func select_backend(id: String) -> void:
	if id == _backend_name:
		return
	if id == BACKEND_QWEN3:
		# Discovery is cached, so a user who has just written the path into
		# config.cfg would otherwise have to restart to be believed.
		_qwen3.refresh()
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
	return _qwen3 if id == BACKEND_QWEN3 else _os_voice


## The neural backend fell over. Falling back rather than going quiet, because
## silence is indistinguishable from the feature being switched off — and the
## choice is *not* persisted, so the next run tries again.
##
## **The reason is said whether or not there is anything to fall back from.**
## `clone_voice_from()` starts the helper regardless of which backend is active,
## and the OS voice is the shipped default — so the most likely time this fires
## is a 當我的聲音 on a machine where the engine cannot load, with the neural
## backend not selected. Guarding the whole handler on "am I on it" made that
## case fail in complete silence: the button did nothing, forever, with no line
## and no way to find out why.
func _on_backend_broke(reason: String) -> void:
	if _backend == _os_voice:
		# Nothing to fall back *from*: the helper was started by a clone while the
		# OS voice was active. The reason still has to be said — see above.
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


# --- The cloned voice ---------------------------------------------------------

func can_clone_voice() -> bool:
	return _qwen3 != null and _qwen3.is_available()


func has_cloned_voice() -> bool:
	return _qwen3 != null and _qwen3.has_cloned_voice()


## Every voice the local engine can speak in, by name. Empty on a backend that
## has no such notion, which is what lets the menu ask without checking first.
func list_voices() -> PackedStringArray:
	return _qwen3.list_voices() if _qwen3 != null else PackedStringArray()


func active_voice() -> String:
	return _qwen3.active_voice() if _qwen3 != null else ""


func select_voice(name: String) -> void:
	if _qwen3 == null or name == _qwen3.active_voice():
		return
	_qwen3.set_active_voice(name)
	# Only the *next* sentence should be in the new voice; whatever is queued was
	# generated in the old one and would arrive as a jarring half-and-half.
	if _backend == _qwen3:
		_qwen3.stop()
	voice_changed.emit()


func voices_folder() -> String:
	return _qwen3.voices_folder() if _qwen3 != null else ""


## Take the pet's voice from a recording — in practice one RecorderService made.
## Answers on `remarked` either way, via _on_voice_cloned.
func clone_voice_from(wav_path: String, name: String) -> void:
	if not can_clone_voice():
		remarked.emit(_qwen3.unavailable_reason())
		return
	_qwen3.clone_from(wav_path, name)


func clear_cloned_voice() -> void:
	if _qwen3 == null:
		return
	_qwen3.clear_cloned_voice()
	voice_changed.emit()


func _on_voice_cloned(ok: bool, message: String) -> void:
	if ok:
		# Cloning is only useful if you are then using it, and the user who just
		# handed over a recording plainly wants to hear it.
		if _backend_name != BACKEND_QWEN3:
			select_backend(BACKEND_QWEN3)
		if not _enabled:
			set_enabled(true)
		voice_changed.emit()
	if _backend != _qwen3:
		# Cloning starts the helper whichever backend is active, so a clone that
		# failed — or one that succeeded and still could not be switched to —
		# leaves a process nobody owns holding the model and a couple of GB of
		# VRAM. Its own idle timer would get there eventually; five minutes is a
		# long time to hold a graphics card you were not asked for.
		_qwen3.shutdown()
	remarked.emit(message)


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


func _on_nudged(_emotion: String, text: String) -> void:
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
