extends Node

## Records one explicitly-started microphone turn, sends that WAV to OpenAI's
## transcription endpoint, and returns text to the existing chat path. Unlike
## RecorderService, this audio is temporary and never enters the outbox.

signal tick(elapsed_text: String)
signal transcribing
signal transcribed(text: String)
signal failed(reason: String)

const BUS_NAME := "SpeechInput"
const ENDPOINT := "https://api.openai.com/v1/audio/transcriptions"
const MODEL := "gpt-4o-mini-transcribe"
const KEY_NAME := "OPENAI_API_KEY"
const MIN_SECONDS := 0.6
const MAX_SECONDS := 60.0
const TEMP_PATH := "user://speech_input.wav"

var _bus := -1
var _player: AudioStreamPlayer
var _effect: AudioEffectRecord
var _request: HTTPRequest
var _started_at := 0.0
var _ticked := -1
var _transcribing := false


func _ready() -> void:
	set_process(false)
	if not bool(ProjectSettings.get_setting("audio/driver/enable_input", false)):
		return
	_bus = AudioServer.bus_count
	AudioServer.add_bus(_bus)
	AudioServer.set_bus_name(_bus, BUS_NAME)
	AudioServer.set_bus_mute(_bus, true)
	_effect = AudioEffectRecord.new()
	_effect.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(_bus, _effect)
	_player = AudioStreamPlayer.new()
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = BUS_NAME
	add_child(_player)
	_request = HTTPRequest.new()
	_request.timeout = 45.0
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


func _exit_tree() -> void:
	if is_listening():
		_discard_capture()


func is_supported() -> bool:
	return _player != null and _request != null


func is_listening() -> bool:
	return _effect != null and _effect.is_recording_active()


func is_transcribing() -> bool:
	return _transcribing


func is_busy() -> bool:
	return is_listening() or _transcribing


func elapsed() -> float:
	return (Time.get_ticks_msec() / 1000.0) - _started_at if is_listening() else 0.0


func elapsed_text() -> String:
	var seconds := int(elapsed())
	return "%d:%02d" % [seconds / 60, seconds % 60]


func start() -> bool:
	if not is_supported() or is_busy() or RecorderService.is_recording():
		return false
	if Config.get_secret(KEY_NAME).is_empty():
		failed.emit("語音輸入需要 OpenAI API key；右鍵的「語言模型」可以設定。")
		return false
	TTSService.stop()
	_player.play()
	_effect.set_recording_active(true)
	_started_at = Time.get_ticks_msec() / 1000.0
	_ticked = -1
	set_process(true)
	return true


func stop_and_transcribe() -> void:
	if not is_listening():
		return
	var seconds := elapsed()
	var stream := _effect.get_recording()
	_effect.set_recording_active(false)
	_player.stop()
	set_process(false)
	if seconds < MIN_SECONDS:
		failed.emit("太短了，我還沒聽清楚就停了。")
		return
	if stream == null or stream.data.is_empty():
		failed.emit("我沒有收到麥克風的聲音；請檢查輸入裝置與系統權限。")
		return
	var err := stream.save_to_wav(TEMP_PATH)
	if err != OK:
		failed.emit("聲音暫存失敗了，這次沒有送出去。")
		return
	var wav := FileAccess.get_file_as_bytes(TEMP_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	if wav.is_empty():
		failed.emit("聲音暫存是空的，這次沒有送出去。")
		return
	_send(wav)


func cancel() -> void:
	if is_listening():
		_discard_capture()
	elif _transcribing:
		_request.cancel_request()
		_transcribing = false


func _discard_capture() -> void:
	_effect.set_recording_active(false)
	_player.stop()
	set_process(false)


func _process(_delta: float) -> void:
	if not is_listening():
		return
	if elapsed() >= MAX_SECONDS:
		stop_and_transcribe()
		return
	var whole := int(elapsed())
	if whole != _ticked:
		_ticked = whole
		tick.emit(elapsed_text())


func _send(wav: PackedByteArray) -> void:
	var boundary := "----GodotPet%08x" % Time.get_ticks_msec()
	var body := multipart_body(wav, boundary)
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % Config.get_secret(KEY_NAME),
		"Content-Type: multipart/form-data; boundary=%s" % boundary,
	])
	var err := _request.request_raw(ENDPOINT, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		failed.emit("語音辨識送不出去（%d）。" % err)
		return
	_transcribing = true
	transcribing.emit()


static func multipart_body(wav: PackedByteArray, boundary: String) -> PackedByteArray:
	var body := PackedByteArray()
	_append_text(body, "--%s\r\n" % boundary)
	_append_text(body, "Content-Disposition: form-data; name=\"model\"\r\n\r\n")
	_append_text(body, MODEL + "\r\n")
	_append_text(body, "--%s\r\n" % boundary)
	_append_text(body, "Content-Disposition: form-data; name=\"language\"\r\n\r\n")
	_append_text(body, "zh\r\n")
	_append_text(body, "--%s\r\n" % boundary)
	_append_text(body, "Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
	_append_text(body, "Content-Type: audio/wav\r\n\r\n")
	body.append_array(wav)
	_append_text(body, "\r\n--%s--\r\n" % boundary)
	return body


static func _append_text(bytes: PackedByteArray, text: String) -> void:
	bytes.append_array(text.to_utf8_buffer())


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_transcribing = false
	if result != HTTPRequest.RESULT_SUCCESS:
		failed.emit("語音辨識連線失敗（%d）。" % result)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if response_code < 200 or response_code >= 300:
		var reason := "HTTP %d" % response_code
		if typeof(parsed) == TYPE_DICTIONARY:
			var error: Variant = parsed.get("error", {})
			if typeof(error) == TYPE_DICTIONARY:
				reason = str(error.get("message", reason))
		failed.emit("語音辨識失敗：%s" % reason)
		return
	if typeof(parsed) != TYPE_DICTIONARY:
		failed.emit("語音辨識回傳了看不懂的內容。")
		return
	var text := str(parsed.get("text", "")).strip_edges()
	if text.is_empty():
		failed.emit("我沒有聽出可以送出的文字。")
		return
	transcribed.emit(text)
