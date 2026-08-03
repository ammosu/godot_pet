extends Node

## What can be checked about the local-service backend without the service.
##
## The parts that only exist on this side: the cache, telling a refusal from an
## absence, and not playing audio the user already cancelled. Whether VoxCPM
## sounds right is a thing ears decide, and whether the service answers is
## checked by running it — neither belongs here.

var _failures := 0
var _checks := 0


func _ready() -> void:
	_test_cache_round_trip()
	_test_health_distinguishes_refusal_from_absence()
	_test_stop_discards_in_flight()
	_test_voice_selection_survives_a_missing_voice()

	if _failures > 0:
		push_error("VoxCPMVoice: %d of %d checks failed" % [_failures, _checks])
	else:
		print("VoxCPMVoice: %d checks passed" % _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("VoxCPMVoice: %s" % message)


func _voice() -> VoxCPMVoice:
	var voice := VoxCPMVoice.new()
	add_child(voice)
	return voice


func _reply(voice: VoxCPMVoice, code: int, body: String) -> void:
	voice._on_meta_received(HTTPRequest.RESULT_SUCCESS, code, PackedStringArray(),
		body.to_utf8_buffer())


## The cache is what makes a fixed line free, and — the part worth testing — what
## lets one still play when the service is not running at all.
func _test_cache_round_trip() -> void:
	var voice := _voice()
	var directory := ProjectSettings.globalize_path("user://voxcpm/test-cache")
	var wav := _tone_wav()

	voice._write_cache("我肚子餓了", directory, wav)
	_expect(not voice._cached_path("我肚子餓了", directory).is_empty(),
		"a written cache line was not found again")
	var stream := voice._cached_stream("我肚子餓了", directory)
	_expect(stream != null, "a cached line did not come back as a stream")
	if stream != null:
		_expect(absf(stream.get_length() - 0.5) < 0.05,
			"the cached audio came back the wrong length")

	_expect(voice._cached_stream("別的句子", directory) == null,
		"a different line matched a cached one")

	# Half-written files happen — the pet is killed mid-batch. Refused rather
	# than played as noise; the caller then synthesises the line for real.
	var broken := directory.path_join("我肚子餓了".sha256_text() + ".wav")
	var file := FileAccess.open(broken, FileAccess.WRITE)
	file.store_buffer(wav.slice(0, 30))
	file.close()
	_expect(voice._cached_stream("我肚子餓了", directory) == null,
		"a truncated cache file was played instead of being refused")

	var dir := DirAccess.open(directory)
	if dir != null:
		for leaf in dir.get_files():
			DirAccess.remove_absolute(directory.path_join(leaf))
	DirAccess.remove_absolute(directory)
	voice.free()


## A service that answered is not a service that is down, and the row offering to
## paste a key must not appear when no key would help.
func _test_health_distinguishes_refusal_from_absence() -> void:
	var voice := _voice()

	_reply(voice, 401, '{"detail":"未授權"}')
	_expect(not voice.is_available(), "a 401 left the backend looking usable")
	_expect(voice.needs_key(), "a 401 did not ask for a key")
	_expect(voice.unavailable_reason().contains("key"),
		"the 401 reason does not mention the key")

	voice._on_meta_received(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(),
		PackedByteArray())
	_expect(not voice.is_available(), "an unreachable service looked usable")
	_expect(not voice.needs_key(),
		"an unreachable service asked for a key no key would fix")

	_reply(voice, 200, '{"status":"loading"}')
	_expect(not voice.is_available(), "a loading service looked ready")
	_expect(not voice.needs_key(), "a loading service asked for a key")

	_reply(voice, 200, '{"status":"ok"}')
	_expect(voice.is_available(), "a healthy service was not believed")
	_expect(voice.unavailable_reason().is_empty(),
		"a healthy service still carries a reason")
	voice.free()


## A request already sent cannot be unsent, so its audio still arrives. It must
## be discarded rather than played over what the pet is saying now — and the
## user who cancelled it must not be told anything broke.
func _test_stop_discards_in_flight() -> void:
	var voice := _voice()
	var complaints: Array[String] = []
	voice.broke.connect(func(reason: String) -> void: complaints.append(reason))

	voice._current = {"text": "在講的那句", "cache": ""}
	voice._request_epoch = voice._epoch
	voice._pending.append({"text": "排隊中", "cache": ""})
	voice.stop()
	_expect(voice._pending.is_empty(), "stop() left sentences queued")

	voice._on_audio_received(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
		_tone_wav())
	_expect(voice._queue.is_empty(), "audio from before stop() was queued anyway")
	_expect(complaints.is_empty(), "cancelling a sentence was reported as a failure")
	voice.free()


## A voice library is rebuilt outside the pet, so the name in config can stop
## existing. Falling back beats going mute with a tick on a row that is gone.
func _test_voice_selection_survives_a_missing_voice() -> void:
	var voice := _voice()
	_reply(voice, 200, '{"voices":[{"voice_id":"lulu_witch","name":"Lulu"},' +
		'{"voice_id":"yu_energetic","name":"Yu"}]}')
	_expect(voice.list_voices().size() == 2, "the voice list was not taken")

	voice.select_voice("yu_energetic")
	_expect(voice.active_voice() == "yu_energetic", "the chosen voice was not kept")
	_expect(voice.voice_name() == "Yu", "the display name was not resolved")

	voice.select_voice("一個不存在的音色")
	_expect(voice.active_voice() == "lulu_witch",
		"a voice that no longer exists did not fall back to a real one")
	voice.select_voice("")
	voice.free()


## Half a second of 16-bit mono, as a WAV the engine will actually parse.
func _tone_wav() -> PackedByteArray:
	var rate := 24000
	var pcm := PackedByteArray()
	for i in rate / 2:
		var value := int(sin(float(i) * 0.05) * 8000.0)
		pcm.append(value & 0xff)
		pcm.append((value >> 8) & 0xff)
	var wav := PackedByteArray()
	wav.append_array("RIFF".to_ascii_buffer())
	_u32(wav, 36 + pcm.size())
	wav.append_array("WAVEfmt ".to_ascii_buffer())
	_u32(wav, 16)
	_u16(wav, 1)
	_u16(wav, 1)
	_u32(wav, rate)
	_u32(wav, rate * 2)
	_u16(wav, 2)
	_u16(wav, 16)
	wav.append_array("data".to_ascii_buffer())
	_u32(wav, pcm.size())
	wav.append_array(pcm)
	return wav


func _u32(bytes: PackedByteArray, value: int) -> void:
	for shift in [0, 8, 16, 24]:
		bytes.append((value >> shift) & 0xff)


func _u16(bytes: PackedByteArray, value: int) -> void:
	bytes.append(value & 0xff)
	bytes.append((value >> 8) & 0xff)
