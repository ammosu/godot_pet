extends Node

## What can be checked about the cloud backend without an account.
##
## Everything here is the part that runs on *this* side of the network: decoding
## what came back, telling the failures apart, and not playing audio the user
## already cancelled. What cannot be checked here is whether ElevenLabs likes the
## request — that needs a key and costs money, so it stays a thing a person does
## once by hand.

var _failures := 0
var _checks := 0


func _ready() -> void:
	_test_decode_formats()
	_test_error_messages()
	_test_stop_discards_in_flight()
	_test_queue_order()
	_test_failure_does_not_wedge()

	if _failures > 0:
		push_error("ElevenVoice: %d of %d checks failed" % [_failures, _checks])
	else:
		print("ElevenVoice: %d checks passed" % _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("ElevenVoice: %s" % message)


func _voice() -> ElevenVoice:
	var voice := ElevenVoice.new()
	add_child(voice)
	return voice


## The decode path is the one that silently disables the whole backend if it is
## wrong: every sentence would come back, fail to become a stream, and be
## reported as ElevenLabs' fault.
func _test_decode_formats() -> void:
	var voice := _voice()

	_expect(voice._decode(PackedByteArray(), "mp3_44100_128") == null,
		"an empty body decoded to something")
	_expect(voice._decode(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]), "mp3_44100_128") == null,
		"garbage decoded as MP3 instead of being refused")

	# Raw PCM16 needs no decoder, only the rate out of the format name — the API
	# does not repeat it anywhere else in the response.
	var pcm := PackedByteArray()
	for i in 200:
		pcm.append(i % 256)
		pcm.append(0)
	var wav := voice._decode(pcm, "pcm_24000")
	_expect(wav is AudioStreamWAV, "pcm_24000 did not decode to a WAV stream")
	if wav is AudioStreamWAV:
		_expect((wav as AudioStreamWAV).mix_rate == 24000,
			"the sample rate was not taken from the format name")
		_expect(not (wav as AudioStreamWAV).stereo, "PCM came back as stereo")
	_expect(voice._decode(pcm, "pcm_") == null, "a format with no rate was accepted")

	var mp3 := _sample_mp3()
	if mp3.is_empty():
		print("ElevenVoice: MP3 decode check skipped (no ffmpeg)")
	else:
		var stream := voice._decode(mp3, "mp3_44100_128")
		_expect(stream is AudioStreamMP3, "a valid MP3 body did not decode")
		if stream != null:
			_expect(absf(stream.get_length() - 1.5) < 0.1,
				"the decoded MP3 was not the length it was made at")

	voice.free()


## Only some of these are worth acting on, and a user told nothing but "it broke"
## cannot tell a wrong key from an exhausted quota.
func _test_error_messages() -> void:
	var voice := _voice()
	var unauthorised := voice._explain(401)
	var quota := voice._explain(429)
	_expect(unauthorised != quota, "a bad key and a spent quota read the same")
	_expect(unauthorised.contains("金鑰"), "the 401 message does not mention the key")
	_expect(quota.contains("額度"), "the 429 message does not mention the quota")
	_expect(voice._explain(503).contains("503"),
		"an unexpected status is not named in the message")
	for code in [401, 403, 422, 429, 500]:
		_expect(voice._explain(code).ends_with("。"),
			"the message for %d is not a finished sentence" % code)
	voice.free()


## A request already sent cannot be unsent, so the audio still arrives. It has to
## be recognised as unwanted rather than played over whatever the pet is saying
## now — and the user who cancelled it must not be told anything broke.
func _test_stop_discards_in_flight() -> void:
	var voice := _voice()
	voice._speaking = "在講的那句"
	voice._request_epoch = voice._epoch
	voice._pending.append("排隊中的那句")

	var complaints: Array[String] = []
	voice.broke.connect(func(reason: String) -> void: complaints.append(reason))

	voice.stop()
	_expect(voice._pending.is_empty(), "stop() left sentences queued")
	_expect(voice._queue.is_empty(), "stop() left audio queued")

	# The reply to the cancelled request turning up afterwards.
	voice._on_audio_received(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
		_sample_mp3() if not _sample_mp3().is_empty() else PackedByteArray([1, 2, 3]))
	_expect(voice._queue.is_empty(), "audio from before stop() was queued anyway")
	_expect(complaints.is_empty(), "cancelling a sentence was reported as a failure")
	voice.free()


## Sentences arrive one at a time as a reply streams, and only one request is in
## flight — otherwise two could finish out of order and the pet would say the
## second half of a thought first.
func _test_queue_order() -> void:
	var voice := _voice()
	voice._voice_id = "test-voice"
	voice._speaking = "佔住"     # pretend a request is already out
	voice._pending.append("第一句")
	voice._pending.append("第二句")
	voice._send_next()
	_expect(voice._speaking == "佔住", "a second request went out while one was in flight")
	_expect(voice._pending.size() == 2, "a queued sentence was consumed early")
	voice.free()


## A failure must not leave sentences piling up behind a request that will never
## be sent. The voice list is asked for once per session so a broken account is
## not hammered, and that guard is exactly what would wedge the queue for the
## rest of the run if giving up did not also empty it.
func _test_failure_does_not_wedge() -> void:
	var voice := _voice()
	voice._pending.append("第一句")
	voice._pending.append("第二句")
	voice._voices_asked = true          # as if the list had already been asked for

	voice._on_voices_received(HTTPRequest.RESULT_SUCCESS, 401, PackedStringArray(),
		PackedByteArray())
	_expect(voice._pending.is_empty(),
		"a failed voice lookup left sentences queued forever")

	# And selecting the backend again — or pasting a key — earns another attempt.
	voice.refresh()
	_expect(not voice._voices_asked, "refresh() did not re-arm the voice lookup")
	voice.free()


## A 1.5-second MP3, or empty when ffmpeg is not installed. Made rather than
## committed: a binary fixture in the repo would have to be trusted, and this one
## can be checked against the duration it was asked for.
func _sample_mp3() -> PackedByteArray:
	var path := OS.get_user_data_dir().path_join("eleven_test_tone.mp3")
	if not FileAccess.file_exists(path):
		var output := []
		var code := OS.execute("ffmpeg", ["-y", "-v", "error", "-f", "lavfi", "-i",
			"sine=frequency=440:duration=1.5", "-ar", "44100", "-ac", "1", "-b:a",
			"128k", path], output)
		if code != 0:
			return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)
