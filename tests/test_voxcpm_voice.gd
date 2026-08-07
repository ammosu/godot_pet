extends Node

## What can be checked about the local-service backend without the service.
##
## The parts that only exist on this side: the cache, telling a refusal from an
## absence, and not playing audio the user already cancelled. Whether VoxCPM
## sounds right is a thing ears decide, and whether the service answers is
## checked by running it — neither belongs here.

var _failures := 0
var _checks := 0
## Which tests reached their last line. **Counting checks is not enough:** a
## runtime error inside a test aborts that function, `_ready()` carries straight
## on to the next one, and the tally then reports only the checks that happened
## to run. Measured — a call to a method that had been deleted printed
## 「13 checks passed」 and exited 0, with seven checks never reached. GDScript
## gives no way to catch that from inside, so the test says it finished and this
## notices when one did not.
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"default endpoint": _test_default_endpoint,
		"cache": _test_cache_round_trip,
		"health": _test_health_distinguishes_refusal_from_absence,
		"cancel": _test_stop_discards_in_flight,
		"voices": _test_voice_selection_survives_a_missing_voice,
		"voice_refresh": _test_explicit_refresh_replaces_a_loaded_library,
		"credential_refresh": _test_credential_refresh_replaces_an_in_flight_check,
		"routing": _test_each_voice_lands_in_its_own_folder,
		"forget": _test_forgetting_is_never_a_side_effect,
		"outage": _test_a_dead_service_ends_the_batch,
	}
	for name: String in tests:
		(tests[name] as Callable).call()

	var aborted: Array[String] = []
	for name: String in tests:
		if not _finished.has(name):
			aborted.append(name)
	for name in aborted:
		_failures += 1
		push_error("VoxCPMVoice: the '%s' test did not run to the end — look for a "
			% name + "SCRIPT ERROR above; its later checks never happened")

	if _failures > 0:
		push_error("VoxCPMVoice: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	else:
		print("VoxCPMVoice: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("VoxCPMVoice: %s" % message)


## Last line of every test. Anything that stops the function short of this —
## including an engine-level error GDScript will not let us catch — is reported.
func _done(name: String) -> void:
	_finished.append(name)


## A backend detached from the network, which is what this file claims to test.
##
## `_ready()` asks the service how it is, and every test below then hands it a
## reply by hand — so without cancelling that first request, the fabricated
## answers arrive while the real one is still in flight and the engine complains
## that the HTTPRequest is busy. Nothing failed, but a test suite that prints
## errors when it passes teaches you to stop reading them.
func _voice() -> VoxCPMVoice:
	var voice := VoxCPMVoice.new()
	add_child(voice)
	voice._meta_http.cancel_request()
	voice._http.cancel_request()
	return voice


func _test_default_endpoint() -> void:
	_expect(VoxCPMVoice.DEFAULT_URL == "https://voice.anfucwbot.uk",
		"the shipped VoxCPM endpoint is not the hosted HTTPS service")
	_done("default endpoint")


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
	_done("cache")


## A service that answered is not a service that is down: the reason has to name
## which, or the user is sent to restart something that is running perfectly
## well. And every outcome must announce itself — the settings UI waits on
## `checked` to say whether a newly-typed address reaches anything, so a path
## that stays silent leaves it waiting forever.
func _test_health_distinguishes_refusal_from_absence() -> void:
	var voice := _voice()
	var answers: Array = []
	voice.checked.connect(func(healthy: bool, reason: String) -> void:
		answers.append([healthy, reason]))

	_reply(voice, 401, '{"detail":"未授權"}')
	_expect(not voice.is_available(), "a 401 left the backend looking usable")
	_expect(voice.unavailable_reason().contains("key"),
		"the 401 reason does not mention the key")
	_expect(voice.unavailable_reason().contains(VoxCPMVoice.KEY_ROW_LABEL),
		"the 401 reason does not name the menu row that fixes it")

	voice._on_meta_received(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(),
		PackedByteArray())
	_expect(not voice.is_available(), "an unreachable service looked usable")
	_expect(not voice.unavailable_reason().contains("key"),
		"an unreachable service blamed the key, which no key would fix")

	_reply(voice, 200, '{"status":"loading"}')
	_expect(not voice.is_available(), "a loading service looked ready")

	_expect(answers.size() == 3,
		"one of the three failures never emitted `checked`, so anything waiting "
		+ "on an answer would wait for ever")
	_expect(not answers.any(func(a: Array) -> bool: return a[0]),
		"a failure reported itself as healthy")
	_expect(not answers.any(func(a: Array) -> bool: return str(a[1]).is_empty()),
		"a failure was announced with no reason to show")

	# `ok` with no voices yet is deliberately *not* settled: /health is exempt
	# from the API key, so a service with auth on answers it and then refuses
	# everything else. The voice list is what decides.
	_reply(voice, 200, '{"status":"ok"}')
	_expect(answers.size() == 3,
		"a bare /health reply was treated as proof the backend works")

	_reply(voice, 200, '{"voices":[{"voice_id":"a","name":"A"}]}')
	_expect(voice.is_available(), "a healthy service was not believed")
	_expect(voice.unavailable_reason().is_empty(),
		"a healthy service still carries a reason")
	_expect(answers.size() == 4 and answers[3][0], "success never announced itself")
	voice.free()
	_done("health")


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
	_done("cancel")


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
	_done("voices")


## Opening the menu starts a health request before the refresh row can be
## pressed. The explicit refresh must wait for that reply, then replace a
## non-empty library; otherwise adding a voice remotely still needs a restart.
func _test_explicit_refresh_replaces_a_loaded_library() -> void:
	var voice := _voice()
	var answers: Array = []
	voice.checked.connect(func(healthy: bool, reason: String) -> void:
		answers.append([healthy, reason]))
	voice._voices = [{"voice_id": "old", "name": "Old"}]

	voice.refresh()
	voice.refresh_voice_library()
	_expect(voice._voice_refresh_requested,
		"a refresh pressed during the health request was discarded")
	# A real request_completed signal is emitted after HTTPRequest leaves its busy
	# state. `_reply()` calls the handler directly, so reproduce that transition.
	voice._meta_http.cancel_request()
	_reply(voice, 200, '{"status":"ok"}')
	_expect(answers.is_empty(),
		"the health reply completed the refresh before /v1/voices answered")
	_expect(voice._voice_refresh_requested,
		"the queued library request was cleared by the health reply")

	_reply(voice, 200, '{"voices":[{"voice_id":"old","name":"Old"},' +
		'{"voice_id":"new","name":"New"}]}')
	_expect(voice.list_voices() == PackedStringArray(["old", "new"]),
		"the explicit refresh did not replace the loaded library")
	_expect(not voice._voice_refresh_requested,
		"the completed refresh still looked in flight")
	_expect(answers.size() == 1 and answers[0][0],
		"the completed library refresh did not announce success")
	voice.free()
	_done("voice_refresh")


## Setting URL first starts a metadata check with the old credential. Pasting a
## key must replace that request, otherwise its stale 401 wins and the backend
## remains disabled until the URL is edited a second time.
func _test_credential_refresh_replaces_an_in_flight_check() -> void:
	var voice := _voice()
	var answers: Array = []
	voice.checked.connect(func(healthy: bool, reason: String) -> void:
		answers.append([healthy, reason]))

	voice.refresh()
	voice.refresh_after_credentials_change()
	_expect(voice._voice_refresh_requested,
		"credential change did not queue a protected voice-list check")
	voice._meta_http.cancel_request()
	_reply(voice, 200, '{"voices":[{"voice_id":"fresh","name":"Fresh"}]}')
	_expect(voice.is_available(), "new credential result did not restore availability")
	_expect(voice.list_voices() == PackedStringArray(["fresh"]),
		"new credential result did not replace the voice list")
	_expect(answers.size() == 1 and answers[0][0],
		"credential refresh did not announce successful validation")
	voice.free()
	_done("credential_refresh")


## Each clip has to land in the folder of the voice it was rendered in.
##
## The bug this exists for: the directory was fixed when the batch started while
## the voice was read from the setting at dispatch time, so everything after a
## switch was filed under the wrong name — permanently, the key being a hash of
## the text rather than of the audio. Nothing downstream can notice, because a
## wrong clip is a perfectly valid wav.
func _test_each_voice_lands_in_its_own_folder() -> void:
	var voice := _voice()
	# Pointed at the discard port for the duration: `prerender()` dispatches the
	# first job immediately, and a test must not make the user's real service
	# generate audio nobody asked for.
	var was: Variant = Config.get_value("tts", "voxcpm_url", VoxCPMVoice.DEFAULT_URL)
	Config.set_value("tts", "voxcpm_url", "http://127.0.0.1:9")

	voice.prerender(PackedStringArray(["一", "二"]), "alice")
	voice.prerender(PackedStringArray(["一", "二"]), "bob")
	var jobs: Array = [voice._current]
	jobs.append_array(voice._pending)
	_expect(jobs.size() == 4, "four clips were asked for, %d were queued" % jobs.size())

	var wrong := 0
	for job: Dictionary in jobs:
		# The folder and the voice must agree *per job*, which is exactly what the
		# old code got wrong — and both must be the job's own, not the setting's.
		if not str(job.get("cache", "")).ends_with(str(job.get("voice", ""))):
			wrong += 1
	_expect(wrong == 0, "%d of %d clips would be filed under another voice" % [wrong, jobs.size()])
	_expect(jobs.any(func(j: Dictionary) -> bool: return j.get("voice") == "alice")
		and jobs.any(func(j: Dictionary) -> bool: return j.get("voice") == "bob"),
		"a whole voice went missing from the batch")

	voice.stop()
	Config.set_value("tts", "voxcpm_url", was)
	voice.free()
	_done("routing")


## Pruning must never be something `prerender()` does on the side.
##
## It used to be, and it pruned to whatever set that one call carried — so a
## caller passing a subset silently deleted everything else. Measured: a probe
## that pre-rendered twenty throwaway lines took a voice's entire cache with it.
func _test_forgetting_is_never_a_side_effect() -> void:
	var voice := _voice()
	var was: Variant = Config.get_value("tts", "voxcpm_url", VoxCPMVoice.DEFAULT_URL)
	Config.set_value("tts", "voxcpm_url", "http://127.0.0.1:9")
	var directory := voice._cache_dir("ghost")
	DirAccess.make_dir_recursive_absolute(directory)
	for line in ["留下來的", "也留下來的"]:
		voice._write_cache(line, directory, _tone_wav())

	voice.prerender(PackedStringArray(["只有這一句"]), "ghost")
	_expect(not voice._cached_path("留下來的", directory).is_empty(),
		"prerender() with a partial list deleted a line it was simply not asked about")

	voice.forget_unlisted(PackedStringArray([]), "ghost")
	_expect(not voice._cached_path("留下來的", directory).is_empty(),
		"an empty list emptied the cache — which is what a failed nudges.json "
		+ "load looks like")

	voice.forget_unlisted(PackedStringArray(["留下來的"]), "ghost")
	_expect(not voice._cached_path("留下來的", directory).is_empty(),
		"a listed line was forgotten")
	_expect(voice._cached_path("也留下來的", directory).is_empty(),
		"an unlisted line survived a deliberate forget")

	voice.stop()
	for leaf in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(leaf))
	DirAccess.remove_absolute(directory)
	Config.set_value("tts", "voxcpm_url", was)
	voice.free()
	_done("forget")


## A batch is ninety requests. Losing the service part-way through must end it,
## not fire the remaining eighty-seven at a socket that has gone — and must say
## so once rather than once per clip.
func _test_a_dead_service_ends_the_batch() -> void:
	var voice := _voice()
	var complaints: Array[String] = []
	voice.broke.connect(func(reason: String) -> void: complaints.append(reason))
	var progress: Array = []
	voice.line_prerendered.connect(func(done: int, left: int) -> void:
		progress.append([done, left]))

	var fill := voice._cache_dir("gone")
	voice._current = {"text": "第一句", "cache": fill, "voice": "gone"}
	voice._request_epoch = voice._epoch
	for i in 5:
		voice._pending.append({"text": "第 %d 句" % i, "cache": fill, "voice": "gone"})
	voice._fills_left = 6

	voice._on_audio_received(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(),
		PackedByteArray())
	_expect(complaints.size() == 1,
		"a dropped connection was reported %d times, not once" % complaints.size())
	_expect(voice._pending.is_empty(),
		"%d clips were still queued for a service that is gone" % voice._pending.size())
	_expect(not progress.is_empty() and progress[-1][1] == 0,
		"the batch never reached zero, so anything watching it waits for ever")
	voice.free()
	_done("outage")


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
