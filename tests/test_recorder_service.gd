extends Node


func _ready() -> void:
	if RecorderService.MAX_SECONDS != 3600.0:
		push_error("RecorderService: expected a one-hour limit, got %.1f seconds"
			% RecorderService.MAX_SECONDS)
		get_tree().quit(1)
		return
	if not RecorderService.DEFAULT_MICROPHONE or not RecorderService.DEFAULT_SYSTEM_AUDIO:
		push_error("RecorderService: both recording sources must default to enabled")
		get_tree().quit(1)
		return

	var microphone := _stream([1000, -1000, 32767])
	var system_audio := _stream([3000, -3000, 32767])
	var mixed: AudioStreamWAV = RecorderService._combine_streams(
		microphone, system_audio)
	var expected := [3000, -3000, 32767]
	for i in expected.size():
		var actual: int = mixed.data.decode_s16(i * 2)
		if actual != expected[i]:
			push_error("RecorderService: mixed sample %d was %d, expected %d"
				% [i, actual, expected[i]])
			get_tree().quit(1)
			return

	if RecorderService._combine_streams(microphone, null) != microphone:
		push_error("RecorderService: microphone-only recording was copied or dropped")
		get_tree().quit(1)
		return
	if RecorderService._combine_streams(null, system_audio) != system_audio:
		push_error("RecorderService: system-only recording was copied or dropped")
		get_tree().quit(1)
		return

	print("RecorderService: source defaults and PCM mixing passed")
	get_tree().quit(0)


func _stream(samples: Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(samples[i]))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 44100
	stream.stereo = false
	stream.data = data
	return stream
