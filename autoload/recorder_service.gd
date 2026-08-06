extends Node

## Records the microphone to a file the user can find, and nothing else.
##
## Deliberately **not** the voice input PLAN.md's Phase 8 designed. That one turns
## speech into text and sends the audio to a transcription API; this one keeps a
## recording. Nothing here reaches the network, no provider is involved, and the
## file never leaves the machine — which is why it needs none of the consent
## machinery `VisionService` carries, and why it works with the LLM switched off
## entirely, like the transcript export.
##
## Where it lands is `OutboxService`'s folder, because that is already "the one
## place the pet may write to, that you can actually open". A recording is the
## first thing in there the pet did not compose out of text.

## Godot mixes into buses by name; this one is created in code rather than in a
## saved bus layout, so there is no .tres that can go missing and no default
## layout to keep in step with it.
const BUS_NAME := "Record"

## A forgotten recording is the failure mode here, not a long one. At the mixer's
## 44.1 kHz stereo 16-bit this can reach about 600 MB, which is a lot for a folder
## meant to be browsed — so it stops itself after an hour and says so, rather
## than filling the disk while the user is in another app.
const MAX_SECONDS := 3600.0

## Below this it is a misclick, not a recording. Saving it would leave a 0-second
## file to delete by hand.
const MIN_SECONDS := 0.6

## Composed here, never taken from anywhere untrusted — but it still goes through
## OutboxService.sanitise_name() like everything else, since the guarantee is
## worth more than the exception.
const NAME_PREFIX := "錄音"

## Recording ended and the file is on disk.
signal saved(file_name: String, seconds: float)
## It didn't. `reason` is a finished sentence for the pet to say.
signal failed(reason: String)
## Another whole second has passed. A clock on screen has to keep its own time
## somewhere, and it cannot be `pet.gd`'s `_process` — that one is switched off
## except where the passthrough mask clips rendering, so on Linux and macOS it
## would simply never tick.
signal tick(elapsed_text: String)

var _bus := -1
var _player: AudioStreamPlayer
var _effect: AudioEffectRecord
var _started_at := 0.0
var _ticked := -1


func _ready() -> void:
	# Only ticks while the microphone is open; an autoload polling every frame for
	# the whole life of the app to answer "no" is the kind of cost this project
	# keeps refusing elsewhere.
	set_process(false)
	if not _input_allowed():
		return

	_bus = AudioServer.bus_count
	AudioServer.add_bus(_bus)
	AudioServer.set_bus_name(_bus, BUS_NAME)
	# The microphone has to be *played* to reach an effect chain at all, and a
	# live microphone routed to the speakers is feedback. Muting is safe because
	# a bus's mute is its output fader, applied after its effects have run — the
	# recording is taken from inside the chain and is unaffected. Verified by
	# recording a known tone and measuring the peak in the saved file, since the
	# failure here would be a silent WAV rather than an error.
	AudioServer.set_bus_mute(_bus, true)

	_effect = AudioEffectRecord.new()
	_effect.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(_bus, _effect)

	_player = AudioStreamPlayer.new()
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = BUS_NAME
	add_child(_player)


## Save rather than discard. Quitting mid-recording is the one moment where
## throwing the audio away is unrecoverable and keeping it costs a file.
func _exit_tree() -> void:
	if is_recording():
		stop()


## False where the engine was built or configured without audio capture. The menu
## row is disabled rather than hidden, the same call the 依你的節奏搭話 and
## 幫我做事 rows make.
func is_supported() -> bool:
	return _player != null


func is_recording() -> bool:
	return _effect != null and _effect.is_recording_active()


func elapsed() -> float:
	if not is_recording():
		return 0.0
	return (Time.get_ticks_msec() / 1000.0) - _started_at


## m:ss, for the menu row and the indicator over the pet's head.
func elapsed_text() -> String:
	var seconds := int(elapsed())
	return "%d:%02d" % [seconds / 60, seconds % 60]


func start() -> bool:
	if not is_supported() or is_recording():
		return false
	# Opening the capture device is what makes the system's "microphone in use"
	# indicator appear, so it happens here and not at startup.
	_player.play()
	_effect.set_recording_active(true)
	_started_at = Time.get_ticks_msec() / 1000.0
	_ticked = -1
	set_process(true)
	return true


## Ends the recording and writes it. Returns the filename, or "" — in which case
## `failed` has already carried the reason.
func stop() -> String:
	if not is_recording():
		return ""
	var seconds := elapsed()
	var stream := _effect.get_recording()
	_effect.set_recording_active(false)
	# Stopping the player is what closes the capture device again, and with it the
	# system's "microphone in use" indicator.
	_player.stop()
	set_process(false)

	if seconds < MIN_SECONDS:
		failed.emit("太短了啦，我還沒聽到什麼就停了。")
		return ""
	if stream == null or stream.data.is_empty():
		# The device was there and gave us nothing: no microphone plugged into
		# the input that is currently selected, or the OS refused without saying
		# so. Naming both beats a bare "failed".
		failed.emit("咦，我什麼都沒錄到欸，是不是麥克風沒接、或是系統沒讓我用？")
		return ""

	var slot := OutboxService.reserve("%s %s.wav" % [NAME_PREFIX, _stamp()])
	if slot.is_empty():
		failed.emit("錄到了，可是存不進資料夾……")
		return ""

	var err := stream.save_to_wav(str(slot["path"]))
	if err != OK:
		push_warning("RecorderService: cannot write '%s' (%d)" % [slot["path"], err])
		failed.emit("錄到了，可是寫檔失敗了……")
		return ""

	var file_name := str(slot["name"])
	saved.emit(file_name, seconds)
	return file_name


func _process(_delta: float) -> void:
	if not is_recording():
		return
	if elapsed() >= MAX_SECONDS:
		stop()
		return
	var whole := int(elapsed())
	if whole != _ticked:
		_ticked = whole
		tick.emit(elapsed_text())


## Local time, and sortable — the folder is browsed by eye, so the name has to be
## the thing that tells two recordings apart.
func _stamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d%02d%02d" % [
		t["year"], t["month"], t["day"], t["hour"], t["minute"], t["second"],
	]


func _input_allowed() -> bool:
	return bool(ProjectSettings.get_setting("audio/driver/enable_input", false))
