class_name MicrophoneFlow
extends Node

## The two things that open the microphone: a local recording saved to the
## outbox, and a voice turn sent for transcription and then said as chat. One at
## a time, each with its own way to stop it.
##
## Speaks only through `said`. The indicator is the speech bubble held open, which
## belongs to pet.gd, so it is asked for with `holding` / `holding_ended` rather
## than drawn from here; the same goes for the pet standing still to listen
## (`attending`) and for a transcription becoming the user's turn (`transcribed`).

## Every line here answers something the user just did, so all are said with
## `unprompted = false` and none is recorded.
signal said(emotion: String, text: String, record: bool, unprompted: bool)
## Hold the bubble open with this text, and a button labelled `action` if given.
signal holding(message: String, action: String)
signal holding_ended
## The pet should stand still and attend. TALK ends by itself when the closing
## line fades, so nothing has to undo this.
signal attending
signal transcribed(text: String)
## A recording landed in the outbox.
signal saved

var _speech_consent: ConfirmationDialog


func setup(speech_consent: ConfirmationDialog) -> void:
	_speech_consent = speech_consent
	_speech_consent.confirmed.connect(_start_speech_input)
	RecorderService.tick.connect(_on_recording_tick)
	RecorderService.saved.connect(_on_recording_saved)
	RecorderService.failed.connect(_on_recording_failed)
	SpeechInputService.tick.connect(_on_speech_input_tick)
	SpeechInputService.transcribing.connect(_on_speech_transcribing)
	SpeechInputService.transcribed.connect(_on_speech_transcribed)
	SpeechInputService.failed.connect(_on_speech_input_failed)


func _say(emotion: String, text: String) -> void:
	said.emit(emotion, text, false, false)


## No dialog, and the reasoning is worth keeping because a microphone looks like
## it should have one. The consent dialogs in this app all guard something that
## happens *without* a fresh human action right now: a background poll
## (PresenceService), or something the model asked for (VisionService, the work
## tag). This is none of those — it happens because the user just clicked 錄一段話,
## it announces itself with an indicator that stays up for as long as the
## microphone is open, nothing is sent anywhere, and stopping is one click in the
## place they started it. Asking "are you sure?" about the thing they just chose
## is the shape of consent, not the substance.
##
## What was genuinely missing is *where it went*, and the honest place to answer
## that is when the file exists — see _on_recording_saved().
func toggle_recording() -> void:
	if SpeechInputService.is_busy():
		_say("neutral", "我正在聽你說話，等這次結束再錄音喔。")
		return
	if RecorderService.is_recording():
		RecorderService.stop()
		return
	if not RecorderService.start():
		return
	# Stand still and attend. TALK is held open by the indicator being up and ends
	# when the closing line finally fades, so nothing has to remember to undo it.
	attending.emit()
	_on_recording_tick(RecorderService.elapsed_text())


## The indicator. It has to answer two questions for as long as it is up — that
## the microphone is live, and how to make it stop — because between those two it
## is the only thing on screen saying so.
func _on_recording_tick(elapsed_text: String) -> void:
	holding.emit("● 錄音中 %s" % elapsed_text, "停止錄音")


## Dedicated rather than routed through toggle_recording(): if the one-hour
## cap ends between the pointer going down and the signal arriving, a late click
## must do nothing instead of immediately starting a new recording.
func on_holding_action_pressed() -> void:
	if SpeechInputService.is_listening():
		SpeechInputService.stop_and_transcribe()
	elif RecorderService.is_recording():
		RecorderService.stop()


func toggle_speech_input() -> void:
	if SpeechInputService.is_listening():
		SpeechInputService.stop_and_transcribe()
		return
	if SpeechInputService.is_transcribing():
		return
	if RecorderService.is_recording():
		_say("neutral", "我還在錄音，先停下來才能聽你說話。")
		return
	if not bool(Config.get_value("speech_input", "consented", false)):
		_speech_consent.popup_centered()
		return
	_start_speech_input()


func _start_speech_input() -> void:
	Config.set_value("speech_input", "consented", true)
	if not SpeechInputService.start():
		return
	attending.emit()
	_on_speech_input_tick(SpeechInputService.elapsed_text())


func _on_speech_input_tick(elapsed_text: String) -> void:
	holding.emit("● 正在聽 %s\n說完按下面送出" % elapsed_text, "停止並送出")


func _on_speech_transcribing() -> void:
	holding.emit("正在把聲音變成文字…", "")


func _on_speech_transcribed(text: String) -> void:
	holding_ended.emit()
	transcribed.emit(text)


func _on_speech_input_failed(reason: String) -> void:
	holding_ended.emit()
	_say("sad", reason)


func _on_recording_saved(file_name: String, seconds: float) -> void:
	var line := "錄好了！叫「%s」，在「我做的東西」裡面。" % file_name
	if seconds >= RecorderService.MAX_SECONDS - 1.0:
		# Otherwise a recording that hit the cap reads as the app having crashed
		# out of it.
		line = "錄滿 %d 分鐘我就先停了，存成「%s」，在「我做的東西」裡面。" \
			% [int(RecorderService.MAX_SECONDS / 60.0), file_name]
	if not bool(Config.get_value("recorder", "told_where", false)):
		# Once, at the moment it means something: the file exists and they are
		# about to go looking for it. Not a dialog before the fact, which would be
		# asking a question that has one answer.
		line += "只會存在你自己的電腦，不會送去任何地方喔。"
		Config.set_value("recorder", "told_where", true)
	_say("happy", line)
	saved.emit()


func _on_recording_failed(reason: String) -> void:
	_say("sad", reason)
