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
const LANGUAGES := ["zh-TW", "zh-HK", "yue-HK", "zh-CN", "zh"]

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
	# Nothing matched, so the voice almost certainly can't pronounce the pet's
	# language — but a wrong voice still beats silence, and it's one config key
	# to fix.
	var any := DisplayServer.tts_get_voices()
	return "" if any.is_empty() else str(any[0].get("id", ""))


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
