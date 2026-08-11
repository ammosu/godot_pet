extends Node

## Records a local WAV from the microphone, macOS system audio, or both.
## Nothing reaches the network. System audio is captured by the small native
## ScreenCaptureKit helper under native/macos, then mixed with Godot's microphone
## capture after recording stops.

const BUS_NAME := "Record"
const MAX_SECONDS := 3600.0
const MIN_SECONDS := 0.6
const NAME_PREFIX := "錄音"

const CONFIG_SECTION := "recorder"
const CONFIG_MICROPHONE := "microphone"
const CONFIG_SYSTEM_AUDIO := "system_audio"
const DEFAULT_MICROPHONE := true
const DEFAULT_SYSTEM_AUDIO := true

const HELPER_RESOURCE := "res://native/macos/system_audio_capture.bin"
const HELPER_FOLDER := "user://helpers"
const HELPER_FILE := "system_audio_capture"
const TEMP_FOLDER := "user://recording_tmp"
const HELPER_STOP_TIMEOUT_MSEC := 3000

signal saved(file_name: String, seconds: float, note: String)
signal failed(reason: String)
signal tick(elapsed_text: String)

var _bus := -1
var _player: AudioStreamPlayer
var _effect: AudioEffectRecord
var _started_at := 0.0
var _ticked := -1
var _recording := false
var _session_microphone := false
var _session_system_audio := false
var _session_system_error := ""
var _helper_path := ""
var _helper_pid := -1
var _system_wav_path := ""
var _stop_marker_path := ""
var _ready_marker_path := ""
var _error_marker_path := ""


func _ready() -> void:
	set_process(false)
	if _input_allowed():
		_setup_microphone()
	if OS.get_name() == "macOS":
		_helper_path = _install_system_audio_helper()


func _setup_microphone() -> void:
	_bus = AudioServer.bus_count
	AudioServer.add_bus(_bus)
	AudioServer.set_bus_name(_bus, BUS_NAME)
	# The microphone must play to reach the effect chain. Muting the bus prevents
	# feedback; bus mute is applied after effects, so AudioEffectRecord still sees
	# the signal.
	AudioServer.set_bus_mute(_bus, true)

	_effect = AudioEffectRecord.new()
	_effect.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(_bus, _effect)

	_player = AudioStreamPlayer.new()
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = BUS_NAME
	add_child(_player)


func _exit_tree() -> void:
	if is_recording():
		stop()


func is_supported() -> bool:
	return microphone_is_supported() or system_audio_is_supported()


func microphone_is_supported() -> bool:
	return _player != null


func system_audio_is_supported() -> bool:
	return OS.get_name() == "macOS" and not _helper_path.is_empty()


func records_microphone() -> bool:
	return bool(Config.get_value(
		CONFIG_SECTION, CONFIG_MICROPHONE, DEFAULT_MICROPHONE))


func records_system_audio() -> bool:
	return bool(Config.get_value(
		CONFIG_SECTION, CONFIG_SYSTEM_AUDIO, DEFAULT_SYSTEM_AUDIO))


## Returns false when the change would leave the recorder with no source.
func set_records_microphone(enabled: bool) -> bool:
	if is_recording() or (not enabled and not records_system_audio()):
		return false
	Config.set_value(CONFIG_SECTION, CONFIG_MICROPHONE, enabled)
	return true


## Returns false when the change would leave the recorder with no source.
func set_records_system_audio(enabled: bool) -> bool:
	if is_recording() or (not enabled and not records_microphone()):
		return false
	Config.set_value(CONFIG_SECTION, CONFIG_SYSTEM_AUDIO, enabled)
	return true


func is_recording() -> bool:
	return _recording


func elapsed() -> float:
	if not is_recording():
		return 0.0
	return (Time.get_ticks_msec() / 1000.0) - _started_at


func elapsed_text() -> String:
	var seconds := int(elapsed())
	return "%d:%02d" % [seconds / 60, seconds % 60]


func active_sources_text() -> String:
	if _session_microphone and _session_system_audio:
		return "麥克風＋系統聲音"
	if _session_system_audio:
		return "系統聲音"
	return "麥克風"


func selected_sources_text() -> String:
	if records_microphone() and records_system_audio():
		return "麥克風＋系統聲音"
	if records_system_audio():
		return "系統聲音"
	return "麥克風"


func start() -> bool:
	if not is_supported() or is_recording():
		return false

	_session_microphone = records_microphone() and microphone_is_supported()
	_session_system_audio = records_system_audio() and system_audio_is_supported()
	_session_system_error = ""
	if not _session_microphone and not _session_system_audio:
		failed.emit("目前選的錄音來源在這台機器上不能使用。")
		return false

	_started_at = Time.get_ticks_msec() / 1000.0
	if _session_system_audio and not _start_system_audio_helper():
		_session_system_audio = false
		_session_system_error = "系統聲音錄音程序沒有啟動"
		if not _session_microphone:
			failed.emit("系統聲音錄音沒有啟動，請確認 macOS 已允許螢幕與系統音訊錄製。")
			return false

	if _session_microphone:
		_player.play()
		_effect.set_recording_active(true)

	_recording = true
	_ticked = -1
	set_process(true)
	return true


## Ends the recording and writes it. If one of two requested sources failed, the
## usable source is still preserved and `note` tells the pet to say what was
## missing instead of silently presenting a partial file as complete.
func stop() -> String:
	if not is_recording():
		return ""
	var seconds := elapsed()
	var microphone_stream: AudioStreamWAV
	if _session_microphone:
		microphone_stream = _effect.get_recording()
		_effect.set_recording_active(false)
		_player.stop()

	_recording = false
	set_process(false)

	var system_stream: AudioStreamWAV
	var system_error := _session_system_error
	if _session_system_audio:
		system_error = _finish_system_audio_helper()
		if system_error.is_empty():
			if not FileAccess.file_exists(_system_wav_path):
				system_error = "系統音訊擷取沒有產生聲音"
			else:
				system_stream = AudioStreamWAV.load_from_file(_system_wav_path)
				if system_stream == null or system_stream.data.is_empty():
					system_error = "系統音訊擷取沒有產生聲音"
	_cleanup_system_audio_session()

	if seconds < MIN_SECONDS:
		failed.emit("太短了啦，我還沒聽到什麼就停了。")
		return ""

	if microphone_stream != null and system_stream != null \
			and not _streams_are_compatible(microphone_stream, system_stream):
		system_error = "系統聲音格式和麥克風不相容"
		system_stream = null
	var stream := _combine_streams(microphone_stream, system_stream)
	if stream == null or stream.data.is_empty():
		var detail := ""
		if not system_error.is_empty():
			detail = "（%s）" % system_error
		failed.emit("咦，我什麼都沒錄到欸%s，請檢查錄音權限和目前選的來源。" % detail)
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

	var note := ""
	if not system_error.is_empty():
		note = "不過系統聲音沒有錄到：%s。" % system_error
	var file_name := str(slot["name"])
	saved.emit(file_name, seconds, note)
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


func _combine_streams(
		microphone: AudioStreamWAV, system_audio: AudioStreamWAV) -> AudioStreamWAV:
	if microphone == null:
		return system_audio
	if system_audio == null:
		return microphone
	if not _streams_are_compatible(microphone, system_audio):
		push_warning("RecorderService: incompatible microphone and system WAV formats")
		return microphone

	var mixed_data := PackedByteArray()
	var byte_count := maxi(microphone.data.size(), system_audio.data.size())
	# A complete sample is two bytes. Both producers write complete PCM frames,
	# but rounding down keeps a damaged temporary tail from becoming an overrun.
	byte_count -= byte_count % 2
	mixed_data.resize(byte_count)
	for offset in range(0, byte_count, 2):
		var mic_sample := _sample_at(microphone.data, offset)
		var system_sample := _sample_at(system_audio.data, offset)
		# 0.75 keeps either source present without halving quiet speech. Saturation
		# protects the WAV when both sides are loud at the same instant.
		var sample := clampi(int((mic_sample + system_sample) * 0.75), -32768, 32767)
		mixed_data.encode_s16(offset, sample)

	var result := AudioStreamWAV.new()
	result.format = AudioStreamWAV.FORMAT_16_BITS
	result.mix_rate = microphone.mix_rate
	result.stereo = microphone.stereo
	result.data = mixed_data
	return result


func _streams_are_compatible(first: AudioStreamWAV, second: AudioStreamWAV) -> bool:
	return first.format == AudioStreamWAV.FORMAT_16_BITS \
		and second.format == AudioStreamWAV.FORMAT_16_BITS \
		and first.mix_rate == second.mix_rate \
		and first.stereo == second.stereo


func _sample_at(data: PackedByteArray, offset: int) -> int:
	if offset + 1 >= data.size():
		return 0
	return data.decode_s16(offset)


func _start_system_audio_helper() -> bool:
	var temp_absolute := ProjectSettings.globalize_path(TEMP_FOLDER)
	if DirAccess.make_dir_recursive_absolute(temp_absolute) != OK:
		return false
	var token := str(Time.get_ticks_usec())
	_system_wav_path = temp_absolute.path_join("system-%s.wav" % token)
	_stop_marker_path = temp_absolute.path_join("system-%s.stop" % token)
	_ready_marker_path = temp_absolute.path_join("system-%s.ready" % token)
	_error_marker_path = temp_absolute.path_join("system-%s.error" % token)
	_helper_pid = OS.create_process(_helper_path, PackedStringArray([
		_system_wav_path,
		_stop_marker_path,
		_ready_marker_path,
		_error_marker_path,
		str(int(AudioServer.get_mix_rate())),
		"2",
	]))
	return _helper_pid > 0


func _finish_system_audio_helper() -> String:
	var marker := FileAccess.open(_stop_marker_path, FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()

	var waited := 0
	while _helper_pid > 0 and OS.is_process_running(_helper_pid) \
			and waited < HELPER_STOP_TIMEOUT_MSEC:
		OS.delay_msec(25)
		waited += 25
	if _helper_pid > 0 and OS.is_process_running(_helper_pid):
		OS.kill(_helper_pid)
		return "系統音訊擷取停止逾時"
	if FileAccess.file_exists(_error_marker_path):
		var message := FileAccess.get_file_as_string(_error_marker_path).strip_edges()
		if not message.is_empty():
			return message
	if not FileAccess.file_exists(_ready_marker_path):
		return "macOS 沒有允許螢幕與系統音訊錄製"
	return ""


func _cleanup_system_audio_session() -> void:
	for path in [_system_wav_path, _stop_marker_path, _ready_marker_path, _error_marker_path]:
		if not path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_helper_pid = -1
	_system_wav_path = ""
	_stop_marker_path = ""
	_ready_marker_path = ""
	_error_marker_path = ""
	_session_microphone = false
	_session_system_audio = false
	_session_system_error = ""


func _install_system_audio_helper() -> String:
	if not FileAccess.file_exists(HELPER_RESOURCE):
		return ""
	var source := FileAccess.get_file_as_bytes(HELPER_RESOURCE)
	if source.is_empty():
		return ""
	var folder := ProjectSettings.globalize_path(HELPER_FOLDER)
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		return ""
	var target := folder.path_join(HELPER_FILE)
	var current := FileAccess.get_file_as_bytes(target) \
		if FileAccess.file_exists(target) else PackedByteArray()
	if current != source:
		var output := FileAccess.open(target, FileAccess.WRITE)
		if output == null:
			return ""
		output.store_buffer(source)
		output.close()
	var chmod_result := OS.execute("/bin/chmod", PackedStringArray(["755", target]))
	return target if chmod_result == 0 else ""


func _stamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d%02d%02d" % [
		t["year"], t["month"], t["day"], t["hour"], t["minute"], t["second"],
	]


func _input_allowed() -> bool:
	return bool(ProjectSettings.get_setting("audio/driver/enable_input", false))
