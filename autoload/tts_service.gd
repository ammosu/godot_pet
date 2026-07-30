extends Node

## Speaks the pet's lines using the operating system's own voices — no API, no
## cost, no network. On macOS that's the same engine as `say`.
##
## Sentences are spoken as they arrive rather than after the whole reply lands,
## so the pet starts talking at roughly the moment the bubble starts typing.

## Anything that ends a spoken sentence, in either script.
const TERMINATORS := ["。", "！", "？", "…", "\n", ".", "!", "?"]
## Speak an unterminated run once it gets this long, so a reply with no
## punctuation doesn't stay silent until the very end.
const FLUSH_AFTER := 40

## Preference order when picking a voice automatically. The shipped persona is
## Traditional Chinese, so those come before the machine's own locale; rewrite
## prompts/persona.md in another language and you'll want to set `voice` under
## `[tts]` in config.cfg to match.
##
## The last two are not BCP 47 typos. macOS reports Chinese voices as `zh-TW`
## and friends, but Linux goes through speech-dispatcher and espeak-ng, which
## names its languages with ISO 639-3 codes — Mandarin is `cmn`, Cantonese is
## `yue`, and there is no `zh` anything. Measured on Ubuntu 24.04: of 13362
## voices, `zh-TW`, `zh-HK`, `yue-HK`, `zh-CN` and `zh` all matched **zero**, and
## `cmn` matched 204. See _pick_voice() for what that silently cost.
const LANGUAGES := ["zh-TW", "zh-HK", "yue-HK", "zh-CN", "zh", "cmn", "yue"]

## A little above natural pitch reads as small and animated.
const PITCH := 1.15

var _enabled := false
var _voice := ""
var _buffer := ""


func _ready() -> void:
	_voice = _pick_voice()
	_enabled = bool(Config.get_value("tts", "enabled", true)) and is_available()

	EventBus.reply_chunk.connect(_on_chunk)
	EventBus.reply_finished.connect(_on_finished)
	EventBus.reply_failed.connect(_on_interrupted)
	EventBus.user_said.connect(_on_user_said)
	EventBus.file_content_said.connect(_on_user_said)
	EventBus.pet_nudged.connect(_on_nudged)


func _exit_tree() -> void:
	if is_available():
		DisplayServer.tts_stop()


## False when the platform has no speech synthesis, or no voices installed.
func is_available() -> bool:
	return not _voice.is_empty()


func is_enabled() -> bool:
	return _enabled


func set_enabled(enabled: bool) -> void:
	_enabled = enabled and is_available()
	Config.set_value("tts", "enabled", _enabled)
	if not _enabled:
		stop()


func get_voice_name() -> String:
	for voice in DisplayServer.tts_get_voices():
		if str(voice.get("id", "")) == _voice:
			return str(voice.get("name", _voice))
	return _voice


func stop() -> void:
	_buffer = ""
	if is_available():
		DisplayServer.tts_stop()


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


## Queued rather than interrupting, so consecutive sentences run together.
func _speak(text: String) -> void:
	var line := text.strip_edges()
	if not line.is_empty():
		DisplayServer.tts_speak(line, _voice, 50, PITCH)


func _last_sentence_end(text: String) -> int:
	var cut := -1
	for terminator in TERMINATORS:
		cut = maxi(cut, text.rfind(terminator))
	return cut


# --- Voice --------------------------------------------------------------------

## Override by setting `voice` under `[tts]` in config.cfg to an id from
## DisplayServer.tts_get_voices().
func _pick_voice() -> String:
	var configured := str(Config.get_value("tts", "voice", ""))
	if not configured.is_empty():
		return configured
	for language in _preferred_languages():
		var voices := DisplayServer.tts_get_voices_for_language(language)
		if not voices.is_empty():
			return voices[0]
	# Nothing matched, so nothing installed here can pronounce the pet's language.
	# This used to fall back to whichever voice came first, on the grounds that a
	# wrong voice beats silence. It does not: the first of speech-dispatcher's
	# 13362 voices is *Afrikaans*, and an Afrikaans voice fed Traditional Chinese
	# emits a continuous run of gibberish syllables out of nowhere every time the
	# pet nudges — which reads as the app malfunctioning, not as a bad accent. The
	# menu row said 說話出聲（Afrikaans）the whole time and nobody looked.
	if not DisplayServer.tts_get_voices().is_empty():
		var wanted := ", ".join(_preferred_languages())
		push_warning(("TTSService: no installed voice speaks %s, so speech is "
			+ "off. Set `voice` under [tts] in config.cfg to override.") % wanted)
	return ""


## Godot reports voice languages as BCP 47 with a hyphen ("zh-TW") and matches
## on a plain prefix, while OS.get_locale() uses an underscore ("zh_TW") — so an
## underscore here silently matches nothing and the fallback picks whichever
## voice happens to be first.
func _preferred_languages() -> PackedStringArray:
	var languages := PackedStringArray(LANGUAGES)
	var locale := OS.get_locale().replace("_", "-")
	languages.append(locale)
	languages.append(locale.get_slice("-", 0))
	return languages
