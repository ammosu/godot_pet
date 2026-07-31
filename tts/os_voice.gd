extends TTSBackend
class_name OSVoice

## The operating system's own voices, through `DisplayServer.tts_speak()`. No
## API, no cost, no network, and nothing to install on a machine that already has
## a voice for the language. On macOS this is the same engine as `say`; on Linux
## it is speech-dispatcher, which in practice means espeak-ng.
##
## This is the backend that must always be *tried*, because it is the only one
## with no external dependency at all. It is not the only one that can fail: a
## machine with no voice for the pet's language leaves it unavailable, which is
## the whole point of `unavailable_reason()`.

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

var _voice := ""


func _ready() -> void:
	_voice = _pick_voice()


func is_available() -> bool:
	return not _voice.is_empty()


func unavailable_reason() -> String:
	if is_available():
		return ""
	if DisplayServer.tts_get_voices().is_empty():
		return "這台機器沒有安裝任何語音。"
	return "這台機器的語音都不會讀中文。"


func voice_name() -> String:
	for voice in DisplayServer.tts_get_voices():
		if str(voice.get("id", "")) == _voice:
			return str(voice.get("name", _voice))
	return _voice


## Queued rather than interrupting, so consecutive sentences run together — the
## engine does this for us, which is why this backend needs no queue of its own.
func speak(text: String) -> void:
	if is_available():
		DisplayServer.tts_speak(text, _voice, 50, PITCH)


func stop() -> void:
	if is_available():
		DisplayServer.tts_stop()


func shutdown() -> void:
	stop()


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
		push_warning(("OSVoice: no installed voice speaks %s, so speech is "
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
