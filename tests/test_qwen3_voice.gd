extends Node

var _failures := 0
var _checks := 0


func _ready() -> void:
	_test_helper_candidates()
	_test_dev_helper_static_gate()
	_test_backend_fallback()
	_test_native_arguments()
	_test_python_command()
	_test_native_wav()
	_test_spool_paths_and_symlink()
	_test_line_cache()
	_test_clear_spool_ownership()
	_test_linked_workdir_blocks_spawn()
	_test_linked_owned_leaves_block_spawn()
	_test_clone_output_links()
	_test_voice_api_links()
	_test_recursive_dependency_closure()
	_test_model_sizes()
	_test_fetcher_limits_and_progress()
	_test_free_space_argv_path()
	_test_pending_say_accounting()
	_test_clone_correlation()
	_test_invalid_native_ready()
	_test_batch_generation_fence()
	await _test_dead_before_send_preserves_requests()
	_test_native_startup_timeout()
	await _test_nonexecutable_native_fallback()
	await _test_real_helper_ready()
	if _failures == 0:
		print("Qwen3Voice integration: %d checks passed" % _checks)
	else:
		push_error("Qwen3Voice integration: %d of %d checks failed" % [_failures, _checks])
	get_tree().quit(_failures)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	push_error(message)


func _test_helper_candidates() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/untrusted-helper-test")
	var runtime := root.path_join("runtime/current")
	DirAccess.make_dir_recursive_absolute(runtime)
	var marker := root.path_join("executed")
	var generated := root.path_join("generated-helper")
	_write_bytes(generated, ("#!/bin/sh\nprintf ran > %s\n" % marker).to_utf8_buffer())
	var output := []
	_expect(OS.execute("/bin/chmod", ["0700", generated], output) == 0,
		"could not prepare ignored helper fixture")
	_write_bytes(runtime.path_join(Qwen3Voice.HELPER_NAME),
		PackedByteArray([1, 2, 3]))
	var old_helper := OS.get_environment("GODOT_PET_QWEN3_HELPER")
	OS.set_environment("GODOT_PET_QWEN3_HELPER", generated)
	var found := Qwen3Voice.helper_candidates("/project", true)
	_expect(found == PackedStringArray([
		"/project/build/tts_helper_engine/godot-pet-tts-helper",
	]), "only the fixed editor helper path may be discovered")
	var exported := Qwen3Voice.helper_candidates("/pack", false)
	_expect(exported.is_empty(), "exported builds must not discover runtime or env binaries")
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	var selected := voice._find_native_helper()
	var built := ProjectSettings.globalize_path(
		"res://build/tts_helper_engine/godot-pet-tts-helper")
	_expect(selected == (built if voice._validate_dev_helper(built) else ""),
		"active discovery escaped the one fixed editor path")
	_expect(not FileAccess.file_exists(marker),
		"discovery executed the environment-provided helper")
	OS.set_environment("GODOT_PET_QWEN3_HELPER", old_helper)
	voice.free()
	DirAccess.remove_absolute(runtime.path_join(Qwen3Voice.HELPER_NAME))
	DirAccess.remove_absolute(generated)
	DirAccess.remove_absolute(runtime)
	DirAccess.remove_absolute(root.path_join("runtime"))
	DirAccess.remove_absolute(root)


func _test_backend_fallback() -> void:
	_expect(Qwen3Voice.choose_backend("/native", true) == Qwen3Voice.BACKEND_NATIVE,
		"native helper was not preferred")
	_expect(Qwen3Voice.choose_backend("", true) == Qwen3Voice.BACKEND_PYTHON,
		"Python fallback was lost")
	_expect(Qwen3Voice.choose_backend("", false).is_empty(),
		"an unavailable engine was selected")


func _test_dev_helper_static_gate() -> void:
	var voice := Qwen3Voice.new()
	var built := ProjectSettings.globalize_path(
		"res://build/tts_helper_engine/godot-pet-tts-helper")
	if FileAccess.file_exists(built):
		_expect(voice._validate_dev_helper(built),
			"real fixed editor helper failed static viability gate")
	var root := ProjectSettings.globalize_path("user://qwen3_tts/static-gate-test")
	DirAccess.make_dir_recursive_absolute(root)
	var zero := root.path_join("zero-helper")
	_touch(zero)
	_expect(not voice._validate_dev_helper(zero),
		"zero-byte helper authorized a model download")
	var nonexec := PackedByteArray()
	nonexec.resize(4096)
	if OS.has_feature("macos"):
		nonexec[0] = 0xcf; nonexec[1] = 0xfa; nonexec[2] = 0xed; nonexec[3] = 0xfe
		nonexec[4] = 0x0c if OS.has_feature("arm64") else 0x07
		nonexec[7] = 0x01
	else:
		nonexec[0] = 0x7f; nonexec[1] = 0x45; nonexec[2] = 0x4c; nonexec[3] = 0x46
		var machine := 183 if OS.has_feature("arm64") else 62
		nonexec[18] = machine & 0xff
		nonexec[19] = (machine >> 8) & 0xff
	var nonexec_path := root.path_join("nonexec-helper")
	_write_bytes(nonexec_path, nonexec)
	_expect(not voice._validate_dev_helper(nonexec_path),
		"non-executable helper authorized a model download")
	var tiny := PackedByteArray([0, 1, 2, 3])
	_expect(not Qwen3Voice.binary_supports_arch(tiny, "macos", true),
		"truncated binary header was accepted")
	var wrong := PackedByteArray()
	wrong.resize(32)
	wrong[0] = 0xcf; wrong[1] = 0xfa; wrong[2] = 0xed; wrong[3] = 0xfe
	# x86_64 cputype in a little-endian Mach-O while this fixture asks for arm64.
	wrong[4] = 0x07; wrong[7] = 0x01
	_expect(not Qwen3Voice.binary_supports_arch(wrong, "macos", true),
		"wrong-architecture Mach-O fixture was accepted")
	_expect(not Qwen3Voice.dev_dependencies_resolve(
		PackedStringArray(["@rpath/libmissing.dylib"]),
		PackedStringArray(["/definitely/missing"]), "/tmp"),
		"missing dylib dependency closure was accepted")
	voice.free()
	DirAccess.remove_absolute(nonexec_path)
	DirAccess.remove_absolute(zero)
	DirAccess.remove_absolute(root)


func _test_native_arguments() -> void:
	var voice := Qwen3Voice.new()
	voice._models = "/models"
	var args := voice._native_arguments()
	voice.free()
	_expect(args.size() == 18, "native helper argument count is wrong")
	_expect(_argument(args, "--models") == "/models", "native models argument is wrong")
	_expect(_argument(args, "--out").ends_with("/response.jsonl"),
		"native response argument is wrong")
	_expect(_argument(args, "--spool").ends_with("/spool"),
		"native spool argument is wrong")
	_expect(_argument(args, "--log").ends_with("/engine.log"),
		"native log argument is missing")
	_expect(_argument(args, "--protocol") == "1", "native protocol argument is wrong")
	_expect(int(_argument(args, "--threads")) >= 2, "native thread count is invalid")
	_expect(float(_argument(args, "--idle")) > 0.0, "native idle timeout is invalid")
	# Both limits are optional to the helper and zero means the library's own
	# defaults, which is the combination measured to run away — so what this
	# checks is that the protection is switched on at all, not any one value.
	_expect(int(_argument(args, "--max-tokens")) > 0,
		"native helper was launched without a token ceiling")
	_expect(float(_argument(args, "--temperature")) > 0.0,
		"native helper was launched without a sampling temperature")


func _test_python_command() -> void:
	var voice := Qwen3Voice.new()
	voice._python = "/usr/bin/python3"
	voice._library = "/legacy/libqwen3tts.dylib"
	voice._models = "/legacy/models"
	var command := voice._command()
	var native := voice._native_arguments()
	voice.free()
	_expect(command.contains("qwen3_tts/daemon.py"), "Python daemon command was lost")
	# The voice falls back from the native helper to this one without saying so,
	# so a sentence must not become more likely to run away by being spoken on
	# the other backend. Same config keys, therefore the same two numbers.
	_expect(command.contains("--max-tokens %s " % _argument(native, "--max-tokens")),
		"the two backends disagree about the token ceiling")
	_expect(command.contains("--temperature %s " % _argument(native, "--temperature")),
		"the two backends disagree about the sampling temperature")
	_expect(command.contains("--lib '/legacy/libqwen3tts.dylib'"),
		"Python library fallback argument was lost")
	_expect(command.contains("--models '/legacy/models'"),
		"Python models fallback argument was lost")


func _argument(args: PackedStringArray, name: String) -> String:
	var position := args.find(name)
	return args[position + 1] if position >= 0 and position + 1 < args.size() else ""


func _test_native_wav() -> void:
	var pcm := PackedByteArray([0, 0, 255, 127, 0, 128, 1, 0])
	var wav := _make_wav(pcm, 24000, 1, 16)
	var parsed := Qwen3Voice.parse_native_wav(wav, 24000, 4)
	_expect(not parsed.is_empty(), "valid PCM16 mono WAV was rejected")
	_expect(parsed.get("data", PackedByteArray()) == pcm, "WAV header leaked into PCM")
	_expect(int(parsed.get("rate", 0)) == 24000, "WAV sample rate was not preserved")
	var with_junk := _insert_junk_chunk(wav)
	_expect(not Qwen3Voice.parse_native_wav(with_junk, 24000, 4).is_empty(),
		"bounded unknown WAV chunk was not skipped safely")

	_expect(Qwen3Voice.parse_native_wav(wav, 16000, 4).is_empty(),
		"event/WAV rate mismatch was accepted")
	_expect(Qwen3Voice.parse_native_wav(wav, 24000, 3).is_empty(),
		"event/WAV sample mismatch was accepted")
	_expect(Qwen3Voice.parse_native_wav(wav.slice(0, wav.size() - 1), 24000, 4).is_empty(),
		"truncated WAV was accepted")
	var stereo := _make_wav(pcm, 24000, 2, 16)
	_expect(Qwen3Voice.parse_native_wav(stereo, 24000, 2).is_empty(),
		"stereo WAV was accepted")
	var float_wav := _make_wav(pcm, 24000, 1, 32)
	_expect(Qwen3Voice.parse_native_wav(float_wav, 24000, 2).is_empty(),
		"non-PCM16 WAV was accepted")

	var impossible := wav.duplicate()
	_put_u32(impossible, 40, 0x7fffffff)
	_expect(Qwen3Voice.parse_native_wav(impossible, 24000, 4).is_empty(),
		"oversized data chunk was accepted")
	var raw := pcm.duplicate()
	_expect(Qwen3Voice.parse_native_wav(raw, 24000, 4).is_empty(),
		"raw Python PCM was mistaken for native WAV")


func _test_spool_paths_and_symlink() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/spool-link-test")
	var spool := root.path_join("spool")
	DirAccess.make_dir_recursive_absolute(spool)
	var victim := root.path_join("victim.txt")
	_write_bytes(victim, "do-not-read-or-delete".to_utf8_buffer())
	var link := spool.path_join("7.wav")
	var output := []
	_expect(OS.execute("/bin/ln", ["-s", victim, link], output) == 0,
		"could not create spool symlink fixture")
	var directory := DirAccess.open(spool)
	_expect(directory != null and directory.is_link("7.wav"),
		"Godot 4.7 DirAccess.is_link did not identify the fixture")
	_expect(not Qwen3Voice.is_expected_spool_file(link, spool, "7.wav"),
		"symlink with the expected leaf was accepted")
	_expect(Qwen3Voice.read_expected_spool_file(link, spool, "7.wav").is_empty(),
		"symlink victim was read")
	_expect(FileAccess.get_file_as_string(victim) == "do-not-read-or-delete",
		"symlink victim was changed or deleted")

	var regular := spool.path_join("8.pcm")
	var raw := PackedByteArray([1, 2, 3, 4])
	_write_bytes(regular, raw)
	_expect(Qwen3Voice.is_expected_spool_file(regular, spool, "8.pcm"),
		"exact regular spool file was rejected")
	_expect(Qwen3Voice.read_expected_spool_file(regular, spool, "8.pcm") == raw,
		"exact regular spool file was not read")
	_expect(not Qwen3Voice.is_expected_spool_file(regular, spool, "7.pcm"),
		"wrong event id filename was accepted")
	_expect(not Qwen3Voice.is_expected_spool_file(regular, spool, "8.wav"),
		"wrong backend extension was accepted")
	var real_spool := root.path_join("real-spool")
	var linked_spool := root.path_join("linked-spool")
	DirAccess.make_dir_recursive_absolute(real_spool)
	var ancestor_victim := real_spool.path_join("9.wav")
	_write_bytes(ancestor_victim, PackedByteArray([9, 9, 9, 9]))
	output.clear()
	_expect(OS.execute("/bin/ln", ["-s", real_spool, linked_spool], output) == 0,
		"could not create spool ancestor symlink fixture")
	_expect(not Qwen3Voice.is_expected_spool_file(
		linked_spool.path_join("9.wav"), linked_spool, "9.wav"),
		"symlinked spool ancestor was accepted")
	_expect(Qwen3Voice.read_expected_spool_file(
		linked_spool.path_join("9.wav"), linked_spool, "9.wav").is_empty(),
		"symlinked spool ancestor victim was read")
	_expect(FileAccess.get_file_as_bytes(ancestor_victim) == PackedByteArray([9, 9, 9, 9]),
		"symlinked spool ancestor victim was changed")
	DirAccess.remove_absolute(link)
	DirAccess.remove_absolute(regular)
	DirAccess.remove_absolute(linked_spool)
	DirAccess.remove_absolute(ancestor_victim)
	DirAccess.remove_absolute(real_spool)
	DirAccess.remove_absolute(victim)
	DirAccess.remove_absolute(spool)
	DirAccess.remove_absolute(root)


## The cache has to hand back exactly what was put in it, and — the part worth
## testing hardest — must stop matching the moment the spoken text changes.
func _test_line_cache() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/cache-test")
	var voice := Qwen3Voice.new()
	voice._work_root_override = root

	var pcm := PackedByteArray()
	for i in 400:
		pcm.append(i % 256)
		pcm.append(0)
	voice._write_cache(voice._cache_dir(), "我肚子餓了", pcm, 24000)
	var found := voice._cached_path("我肚子餓了")
	_expect(not found.is_empty(), "a written cache line was not found again")
	_expect(found.get_file().begins_with("我肚子餓了".sha256_text() + "-"),
		"the cache file is not named after the spoken text")

	var stream := voice._cached_stream("我肚子餓了")
	_expect(stream != null, "a cached line did not come back as a stream")
	if stream != null:
		_expect(stream.data == pcm, "the cached audio came back altered")
		_expect(stream.mix_rate == 24000, "the cached sample rate was lost")
		_expect(not stream.stereo, "a cached line came back as stereo")

	# The invalidation the whole design rests on: a 破音字 rule changes the text
	# that reaches the backend, so it changes the key, so the old audio is simply
	# never found. Nothing clears anything, and nothing can forget to.
	_expect(voice._cached_path("我肚子餓ㄌ").is_empty(),
		"a different line matched a cached one")
	_expect(voice._cached_stream("我肚子餓ㄌ") == null,
		"a different line played cached audio")

	# The point of the whole feature: a cached line is queued without the helper
	# being asked for anything, so no model is loaded and no VRAM is taken. If
	# this ever regresses the pet still speaks correctly and the saving silently
	# disappears, which is why it is asserted rather than assumed.
	var before := voice._next_id
	voice.speak("我肚子餓了")
	_expect(voice._next_id == before, "a cached line still sent a request to the helper")
	_expect(voice._queue.size() == 1, "a cached line was not queued for playback")
	_expect(voice._pid == -1, "a cached line started the helper process")

	# A half-written or truncated file is refused rather than played as noise —
	# the caller then synthesises the line for real.
	_write_bytes(found, PackedByteArray([82, 73, 70, 70, 9, 9, 9, 9]))
	_expect(voice._cached_stream("我肚子餓了") == null,
		"a corrupt cache file was played instead of being refused")

	var cache_dir := voice._cache_dir()
	voice.free()
	var dir := DirAccess.open(cache_dir)
	if dir != null:
		for leaf in dir.get_files():
			DirAccess.remove_absolute(cache_dir.path_join(leaf))
	DirAccess.remove_absolute(cache_dir)
	DirAccess.remove_absolute(root.path_join(Qwen3Voice.CACHE_DIR))
	DirAccess.remove_absolute(root)


func _test_clear_spool_ownership() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/spool-clear-test")
	var victim_dir := root.path_join("victim-dir")
	var linked_spool := root.path_join("spool")
	DirAccess.make_dir_recursive_absolute(victim_dir)
	var victim_audio := victim_dir.path_join("1.wav")
	_write_bytes(victim_audio, PackedByteArray([1, 2, 3, 4]))
	var output := []
	_expect(OS.execute("/bin/ln", ["-s", victim_dir, linked_spool], output) == 0,
		"could not create linked spool cleanup fixture")
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._clear_spool()
	_expect(FileAccess.get_file_as_bytes(victim_audio) == PackedByteArray([1, 2, 3, 4]),
		"clear_spool followed a linked spool ancestor into victim data")
	DirAccess.remove_absolute(linked_spool)

	DirAccess.make_dir_recursive_absolute(linked_spool)
	_write_bytes(linked_spool.path_join("1.wav"), PackedByteArray([1]))
	_write_bytes(linked_spool.path_join("2.pcm"), PackedByteArray([2]))
	_write_bytes(linked_spool.path_join("unrelated.txt"), PackedByteArray([3]))
	_write_bytes(linked_spool.path_join("03.wav"), PackedByteArray([4]))
	_write_bytes(linked_spool.path_join("5.WAV"), PackedByteArray([5]))
	_write_bytes(linked_spool.path_join("6.PCM"), PackedByteArray([6]))
	var outside := root.path_join("outside.bin")
	_write_bytes(outside, PackedByteArray([5]))
	output.clear()
	_expect(OS.execute("/bin/ln", ["-s", outside, linked_spool.path_join("4.wav")], output) == 0,
		"could not create owned-name leaf symlink fixture")
	voice._clear_spool()
	_expect(not FileAccess.file_exists(linked_spool.path_join("1.wav"))
			and not FileAccess.file_exists(linked_spool.path_join("2.pcm")),
		"clear_spool did not remove direct owned audio files")
	_expect(FileAccess.file_exists(linked_spool.path_join("unrelated.txt"))
			and FileAccess.file_exists(linked_spool.path_join("03.wav"))
			and FileAccess.file_exists(linked_spool.path_join("5.WAV"))
			and FileAccess.file_exists(linked_spool.path_join("6.PCM")),
		"clear_spool removed unrelated or noncanonical files")
	var spool_dir := DirAccess.open(linked_spool)
	_expect(spool_dir != null and spool_dir.is_link("4.wav")
			and FileAccess.get_file_as_bytes(outside) == PackedByteArray([5]),
		"clear_spool removed/followed an owned-name symlink")
	voice.free()
	DirAccess.remove_absolute(linked_spool.path_join("4.wav"))
	DirAccess.remove_absolute(linked_spool.path_join("unrelated.txt"))
	DirAccess.remove_absolute(linked_spool.path_join("03.wav"))
	DirAccess.remove_absolute(linked_spool.path_join("5.WAV"))
	DirAccess.remove_absolute(linked_spool.path_join("6.PCM"))
	DirAccess.remove_absolute(linked_spool)
	DirAccess.remove_absolute(outside)
	DirAccess.remove_absolute(victim_audio)
	DirAccess.remove_absolute(victim_dir)
	DirAccess.remove_absolute(root)


func _test_linked_workdir_blocks_spawn() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/linked-work-start-test")
	var victim := root.path_join("victim")
	DirAccess.make_dir_recursive_absolute(victim)
	_write_bytes(victim.path_join("keep.txt"), "keep".to_utf8_buffer())
	var output := []
	OS.execute("/bin/ln", ["-s", victim, root.path_join("spool")], output)
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._checked = true
	voice._reason = ""
	voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
	voice._helper = ProjectSettings.globalize_path(
		"res://build/tts_helper_engine/godot-pet-tts-helper")
	voice._models = root
	_expect(not voice._start() and voice._pid == -1 and voice._stdio == null,
		"linked spool did not hard-fail before helper spawn")
	_expect(FileAccess.get_file_as_string(victim.path_join("keep.txt")) == "keep"
			and not FileAccess.file_exists(root.path_join("response.jsonl")),
		"linked spool startup wrote through or touched victim state")
	voice.free()
	DirAccess.remove_absolute(root.path_join("spool"))
	DirAccess.remove_absolute(victim.path_join("keep.txt"))
	DirAccess.remove_absolute(victim)
	DirAccess.remove_absolute(root)


func _test_linked_owned_leaves_block_spawn() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/linked-leaves-start-test")
	DirAccess.make_dir_recursive_absolute(root)
	var victim := root.path_join("victim")
	_write_bytes(victim, "keep".to_utf8_buffer())
	for leaf in ["response.jsonl", "engine.log", "daemon.py"]:
		var output := []
		_expect(OS.execute("/bin/ln", ["-s", victim, root.path_join(leaf)], output) == 0,
			"could not create linked owned-leaf fixture")
		var voice := Qwen3Voice.new()
		voice._work_root_override = root
		voice._checked = true
		voice._reason = ""
		voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
		voice._helper = ProjectSettings.globalize_path(
			"res://build/tts_helper_engine/godot-pet-tts-helper")
		voice._models = root
		_expect(not voice._start() and voice._pid == -1
				and voice._stdio == null and voice._spawn_generation == 0,
			"linked %s did not hard-fail before spawn" % leaf)
		_expect(FileAccess.get_file_as_string(victim) == "keep",
			"linked %s modified its victim" % leaf)
		voice.free()
		DirAccess.remove_absolute(root.path_join(leaf))
	for leaf in ["response.jsonl", "engine.log", "daemon.py"]:
		_write_bytes(root.path_join(leaf), "regular".to_utf8_buffer())
	var regular_voice := Qwen3Voice.new()
	regular_voice._work_root_override = root
	_expect(regular_voice._prepare_work_dirs(),
		"existing regular owned leaves were rejected")
	regular_voice.free()
	_cleanup_ready_tree(root)
	DirAccess.remove_absolute(victim)
	DirAccess.remove_absolute(root)


func _test_clone_output_links() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/linked-clone-output-test")
	DirAccess.make_dir_recursive_absolute(root.path_join(Qwen3Voice.VOICES_DIR))
	var recording := root.path_join("recording.wav")
	var victim := root.path_join("victim")
	_touch(recording)
	_write_bytes(victim, "keep".to_utf8_buffer())
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	var target := voice._voice_path("linked")
	var output := []
	OS.execute("/bin/ln", ["-s", victim, target], output)
	_expect(not voice.clone_from(recording, "linked") and voice._spawn_generation == 0,
		"linked clone target was handed to a helper")
	_expect(FileAccess.get_file_as_string(victim) == "keep",
		"linked clone target modified its victim")
	DirAccess.remove_absolute(target)
	output.clear()
	OS.execute("/bin/ln", ["-s", victim, target + ".part"], output)
	_expect(not voice.clone_from(recording, "linked") and voice._spawn_generation == 0,
		"linked legacy clone .part was handed to a helper")
	_expect(FileAccess.get_file_as_string(victim) == "keep",
		"linked clone .part modified its victim")
	DirAccess.remove_absolute(target + ".part")
	_write_bytes(target, "regular".to_utf8_buffer())
	_write_bytes(target + ".part", "regular".to_utf8_buffer())
	_expect(voice._clone_output_is_safe(target),
		"regular existing clone output leaves were rejected")
	voice.free()
	DirAccess.remove_absolute(target + ".part")
	DirAccess.remove_absolute(target)
	DirAccess.remove_absolute(root.path_join(Qwen3Voice.VOICES_DIR))
	DirAccess.remove_absolute(recording)
	DirAccess.remove_absolute(victim)
	DirAccess.remove_absolute(root)


func _test_voice_api_links() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/voice-api-link-test")
	var victim_dir := root.path_join("victim-dir")
	DirAccess.make_dir_recursive_absolute(victim_dir)
	var victim_voice := victim_dir.path_join("victim.%s" % Qwen3Voice.VOICE_EXTENSION)
	_write_bytes(victim_voice, "keep".to_utf8_buffer())
	var old_voice: Variant = Config.get_value("tts", "qwen3_voice", "")
	var output := []
	OS.execute("/bin/ln", ["-s", victim_dir, root.path_join(Qwen3Voice.VOICES_DIR)], output)
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	Config._file.set_value("tts", "qwen3_voice", "victim")
	_expect(voice.list_voices().is_empty() and voice.voices_folder().is_empty(),
		"linked voices ancestor was listed or exposed as a folder")
	_expect(voice.active_voice().is_empty() and not voice.has_cloned_voice(),
		"linked voices ancestor was treated as the active voice")
	_expect(not voice.delete_voice("victim")
			and FileAccess.get_file_as_string(victim_voice) == "keep",
		"delete_voice followed a linked voices ancestor")
	voice.set_active_voice("victim")
	_expect(str(Config.get_value("tts", "qwen3_voice", "")) == "",
		"set_active_voice persisted a linked voice")
	DirAccess.remove_absolute(root.path_join(Qwen3Voice.VOICES_DIR))
	var physical_voices := root.path_join(Qwen3Voice.VOICES_DIR)
	DirAccess.make_dir_recursive_absolute(physical_voices)
	output.clear()
	OS.execute("/bin/ln", ["-s", victim_voice,
		physical_voices.path_join("victim.%s" % Qwen3Voice.VOICE_EXTENSION)], output)
	Config._file.set_value("tts", "qwen3_voice", "victim")
	_expect(not voice.list_voices().has("victim") and voice.active_voice().is_empty(),
		"linked voice leaf was listed or activated")
	_expect(not voice.delete_voice("victim") and not voice.delete_voice("../victim")
			and FileAccess.get_file_as_string(victim_voice) == "keep",
		"delete_voice followed a leaf link or accepted a noncanonical name")
	Config.set_value("tts", "qwen3_voice", old_voice)
	voice.free()
	var physical_dir := DirAccess.open(physical_voices)
	if physical_dir != null:
		for leaf in physical_dir.get_files():
			DirAccess.remove_absolute(physical_voices.path_join(leaf))
	DirAccess.remove_absolute(physical_voices)
	DirAccess.remove_absolute(victim_voice)
	DirAccess.remove_absolute(victim_dir)
	DirAccess.remove_absolute(root)


func _test_recursive_dependency_closure() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/dependency-closure-test")
	var executable_dir := root.path_join("bin")
	var libraries := root.path_join("libs")
	var nested := libraries.path_join("nested")
	var absolute_dir := root.path_join("absolute")
	DirAccess.make_dir_recursive_absolute(executable_dir)
	DirAccess.make_dir_recursive_absolute(nested)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var helper := executable_dir.path_join("helper")
	var lib_a := libraries.path_join("libA.dylib")
	var lib_b := nested.path_join("libB.dylib")
	var lib_c := absolute_dir.path_join("libC.dylib")
	for path in [helper, lib_a, lib_b, lib_c]:
		_touch(path)
	var graph := {
		helper: {"dependencies": PackedStringArray([
			"@rpath/libA.dylib", "@executable_path/../absolute/libC.dylib"]),
			"rpaths": PackedStringArray(["@executable_path/../libs"])},
		lib_a: {"dependencies": PackedStringArray(["@loader_path/nested/libB.dylib"]),
			"rpaths": PackedStringArray()},
		lib_b: {"dependencies": PackedStringArray(["@executable_path/../libs/libA.dylib"]),
			"rpaths": PackedStringArray()},
		lib_c: {"dependencies": PackedStringArray([lib_b]),
			"rpaths": PackedStringArray()},
	}
	_expect(Qwen3Voice.dev_dependency_graph_resolves(graph, helper, executable_dir),
		"valid nested dependency closure/cycle did not resolve")
	DirAccess.remove_absolute(lib_b)
	_expect(not Qwen3Voice.dev_dependency_graph_resolves(graph, helper, executable_dir),
		"missing nested libB was accepted")
	_touch(lib_b)
	_expect(Qwen3Voice.parse_otool_metadata(
		"helper:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)",
		"Load command 0\n          cmd LC_RPATH\n      cmdsize 32\n         path @loader_path (offset 12)").size() == 2,
		"valid otool metadata did not parse")
	_expect(Qwen3Voice.parse_otool_metadata("helper:\n\tbroken", "").is_empty(),
		"malformed otool dependency output did not fail closed")
	_expect(Qwen3Voice._is_macos_system_dependency("/usr/lib/libSystem.B.dylib"),
		"canonical dyld shared-cache system name was rejected")
	_expect(not Qwen3Voice._is_macos_system_dependency("/usr/lib/../../tmp/evil"),
		"dot-dot dependency escaped a trusted system prefix")
	for path in [lib_c, lib_b, lib_a, helper]:
		DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(absolute_dir)
	DirAccess.remove_absolute(nested)
	DirAccess.remove_absolute(libraries)
	DirAccess.remove_absolute(executable_dir)
	DirAccess.remove_absolute(root)


func _test_model_sizes() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/model-size-test")
	DirAccess.make_dir_recursive_absolute(root)
	var entries := [
		{"name": Qwen3Voice.WEIGHT_FILES[1], "bytes": 4},
		{"name": Qwen3Voice.TOKENIZER_FILE, "bytes": 3},
	]
	_touch(root.path_join(Qwen3Voice.WEIGHT_FILES[1]))
	_write_bytes(root.path_join(Qwen3Voice.TOKENIZER_FILE), PackedByteArray([1, 2]))
	_expect(not ModelFetcher.has_expected_files(root, entries),
		"zero/truncated model files were accepted")
	_expect(not ModelFetcher.file_matches_entry(
		root.path_join(Qwen3Voice.WEIGHT_FILES[1]), entries[0]),
		"zero-byte existing target was treated as complete")
	_write_bytes(root.path_join(Qwen3Voice.WEIGHT_FILES[1]), PackedByteArray([1, 2, 3, 4]))
	_expect(ModelFetcher.remaining_bytes(root, entries) == 3,
		"remaining download bytes did not count only the tokenizer")
	_expect(ModelFetcher.required_free_bytes(root, entries) == 3 + ModelFetcher.SPACE_MARGIN,
		"disk threshold did not use remaining bytes plus margin")
	_write_bytes(root.path_join(Qwen3Voice.TOKENIZER_FILE), PackedByteArray([1, 2, 3]))
	_expect(ModelFetcher.has_expected_files(root, entries),
		"exact-size q8/tokenizer fixtures were rejected")
	_expect(ModelFetcher.remaining_bytes(root, entries) == 0,
		"complete exact-size files still counted as remaining")
	var voice := Qwen3Voice.new()
	_expect(not voice._holds_models(root),
		"Qwen availability bypassed ModelFetcher FILES size requirements")
	var legacy := PackedByteArray()
	legacy.resize(Qwen3Voice.LEGACY_MODEL_MIN_BYTES)
	for index in range(4):
		legacy[index] = "GGUF".to_ascii_buffer()[index]
	_write_bytes(root.path_join(Qwen3Voice.WEIGHT_FILES[0]), legacy)
	_write_bytes(root.path_join(Qwen3Voice.TOKENIZER_FILE), legacy)
	_expect(voice._holds_models(root),
		"valid manual f16 GGUF compatibility pair was rejected")
	_touch(root.path_join(Qwen3Voice.WEIGHT_FILES[0]))
	_expect(not voice._holds_models(root), "zero-byte manual f16 model was accepted")
	_write_bytes(root.path_join(Qwen3Voice.WEIGHT_FILES[0]), "GGUF".to_ascii_buffer())
	_expect(not voice._holds_models(root), "truncated manual f16 GGUF header was accepted")
	voice.free()
	DirAccess.remove_absolute(root.path_join(Qwen3Voice.WEIGHT_FILES[0]))
	DirAccess.remove_absolute(root.path_join(Qwen3Voice.WEIGHT_FILES[1]))
	DirAccess.remove_absolute(root.path_join(Qwen3Voice.TOKENIZER_FILE))
	DirAccess.remove_absolute(root)


func _test_fetcher_limits_and_progress() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/fetcher-state-test")
	DirAccess.make_dir_recursive_absolute(root)
	var entries := [
		{"name": "talker.gguf", "bytes": 4},
		{"name": "tokenizer.gguf", "bytes": 3},
	]
	var fetcher := ModelFetcher.new()
	fetcher._ensure_http()
	for index in range(ModelFetcher.FILES.size()):
		fetcher._index = index
		fetcher._set_current_body_limit()
		_expect(fetcher._http.body_size_limit == int(ModelFetcher.FILES[index]["bytes"]),
			"HTTPRequest body limit did not match current entry %d" % index)

	# Tokenizer survives while talker is absent: initial progress includes the
	# non-prefix artifact, then reaches the total after talker completes.
	_write_bytes(root.path_join("tokenizer.gguf"), PackedByteArray([1, 2, 3]))
	fetcher._initialise_run(root, entries)
	_expect(fetcher._carried == 3 and fetcher._index == 0,
		"initial progress did not carry a completed non-prefix tokenizer")
	_write_bytes(root.path_join("talker.gguf"), PackedByteArray([1, 2, 3, 4]))
	fetcher._carried += 4
	fetcher._index = 1
	fetcher._skip_completed_entries(entries)
	_expect(fetcher._carried == 7 and fetcher._index == 2
			and ModelFetcher._percent(fetcher._carried, 7) == 100,
		"talker completion plus existing tokenizer did not reach 100 percent")

	# Both complete starts at total and skipping must not double-add; none starts
	# at zero.
	fetcher._initialise_run(root, entries)
	var already_complete := fetcher._carried
	fetcher._skip_completed_entries(entries)
	_expect(already_complete == 7 and fetcher._carried == 7 and fetcher._index == 2,
		"completed prefix skipping double-counted carried bytes")
	DirAccess.remove_absolute(root.path_join("talker.gguf"))
	DirAccess.remove_absolute(root.path_join("tokenizer.gguf"))
	fetcher._initialise_run(root, entries)
	_expect(fetcher._carried == 0, "empty model directory did not start at zero")

	# HTTPRequest reports the cap violation; the existing failure path must remove
	# the partial file and never advance carried bytes.
	fetcher._dir = root
	fetcher._index = 0
	fetcher._carried = 0
	fetcher._phase = ModelFetcher.Phase.DOWNLOAD
	_write_bytes(fetcher._part(0), PackedByteArray([1, 2, 3, 4, 5]))
	var finishes: Array = []
	fetcher.finished.connect(func(ok: bool, message: String) -> void:
		finishes.append([ok, message]))
	fetcher._on_request_completed(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED,
		200, PackedStringArray(), PackedByteArray())
	_expect(not FileAccess.file_exists(fetcher._part(0)) and fetcher._carried == 0,
		"oversize response left partial data or advanced progress")
	_expect(finishes.size() == 1 and finishes[0][0] == false,
		"oversize response did not use the existing terminal failure path")
	fetcher.free()
	DirAccess.remove_absolute(root)


func _test_free_space_argv_path() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/df space ' quote")
	DirAccess.make_dir_recursive_absolute(root)
	_expect(ModelFetcher._free_space(root) >= 0,
		"df did not receive a spaced/single-quoted path as one exact argv element")
	DirAccess.remove_absolute(root)


func _test_pending_say_accounting() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/say-id-test")
	var spool := root.path_join("spool")
	DirAccess.make_dir_recursive_absolute(spool)
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._running_backend = Qwen3Voice.BACKEND_PYTHON
	voice._pending_say_ids = {1: true, 2: true, 3: true}
	voice._sync_outstanding()
	voice._on_error({"op": "say", "id": 1, "code": "engine_error", "message": "once"})
	voice._on_error({"op": "say", "id": 1, "code": "engine_error", "message": "duplicate"})
	voice._on_error({"op": "say", "id": 99, "code": "engine_error", "message": "unknown"})
	_expect(voice._pending_say_ids.size() == 2 and voice._outstanding == 2,
		"duplicate/unknown say errors changed outstanding accounting")
	voice._on_error({"op": "bogus", "id": 2, "code": "engine_error",
		"message": "must not consume"})
	_expect(voice._pending_say_ids.has(2) and voice._outstanding == 2,
		"unknown error op consumed a pending sentence")
	var audio := spool.path_join("2.pcm")
	_write_bytes(audio, PackedByteArray([1, 0, 2, 0]))
	voice._epoch = 2
	voice._on_audio({"id": 2, "path": audio, "rate": 24000, "samples": 2})
	voice._on_audio({"id": 2, "path": audio, "rate": 24000, "samples": 2})
	_expect(voice._pending_say_ids.has(3) and voice._pending_say_ids.size() == 1
			and voice._outstanding == 1 and voice._queue.is_empty(),
		"audio was not consumed exactly once")
	voice._clone_request = {"op": "clone", "id": 10, "name": ""}
	voice._deferred_native_requests = [
		{"op": "say", "id": 3}, {"op": "clone", "id": 10}]
	voice._sync_outstanding()
	voice.stop()
	_expect(voice._pending_say_ids.is_empty() and voice._outstanding == 1,
		"cancel did not clear only pending sentences")
	_expect(voice._deferred_native_requests.size() == 1
			and str(voice._deferred_native_requests[0].get("op")) == "clone",
		"cancel did not remove deferred sentences while preserving clone")
	voice._clone_request = {}
	voice._sync_outstanding()
	voice.free()
	DirAccess.remove_absolute(audio)
	DirAccess.remove_absolute(spool)
	DirAccess.remove_absolute(root)


func _touch(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.close()


func _test_clone_correlation() -> void:
	var voice := Qwen3Voice.new()
	var results: Array = []
	voice.voice_cloned.connect(func(ok: bool, message: String) -> void:
		results.append([ok, message]))
	voice._clone_request = {"op": "clone", "id": 7, "name": ""}
	voice._outstanding = 1
	_expect(not voice.clone_from("/unused.wav", "second"),
		"second concurrent clone was accepted")
	_expect(results.size() == 1 and results[0][0] == false,
		"concurrent clone rejection did not emit exactly one failure")
	voice._on_cloned({"id": 6})
	voice._on_error({"op": "clone", "id": 6, "code": "engine_error",
		"message": "stale"})
	_expect(int(voice._clone_request.get("id", 0)) == 7,
		"stale clone event cleared the active request")
	_expect(voice._outstanding == 1 and results.size() == 1,
		"stale clone event changed accounting or emitted a result")
	voice._on_cloned({"id": 7})
	_expect(voice._clone_request.is_empty() and voice._outstanding == 0,
		"matching cloned event did not finish its request")
	_expect(results.size() == 2 and results[1][0] == true,
		"matching cloned event did not emit success once")

	voice._clone_request = {"op": "clone", "id": 9, "name": ""}
	voice._outstanding = 1
	voice._deferred_native_requests = [{"op": "clone", "id": 9}]
	voice._forget_helper()
	_expect(int(voice._clone_request.get("id", 0)) == 9,
		"helper teardown lost the clone that must survive one restart")
	_expect(voice._outstanding == 1 and voice._deferred_native_requests.is_empty(),
		"helper teardown retained stale deferred work")
	voice._outstanding = 1
	voice._on_error({"op": "clone", "id": 9, "code": "engine_error",
		"message": "matching"})
	_expect(voice._clone_request.is_empty() and voice._outstanding == 0,
		"matching clone error did not finish its request")
	_expect(results.size() == 3 and results[2][0] == false,
		"matching clone error did not emit failure once")
	voice._clone_request = {"op": "clone", "id": 11, "name": ""}
	voice._clone_replays = Qwen3Voice.MAX_CLONE_REPLAYS
	voice._running_backend = Qwen3Voice.BACKEND_PYTHON
	voice._sync_outstanding()
	voice._handle_helper_death("replay budget exhausted")
	_expect(voice._clone_request.is_empty() and voice._outstanding == 0,
		"exhausted clone replay budget left a pending request")
	_expect(results.size() == 4 and results[3][0] == false,
		"exhausted clone replay budget did not emit exactly one failure")
	voice.free()


func _test_invalid_native_ready() -> void:
	var voice := Qwen3Voice.new()
	voice._running_backend = Qwen3Voice.BACKEND_NATIVE
	var failures: Array[String] = []
	voice.broke.connect(func(message: String) -> void: failures.append(message))
	voice._handle_line('{"event":"ready","protocol":1,"engine":"fake-qwen"}')
	_expect(not voice._native_ready and failures.size() == 1,
		"incompatible native ready was not rejected as startup failure")
	voice.free()


func _test_native_startup_timeout() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/startup-timeout-test")
	DirAccess.make_dir_recursive_absolute(root.path_join("spool"))
	var process := OS.execute_with_pipe("/bin/sleep", PackedStringArray(["30"]))
	_expect(not process.is_empty(), "could not create startup-timeout child")
	if process.is_empty():
		return
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._pid = int(process["pid"])
	voice._stdio = process["stdio"]
	voice._running_backend = Qwen3Voice.BACKEND_NATIVE
	voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
	voice._native_ready = false
	voice._native_ready_deadline_msec = 0
	voice._native_fallback_attempted = true
	voice._pending_say_ids = {12: true}
	voice._clone_request = {"op": "clone", "id": 13, "name": ""}
	voice._deferred_native_requests = [
		{"op": "say", "id": 12}, {"op": "clone", "id": 13}]
	voice._sync_outstanding()
	var clone_results: Array = []
	voice.voice_cloned.connect(func(ok: bool, message: String) -> void:
		clone_results.append([ok, message]))
	voice._process(1.0)
	_expect(voice._pid == -1 and voice._stdio == null and voice._running_backend.is_empty()
			and voice._pending_say_ids.is_empty()
			and voice._clone_request.is_empty() and voice._outstanding == 0,
		"native startup timeout did not terminate all deferred work")
	_expect(clone_results.size() == 1 and clone_results[0][0] == false,
		"native startup timeout did not finish clone exactly once")
	voice.free()
	_cleanup_ready_tree(root)


func _test_batch_generation_fence() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/batch-fence-test")
	DirAccess.make_dir_recursive_absolute(root.path_join("models"))
	var library := root.path_join("libqwen3tts.dylib")
	_touch(library)
	var old_python := OS.get_environment("GODOT_PET_PYTHON")
	var old_library := OS.get_environment("GODOT_PET_QWEN3_LIB")
	OS.set_environment("GODOT_PET_PYTHON", "/usr/bin/python3")
	OS.set_environment("GODOT_PET_QWEN3_LIB", library)
	var native := OS.execute_with_pipe("/bin/sleep", PackedStringArray(["30"]))
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._pid = int(native["pid"])
	voice._stdio = native["stdio"]
	voice._running_backend = Qwen3Voice.BACKEND_NATIVE
	voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
	voice._native_ready = false
	voice._spawn_generation = 1
	voice._pending_say_ids = {5: true}
	voice._clone_request = {"op": "clone", "id": 6, "name": ""}
	voice._deferred_native_requests = [
		{"op": "say", "id": 5}, {"op": "clone", "id": 6}]
	voice._sync_outstanding()
	var old_pid := voice._pid
	voice._handle_response_lines(PackedStringArray([
		'{"event":"ready","protocol":2,"engine":"qwen3-tts"}',
		'{"event":"audio","id":5,"path":"/must-not-read/5.pcm","rate":24000,"samples":2}',
		'{"event":"cloned","id":6}',
	]))
	_expect(voice._running_backend == Qwen3Voice.BACKEND_PYTHON
			and voice._pid != old_pid and voice._stdio != null,
		"invalid native ready did not fully replace pid/pipe/backend with Python")
	_expect(voice._pending_say_ids.has(5) and int(voice._clone_request.get("id", 0)) == 6,
		"old native batch tail was processed after fallback generation changed")
	_expect(voice._deferred_native_requests.is_empty() and voice._outstanding == 2,
		"fallback duplicated or lost preserved deferred requests")
	voice.shutdown()
	voice.free()
	OS.set_environment("GODOT_PET_PYTHON", old_python)
	OS.set_environment("GODOT_PET_QWEN3_LIB", old_library)
	DirAccess.remove_absolute(library)
	_cleanup_ready_tree(root)


func _test_dead_before_send_preserves_requests() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/dead-before-send-test")
	DirAccess.make_dir_recursive_absolute(root.path_join("models"))
	var library := root.path_join("libqwen3tts.dylib")
	_touch(library)
	var old_python := OS.get_environment("GODOT_PET_PYTHON")
	var old_library := OS.get_environment("GODOT_PET_QWEN3_LIB")
	OS.set_environment("GODOT_PET_PYTHON", "/usr/bin/python3")
	OS.set_environment("GODOT_PET_QWEN3_LIB", library)
	var native := OS.execute_with_pipe("/bin/sleep", PackedStringArray(["30"]))
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._pid = int(native["pid"])
	voice._stdio = native["stdio"]
	voice._running_backend = Qwen3Voice.BACKEND_NATIVE
	voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
	voice._native_ready = false
	voice._spawn_generation = 1
	voice._pending_say_ids = {21: true}
	voice._clone_request = {"op": "clone", "id": 22, "name": ""}
	voice._sync_outstanding()
	voice._send({"op": "clone", "id": 22, "wav": "/recording.wav", "out": "/voice.emb"})
	_expect(voice._deferred_native_requests.size() == 1,
		"live not-ready native did not defer clone exactly once")
	OS.kill(voice._pid)
	await get_tree().create_timer(0.05).timeout
	# The harness has observed/reaped the immediate exit. Keep the stale pipe so
	# `_send` must still take the unified teardown/fallback path after deferring.
	voice._pid = -1
	voice._send({"op": "say", "id": 21, "text": "queued after death"})
	_expect(voice._running_backend == Qwen3Voice.BACKEND_PYTHON
			and voice._deferred_native_requests.is_empty(),
		"dead-before-send request was lost instead of falling back once")
	_expect(voice._pending_say_ids.has(21)
			and int(voice._clone_request.get("id", 0)) == 22 and voice._outstanding == 2,
		"fallback snapshot lost or duplicated speak/clone accounting")
	voice._on_error({"op": "say", "id": 21, "code": "engine_error", "message": "terminal"})
	voice._on_error({"op": "clone", "id": 22, "code": "engine_error", "message": "terminal"})
	_expect(voice._outstanding == 0 and voice._pending_say_ids.is_empty()
			and voice._clone_request.is_empty(),
		"Python terminal events did not settle preserved requests exactly once")
	voice.shutdown()
	voice.free()
	OS.set_environment("GODOT_PET_PYTHON", old_python)
	OS.set_environment("GODOT_PET_QWEN3_LIB", old_library)
	DirAccess.remove_absolute(library)
	_cleanup_ready_tree(root)


func _test_nonexecutable_native_fallback() -> void:
	var root := ProjectSettings.globalize_path("user://qwen3_tts/native-fallback-test")
	DirAccess.make_dir_recursive_absolute(root.path_join("models"))
	var stale := root.path_join("godot-pet-tts-helper")
	var library := root.path_join("libqwen3tts.dylib")
	_write_bytes(stale, "stale, not executable".to_utf8_buffer())
	_touch(library)
	var old_python := OS.get_environment("GODOT_PET_PYTHON")
	var old_library := OS.get_environment("GODOT_PET_QWEN3_LIB")
	OS.set_environment("GODOT_PET_PYTHON", "/usr/bin/python3")
	OS.set_environment("GODOT_PET_QWEN3_LIB", library)
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._checked = true
	voice._reason = ""
	voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
	voice._helper = stale
	voice._models = root.path_join("models")
	var started := voice._start()
	if started and voice._running_backend == Qwen3Voice.BACKEND_NATIVE:
		for attempt in range(20):
			if not OS.is_process_running(voice._pid):
				break
			await get_tree().create_timer(0.02).timeout
		voice._handle_helper_death("stale native helper")
	_expect(voice._native_fallback_attempted,
		"nonexecutable/stale native helper did not attempt Python fallback")
	_expect(voice._backend_kind == Qwen3Voice.BACKEND_PYTHON,
		"native spawn failure did not switch to legacy Python backend")
	voice.shutdown()
	voice.free()
	OS.set_environment("GODOT_PET_PYTHON", old_python)
	OS.set_environment("GODOT_PET_QWEN3_LIB", old_library)
	DirAccess.remove_absolute(stale)
	DirAccess.remove_absolute(library)
	_cleanup_ready_tree(root)


func _test_real_helper_ready() -> void:
	var helper := ProjectSettings.globalize_path(
		"res://build/tts_helper_engine/godot-pet-tts-helper")
	if not FileAccess.file_exists(helper):
		print("Qwen3Voice integration: real helper ready test skipped (not built)")
		return
	var root := ProjectSettings.globalize_path("user://qwen3_tts/real-ready-test")
	DirAccess.make_dir_recursive_absolute(root.path_join("models"))
	var voice := Qwen3Voice.new()
	voice._work_root_override = root
	voice._checked = true
	voice._reason = ""
	voice._backend_kind = Qwen3Voice.BACKEND_NATIVE
	voice._helper = helper
	voice._models = root.path_join("models")
	voice._clone_replays = 1
	# Normal speak/clone increments this immediately after `_start`; keep polling
	# alive while this test queues without asking the real engine to synthesize.
	voice._outstanding = 1
	add_child(voice)
	_expect(voice._start(), "real editor helper could not be launched asynchronously")
	voice._send({"op": "say", "id": 99, "text": "must remain deferred"})
	_expect(not voice._native_ready and voice._deferred_native_requests.size() == 1,
		"native request was sent before ready validation")
	voice._deferred_native_requests.clear()
	for attempt in range(40):
		if voice._native_ready:
			break
		await get_tree().create_timer(0.05).timeout
	_expect(voice._native_ready, "real editor helper never produced compatible async ready")
	_expect(voice._clone_replays == 1,
		"native ready incorrectly reset the clone replay budget")
	voice._outstanding = 0
	voice._clone_request = {"op": "clone", "id": 77, "name": ""}
	voice._sync_outstanding()
	voice.set_process(false)
	voice._write_request({"op": "quit"})
	await get_tree().create_timer(0.1).timeout
	_expect(voice._ensure_running(), "pre-poll helper death did not restart")
	_expect(voice._clone_replays == 2 and voice._outstanding == 1,
		"pre-poll death did not use the unified clone replay accounting")
	voice._deferred_native_requests.clear()
	voice._clone_request = {}
	voice._clone_replays = 0
	voice._sync_outstanding()
	voice.shutdown()
	remove_child(voice)
	voice.free()
	_cleanup_ready_tree(root)


func _cleanup_ready_tree(root: String) -> void:
	var spool := root.path_join("spool")
	var directory := DirAccess.open(spool)
	if directory != null:
		for leaf in directory.get_files():
			DirAccess.remove_absolute(spool.path_join(leaf))
	DirAccess.remove_absolute(spool)
	DirAccess.remove_absolute(root.path_join("models"))
	for leaf in ["response.jsonl", "engine.log", "daemon.py"]:
		DirAccess.remove_absolute(root.path_join(leaf))
	DirAccess.remove_absolute(root)


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _make_wav(pcm: PackedByteArray, rate: int, channels: int, bits: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.append_array("RIFF".to_ascii_buffer())
	_append_u32(bytes, 36 + pcm.size())
	bytes.append_array("WAVEfmt ".to_ascii_buffer())
	_append_u32(bytes, 16)
	_append_u16(bytes, 1 if bits == 16 else 3)
	_append_u16(bytes, channels)
	_append_u32(bytes, rate)
	var block_align := channels * bits / 8
	_append_u32(bytes, rate * block_align)
	_append_u16(bytes, block_align)
	_append_u16(bytes, bits)
	bytes.append_array("data".to_ascii_buffer())
	_append_u32(bytes, pcm.size())
	bytes.append_array(pcm)
	return bytes


func _insert_junk_chunk(wav: PackedByteArray) -> PackedByteArray:
	var result := wav.slice(0, 12)
	result.append_array("JUNK".to_ascii_buffer())
	_append_u32(result, 3)
	result.append_array(PackedByteArray([1, 2, 3, 0]))
	result.append_array(wav.slice(12))
	_put_u32(result, 4, result.size() - 8)
	return result


func _append_u16(bytes: PackedByteArray, value: int) -> void:
	bytes.append(value & 0xff)
	bytes.append((value >> 8) & 0xff)


func _append_u32(bytes: PackedByteArray, value: int) -> void:
	bytes.append(value & 0xff)
	bytes.append((value >> 8) & 0xff)
	bytes.append((value >> 16) & 0xff)
	bytes.append((value >> 24) & 0xff)


func _put_u32(bytes: PackedByteArray, offset: int, value: int) -> void:
	for byte in range(4):
		bytes[offset + byte] = (value >> (byte * 8)) & 0xff
