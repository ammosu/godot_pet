extends Node
class_name TTSBackend

## What a voice has to look like. `TTSService` only ever sees this, so the
## operating system's voices and a local neural model are interchangeable — the
## same split `LLMProvider` makes between the mock and a real backend.
##
## The one thing this interface insists on that `LLMProvider` does not: a backend
## that cannot run here has to say **why**, in a finished sentence. A voice
## depends on things outside the repo — an engine, a model, a language pack — and
## every one of them is missing on some machine. "說話出聲（不能用）" is a dead end;
## naming the file that isn't there is something the user can act on.

## The backend stopped being usable part-way through a session: the helper died,
## the library went away, the device was taken. `reason` is a finished sentence.
## `TTSService` falls back to the operating system's voice rather than going
## quiet, because silence is indistinguishable from the feature being off.
signal broke(reason: String)

## Something worth saying that is *not* a reason to swap the voice out. A machine
## that synthesizes slower than it speaks still speaks; being switched back to a
## different voice without asking would be the more surprising outcome, so this
## is said once and the user decides.
signal warned(message: String)

## One pre-rendered line landed, or was given up on. `left` reaching zero ends
## the batch however it ended — including early, or the caller waits forever on
## a line nobody is still making.
signal line_prerendered(done: int, left: int)

## A discovery attempt finished — the answer to `is_available()` is now this
## run's, not the previous one's. Only backends that discover asynchronously emit
## it, and it is the difference between a wrong service address surfacing when it
## is typed and surfacing halfway through the pet's next sentence.
signal checked(healthy: bool, reason: String)


## Say one sentence. Called once per sentence as a reply streams in, so an
## implementation queues rather than interrupting — consecutive sentences have to
## run together the way `DisplayServer.tts_speak()` makes them.
func speak(_text: String) -> void:
	push_error("%s does not implement speak()" % get_script().resource_path)


## Drop everything queued and stop what is being said. Must be safe when idle.
func stop() -> void:
	pass


## Whether this backend can speak on this machine, right now. Called every time
## the menu is built, so it has to be cheap and must not start anything.
func is_available() -> bool:
	return false


## Empty when available; otherwise the sentence described above.
func unavailable_reason() -> String:
	return ""


## For the menu row, so which voice is actually in use is visible without a
## picker. This is how the Afrikaans bug stayed hidden for as long as it did —
## the row said the name the whole time and it was never doubted.
func voice_name() -> String:
	return ""


## Every voice this backend can speak in, by the id the user picks. Empty on a
## backend that has no such notion, which is what lets the menu ask without
## checking which one is in use first.
func list_voices() -> PackedStringArray:
	return PackedStringArray()


func active_voice() -> String:
	return ""


func select_voice(_name: String) -> void:
	pass


## Render lines into a cache so saying one later costs no synthesis, returning
## how many were actually asked for. Zero is the honest answer for a backend
## with nothing to gain from it — the OS voice loads no model and reaches no
## network, so there is nothing to save.
##
## `voice` empty means whichever is selected. It is a parameter rather than being
## read from the setting because the caller renders the *whole* library in one
## go, so the voice being rendered is usually not the one in the menu.
func prerender(_lines: PackedStringArray, _voice := "") -> int:
	return 0


## Drop anything cached for this voice that is not in `lines`, so a line whose
## wording changed does not leave its old audio behind forever.
##
## Deliberately not part of `prerender()`: the two mean different things and only
## this one can lose data, so a caller passing a partial set must not prune by
## accident. Empty `lines` does nothing.
func forget_unlisted(_lines: PackedStringArray, _voice := "") -> void:
	pass


## Release whatever this is holding: a child process, an audio device. Called
## when the backend is swapped away from as well as at shutdown, so it has to
## leave the object usable if `speak()` is called again afterwards.
func shutdown() -> void:
	pass


## Raw PCM16 mono as something the audio server will play.
##
## Shared because two backends now produce exactly this — the local helper's
## spool and a Pro-tier `pcm_*` download — and a second copy of four lines is
## how the two would end up disagreeing about `stereo` or the sample rate on
## some future edit.
static func pcm_stream(pcm: PackedByteArray, rate: int) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = pcm
	return stream
