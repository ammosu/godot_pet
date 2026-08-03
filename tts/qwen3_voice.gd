extends TTSBackend
class_name Qwen3Voice

## A local neural voice, from qwen3-tts.cpp running in a helper process.
##
## Everything here still happens on this machine — no API, no network, no cost —
## but unlike `OSVoice` it needs the two model files totalling 1.7 GB and either
## the fixed editor-build helper (Phase 2A) or the legacy Python + shared-library
## pair. A downloadable native runtime waits for Phase 2B's signed/hash-pinned
## installer. So the whole class is written around one assumption: **on most
## machines this will not be present**, and the honest answer is a sentence
## naming what is missing, not a disabled row.
##
## Why a helper process rather than a GDExtension: linking the library into Godot
## means shipping a per-platform binary and taking any crash inside the engine's
## own process. This is a desk pet. An optional voice must not be able to take
## the character down with it, and a child process is the containment that gives.
##
## Why resident rather than one CLI run per sentence: measured, loading the model
## costs 754 ms before a single character is synthesized, and the pet speaks in
## short sentences — warm synthesis of an eight-character line is 413 ms. Paying
## the load every time would nearly triple the wait for every line.
##
## Communication follows `WorkService` exactly, and for the same reason:
## `FileAccess` reads on a pipe **block**, so responses go to a regular file that
## is tailed by byte offset from `_process`. Requests go the other way over
## stdin, which is the direction `SecretStore` already proves is safe. The helper
## redirects its own stdout and stderr into a log file, because ggml and the CUDA
## runtime write banners and per-utterance timings there at a rate that would
## fill an undrained pipe and wedge the helper mid-sentence.

## Copied out of the pack at startup, because `res://` has no filesystem path in
## an exported build — the same thing that makes `res://.env` invisible there.
const DAEMON_SOURCE := "res://tools/qwen3_tts_daemon.py"
const WORK_DIR := "user://qwen3_tts"
const HELPER_PROTOCOL := 1
const HELPER_NAME := "godot-pet-tts-helper"
const BACKEND_NATIVE := "native"
const BACKEND_PYTHON := "python"

## A sentence from this app is bounded at forty characters, so a 64 MiB WAV is
## already far beyond any honest response. Keeping the cap here matters because
## the path arrives over a process boundary and the whole audio file has to be
## allocated before its RIFF chunks can be decoded.
const MAX_NATIVE_WAV_BYTES := 64 << 20
const MAX_WAV_CHUNKS := 64
const MAX_FMT_CHUNK_BYTES := 64
const LEGACY_MODEL_MIN_BYTES := 1 << 20

## Voices the project ships, copied out to `user://` on first run for the same
## reason `daemon.py` is: `res://` is inside the pack in an exported build and
## has nothing an outside process could open. Copied only when absent, never
## over the top — a voice the user re-cloned under a shipped name is theirs.
const SEED_DIR := "res://voices"
## Where every voice lives once it is usable, shipped or cloned alike. One folder
## rather than two, so nothing downstream has to know where a voice came from.
const VOICES_DIR := "voices"
const VOICE_EXTENSION := "emb"
const CACHE_DIR := "cache"
## Long enough to name a person, short enough to sit in a menu row.
const MAX_VOICE_NAME := 24

## Hardcoded on the library's side. The weights come in two spellings and
## `load_models()` prefers the quantised one where both are present — which
## neither the header nor the integration guide mentions, and which means a
## directory holding only q8_0 weights is perfectly valid and would be rejected
## by a check that knew about f16 alone.
const WEIGHT_FILES := ["qwen3-tts-0.6b-f16.gguf", "qwen3-tts-0.6b-q8_0.gguf"]
const TOKENIZER_FILE := "qwen3-tts-tokenizer-f16.gguf"

## How often the response file is checked. Synthesis takes hundreds of
## milliseconds, so a tighter poll would only cost syscalls.
const POLL := 0.05

## Enough utterances to tell a slow machine from one slow sentence.
const RTF_SAMPLES := 3
## Above this the engine generates slower than the audio plays, so the pet falls
## further behind with every sentence. Measured at 0.24-0.49 on an RTX 4090 and
## reported as ~1.7 CPU-only in the upstream integration guide.
const RTF_TOO_SLOW := 1.0

## Ceiling on the audio tokens one utterance may generate, at 12.5 per second.
##
## Generation does not reliably stop, and **the risk is almost entirely on the
## default voice**. Measured, same sentence, eight runs each: the default voice
## ran away once and wobbled once more (3.4 to 40.9 s), while `yu` and `anna`
## were 0 for 8 apiece and barely varied at all (3.3-4.3 s). The 61 lines
## `tools/hear.sh` renders are all in a cloned voice and none has ever run away.
##
## That is backwards from the obvious guess — a speaker embedding sounds like an
## extra constraint that could only make things harder — and it is worth
## remembering when reading anything else here: several rounds of measurement on
## this went wrong purely because the runs used no embedding and the app always
## does.
##
## It still has to be bounded, because the pet speaks in its own voice when no
## voice is chosen. Left alone the ceiling is 4096, which is **five and a half
## minutes** of the pet reading gibberish with every queued sentence stuck
## behind it — and worse than that, the compute graph is sized from the ceiling,
## so a run that never emits EOS asks for 21598 MiB of VRAM and takes the helper
## down with an out-of-memory instead. Measured both ways: at 4096 the runaway
## is a crash, at 512 it is 41 seconds of noise.
##
## 512 is 41 seconds. `TTSService` flushes at 40 characters, and a 30-character
## line measured 8.70 s — 109 tokens — so the longest thing that should ever
## arrive here is around 150. Erring high is deliberate: cutting a sentence off
## mid-word is a worse failure than the runaway this bounds, and the runaway has
## its own fix in the temperature setting rather than in this number.
##
## Verified by driving the daemon directly: 32 gave 2.54 s of audio (32/12.5),
## and 512 gave 40.94 s — that second one having run away, which is what a
## ceiling looks like when it works.
const MAX_AUDIO_TOKENS := 512

## Sampling temperature. The library defaults to 0.9, and that default is what
## makes the runaway above common: measured on one sentence, one voice, five
## runs per setting, the runs that ended normally were 1 at 0.9, 2 at 0.7, 5 at
## 0.5, and 0 at 0.3.
##
## **0.5 makes it rare, not impossible.** Fifteen runs at 0.5 were 10 good
## against 7 at 0.9 — a real improvement and nothing like the 5-for-5 the first
## small sample suggested. Neither setting replaces the other: this lowers the
## rate, `MAX_AUDIO_TOKENS` bounds the damage, and both are needed.
##
## A run of good sentences is not evidence that a value fixed anything. Every
## wrong conclusion drawn while investigating this — that 0.5 cured it, that only
## long lines were affected, that it was specific to one sentence — came from
## three to five samples that happened to agree. This engine is random enough to
## fake any pattern at that size; count at least fifteen.
##
## It fails at both ends and for opposite reasons — too high and sampling
## wanders off without ever drawing EOS, too low and greedy decoding never picks
## it (0.0 measured 60 s for a line that normally takes 7). So this is not
## "lower is safer": it has a floor as well as a ceiling, and the usable range
## is narrower than a knob like this usually implies.
##
## Lowering it also narrows how much a voice varies between takes, which is the
## trade being made. A pet that occasionally reads gibberish for forty seconds
## is worse than one that is slightly more even.
const DEFAULT_TEMPERATURE := 0.5

## How many times a helper that died is started again before the voice is given
## up on. One, for the same reason WorkService retries a stale session exactly
## once: two overlapping calls into this library abort the process outright
## rather than returning an error, so a crash is a thing that genuinely happens
## and losing the voice the user chose for the rest of the session over one of
## them is too harsh. Bounded, so a helper that cannot load never loops.
const MAX_RESTARTS := 1
const MAX_CLONE_REPLAYS := 2
const NATIVE_READY_TIMEOUT_MSEC := 5000

## Emitted when a cloning attempt finishes, either way.
signal voice_cloned(ok: bool, message: String)

## One pre-rendered line landed, or was given up on. `left` reaching zero is the
## end of the batch — including when it ends early, since `stop()` drops every
## outstanding request and the count has to reach zero either way or the caller
## waits forever for a line nobody is still making.
signal line_prerendered(done: int, left: int)

var _pid := -1
var _stdio: FileAccess = null
var _offset := 0
var _pending := PackedByteArray()
var _since_poll := 0.0

var _next_id := 0
## Anything asked for at or before this is no longer wanted — the audio may
## already have been generated by the time the cancel lands. Same shape as
## MemoryStore's `_epoch`, and for the same reason.
var _epoch := 0
## Requests sent that have not been answered — **every** kind, not just
## sentences. `_process` switches itself off when this reaches zero and nothing
## is playing, so a request that forgets to count itself here is a request whose
## reply is never read: cloning did exactly that, and the symptom was a voice
## file that appeared on disk while the pet said nothing at all about it.
var _outstanding := 0
## Every accepted sentence id until its one terminal audio/error event. The
## helper protocol is untrusted input even in development: duplicate or stale
## events must not decrement unrelated work or play twice.
var _pending_say_ids := {}
## id → the text being rendered into the cache, for requests that must not play.
var _cache_fills := {}
var _prerendered := 0

var _player: AudioStreamPlayer
var _queue: Array[AudioStreamWAV] = []

## Which check failed, as something other code can branch on. `_reason` is a
## sentence for a person and must stay one — matching on its wording is how a
## reworded message silently turns a feature off.
##
## Only `GAP_MODELS` is actionable from inside the app today: the models can be
## downloaded, while native-helper download and installation is the next phase.
const GAP_NONE := ""
const GAP_PLATFORM := "platform"
const GAP_DAEMON := "daemon"
const GAP_PYTHON := "python"
const GAP_LIBRARY := "library"
const GAP_MODELS := "models"
## The models are missing *and* the user has not pointed at a folder of their
## own. A stated path that is wrong is a different problem with a different fix,
## and downloading into `user://` would leave that path still wrong while
## appearing to work.
const GAP_MODELS_STATED := "models-stated"

var _checked := false
var _reason := ""
var _gap := GAP_NONE
var _library := ""
var _models := ""
var _python := ""
var _helper := ""
var _backend_kind := ""
var _running_backend := ""
var _native_ready := false
var _deferred_native_requests: Array[Dictionary] = []
var _native_ready_deadline_msec := 0
var _native_fallback_attempted := false
var _spawn_generation := 0
## Test seam for exercising the real child-process lifecycle without touching a
## person's actual user:// response/spool files.
var _work_root_override := ""

## The one in-flight request that must survive a helper restart — see clone_from().
var _clone_request := {}
var _clone_replays := 0
var _rtf: Array[float] = []
var _slow_reported := false
var _restarts := 0


func _ready() -> void:
	set_process(false)
	_player = AudioStreamPlayer.new()
	# Explicitly Master: RecorderService adds a muted "Record" bus, and a voice
	# that landed on it would generate perfectly and be inaudible.
	_player.bus = &"Master"
	_player.finished.connect(_play_next)
	add_child(_player)


func _exit_tree() -> void:
	shutdown()


# --- Availability -------------------------------------------------------------

func is_available() -> bool:
	_check()
	return _reason.is_empty()


func unavailable_reason() -> String:
	_check()
	return _reason


## Re-run discovery. Called every time the menu opens, so the fixed development
## helper/library build or a downloaded model is picked up without a restart.
##
## **It cannot pick up an edit to `config.cfg`**, and no amount of refreshing here
## would: `Config` loads that file once in its own `_ready()` and every
## `get_value` reads the in-memory copy. Which is why the messages in `_check()`
## name two routes and say which one needs the pet restarted — an instruction
## that silently does nothing is worse than no instruction.
func refresh() -> void:
	_checked = false
	# Asking for this voice again is asking for a clean slate: a session that
	# already spent its one retry would otherwise give up on the first stumble.
	_restarts = 0
	_slow_reported = false
	_native_fallback_attempted = false


## Whether the models are the *only* thing missing, which is the one gap the app
## can close by itself.
##
## Deliberately not "are the models absent": `_check()` returns at the first
## failure, so on a machine with no engine at all this is false — and it has to
## be, or the pet would offer a 1.7 GB download that leaves the voice exactly as
## unavailable as it was. The fixed editor helper or the legacy Python engine
## has to be there first; verified runtime installation is deferred to Phase 2B.
func needs_models() -> bool:
	_check()
	return _gap == GAP_MODELS


## Where a download should land. The first candidate `_find_models()` tries, so
## nothing has to be told about it afterwards — `refresh()` finds it on the next
## menu build.
func models_dir() -> String:
	return _work_path("models")


func voice_name() -> String:
	var name := active_voice()
	return "Qwen3・%s" % (name if not name.is_empty() else "預設嗓音")


## Cheap enough to run on every menu build: at worst four `file_exists` calls and
## one `which`, and the answer is cached until something asks for it again.
func _check() -> void:
	if _checked:
		return
	_checked = true
	_library = ""
	_models = ""
	_python = ""
	_helper = ""
	_backend_kind = ""
	_gap = GAP_NONE

	if not _platform_supported():
		# Windows has no /bin/sh to launch through, which is the same wall
		# WorkService and PresenceService hit. Disabled, never hidden.
		_gap = GAP_PLATFORM
		_reason = "這個系統上還不能用本機語音。"
		return
	_helper = _find_native_helper()
	if not _helper.is_empty():
		_backend_kind = choose_backend(_helper, false)
	else:
		# The native helper is preferred because it carries the engine boundary
		# itself. These checks are deliberately only the fallback: a signed helper
		# install must not also require Python or a loose dylib to light up the row.
		if not _check_python_engine():
			return
		_backend_kind = choose_backend("", true)

	var stated := _stated("qwen3_models", "GODOT_PET_QWEN3_MODELS")
	if not stated.is_empty():
		if not _holds_models(stated):
			_gap = GAP_MODELS_STATED
			_reason = "設定裡指定的 %s 裡沒有模型檔。" % stated
			return
		_models = stated
	else:
		_models = _find_models()
		if _models.is_empty():
			_gap = GAP_MODELS
			# The one gap in this list the app can close by itself, so the message
			# says so first and keeps the manual routes for the machine that would
			# rather not spend the bandwidth.
			_reason = ("還缺語音模型（%s 和 %s）。可以在「說話」選單裡叫我下載，"
				+ "或自己放到 %s，或把資料夾路徑寫進 config.cfg 的 [tts] qwen3_models "
				+ "再重開我一次。") \
				% [WEIGHT_FILES[1], TOKENIZER_FILE, _work_path("models")]
			return
	_reason = ""


static func choose_backend(native_helper: String, python_usable: bool) -> String:
	if not native_helper.is_empty():
		return BACKEND_NATIVE
	return BACKEND_PYTHON if python_usable else ""


## Discover the legacy Python engine. Kept separate from `_check()` so the
## native route can satisfy the engine requirement without touching Python or
## `libqwen3tts`, while an existing manual installation continues to work.
func _check_python_engine() -> bool:
	if FileAccess.get_file_as_bytes(DAEMON_SOURCE).is_empty():
		_gap = GAP_DAEMON
		_reason = "找不到本機語音 helper，也找不到 %s。" % DAEMON_SOURCE
		return false
	_python = _find_python()
	if _python.is_empty():
		_gap = GAP_PYTHON
		_reason = ("目前可測的開發版 native helper 不在固定的 build 路徑，也找不到 python3。"
			+ "舊版引擎可以把 Python 路徑寫進 config.cfg 的 [tts] python，"
			+ "改完要重開我一次；正式 helper 安裝會在下一階段開放。")
		return false
	# A path the user wrote down is not a first guess, it is the answer. Falling
	# through to the search when it doesn't exist means quietly loading a
	# *different* library than the one named.
	var stated := _stated("qwen3_lib", "GODOT_PET_QWEN3_LIB")
	if not stated.is_empty():
		if not FileAccess.file_exists(stated):
			_gap = GAP_LIBRARY
			_reason = "設定裡指定的 %s 不在那裡。" % stated
			return false
		_library = stated
	else:
		_library = _find_library()
		if _library.is_empty():
			_gap = GAP_LIBRARY
			_reason = ("找不到固定開發路徑裡的 native helper，也找不到舊版引擎的 %s。"
				+ "目前可以把編好的函式庫放到 %s（開一次選單就會找到），"
				+ "或把路徑寫進 config.cfg 的 [tts] qwen3_lib 再重開我一次；"
				+ "正式 helper 安裝會在下一階段開放。") \
				% [_library_name(), _work_path("")]
			return false
	return true


## What the user said, config first and then the environment — the same order
## Config.get_secret uses for the opposite reason: there a shell export is a
## one-off override, here a written-down path is the standing answer.
func _stated(key: String, variable: String) -> String:
	var value := str(Config.get_value("tts", key, ""))
	return value if not value.is_empty() else OS.get_environment(variable)


func _platform_supported() -> bool:
	return OS.has_feature("linux") or OS.has_feature("macos")


func _library_name() -> String:
	if OS.has_feature("macos"):
		return "libqwen3tts.dylib"
	if OS.has_feature("windows"):
		return "qwen3tts.dll"
	return "libqwen3tts.so"


## Phase 2A deliberately trusts only the project's fixed editor build location.
## `GODOT_PET_QWEN3_HELPER` and `runtime/current` are not consulted: executing
## either before the signed/hash-pinned installer exists would turn a filename
## and self-reported metadata into a trust decision. Exported builds therefore
## stay on the legacy Python path until Phase 2B installs a verified helper.
func _native_helper_candidates() -> PackedStringArray:
	return helper_candidates(ProjectSettings.globalize_path("res://"),
		OS.has_feature("editor"))


static func helper_candidates(project_root: String,
		include_development: bool) -> PackedStringArray:
	var candidates := PackedStringArray()
	if include_development:
		candidates.append(project_root.path_join(
			"build/tts_helper_engine/%s" % HELPER_NAME))
	return candidates


func _find_native_helper() -> String:
	for path in _native_helper_candidates():
		if path.is_absolute_path() and _validate_dev_helper(path):
			return path
	return ""


## Phase 2A's fixed development artifact gets a cheap static viability gate so
## it cannot authorize a 1.7 GB model download when it plainly cannot launch.
## This is not signature/runtime trust; Phase 2B still owns hashes, signing and
## the release manifest.
func _validate_dev_helper(path: String) -> bool:
	if _path_contains_link(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 4096:
		if file != null:
			file.close()
		return false
	var header := file.get_buffer(4096)
	file.close()
	var platform := "macos" if OS.has_feature("macos") else "linux"
	if not binary_supports_arch(header, platform, OS.has_feature("arm64")):
		return false
	# BSD/macOS installs the standalone utility in /bin, while Linux commonly
	# provides /usr/bin/test. Both are invoked directly with an argv array.
	var test_tool := "/usr/bin/test" if FileAccess.file_exists("/usr/bin/test") else "/bin/test"
	var ignored := []
	if not FileAccess.file_exists(test_tool) or OS.execute(test_tool, ["-x", path], ignored) != 0:
		return false
	return _macos_dependencies_resolve(path) if platform == "macos" else true


static func binary_supports_arch(header: PackedByteArray, platform: String,
		want_arm64: bool) -> bool:
	if platform == "linux":
		if header.size() < 20 or header.slice(0, 4) != PackedByteArray([0x7f, 0x45, 0x4c, 0x46]):
			return false
		var machine := _u16le(header, 18)
		return machine == (183 if want_arm64 else 62)
	if header.size() < 8:
		return false
	var magic := header.slice(0, 4)
	var wanted := 0x0100000c if want_arm64 else 0x01000007
	if magic == PackedByteArray([0xcf, 0xfa, 0xed, 0xfe]):
		return _u32le(header, 4) == wanted
	if magic == PackedByteArray([0xfe, 0xed, 0xfa, 0xcf]):
		return _u32be(header, 4) == wanted
	if magic == PackedByteArray([0xca, 0xfe, 0xba, 0xbe]):
		var count := _u32be(header, 4)
		if count <= 0 or count > 32 or header.size() < 8 + count * 20:
			return false
		for index in range(count):
			if _u32be(header, 8 + index * 20) == wanted:
				return true
	return false


func _macos_dependencies_resolve(path: String) -> bool:
	var canonical := _canonical_macos_dependency(path)
	if canonical.is_empty():
		return false
	return _macos_dependency_dfs(canonical, canonical.get_base_dir(),
		PackedStringArray(), {})


func _macos_dependency_dfs(path: String, executable_dir: String,
		inherited_rpaths: PackedStringArray, visited: Dictionary) -> bool:
	if visited.has(path):
		return true
	visited[path] = true
	var metadata := _read_macos_metadata(path)
	if metadata.is_empty():
		return false
	var rpaths := inherited_rpaths.duplicate()
	for raw in metadata["rpaths"]:
		var expanded := _expand_macos_path(str(raw), path.get_base_dir(), executable_dir)
		if expanded.is_empty() or not expanded.is_absolute_path():
			return false
		expanded = expanded.simplify_path()
		if not rpaths.has(expanded):
			rpaths.append(expanded)
	for dependency in metadata["dependencies"]:
		var raw_dependency := str(dependency)
		if _is_macos_system_dependency(raw_dependency):
			continue
		var resolved := _resolve_macos_dependency(raw_dependency,
			path.get_base_dir(), executable_dir, rpaths, true)
		if resolved.is_empty() or not _macos_dependency_dfs(
				resolved, executable_dir, rpaths, visited):
			return false
	return true


func _read_macos_metadata(path: String) -> Dictionary:
	var libraries := []
	if OS.execute("/usr/bin/otool", ["-L", path], libraries) != 0 or libraries.is_empty():
		return {}
	var loads := []
	if OS.execute("/usr/bin/otool", ["-l", path], loads) != 0 or loads.is_empty():
		return {}
	return parse_otool_metadata(str(libraries[0]), str(loads[0]))


static func parse_otool_metadata(libraries: String, loads: String) -> Dictionary:
	var dependencies := PackedStringArray()
	var library_lines := libraries.split("\n")
	if library_lines.is_empty() or not library_lines[0].strip_edges().ends_with(":"):
		return {}
	for line in library_lines.slice(1):
		var stripped := line.strip_edges()
		if stripped.is_empty():
			continue
		var suffix := stripped.find(" (")
		if suffix <= 0:
			return {}
		dependencies.append(stripped.substr(0, suffix))
	var rpaths := PackedStringArray()
	var expect_path := false
	for line in loads.split("\n"):
		var stripped := line.strip_edges()
		if expect_path and stripped.begins_with("Load command"):
			return {}
		if stripped == "cmd LC_RPATH":
			if expect_path:
				return {}
			expect_path = true
		elif expect_path and stripped.begins_with("path "):
			var value := stripped.trim_prefix("path ")
			var suffix := value.find(" (offset")
			if suffix <= 0:
				return {}
			rpaths.append(value.substr(0, suffix))
			expect_path = false
	if expect_path:
		return {}
	return {"dependencies": dependencies, "rpaths": rpaths}


static func _is_macos_system_dependency(path: String) -> bool:
	if not path.is_absolute_path():
		return false
	# Never simplify an escaping spelling into a trusted prefix. Mach-O load
	# commands are lexical input, and `/usr/lib/../../tmp/x` is not a system load.
	for component in path.split("/", false):
		if component == "..":
			return false
	var normalized := path.simplify_path()
	var root := ""
	if normalized.begins_with("/System/Library/"):
		root = "/System/Library"
	elif normalized.begins_with("/usr/lib/"):
		root = "/usr/lib"
	else:
		return false
	var root_output := []
	if OS.execute("/bin/realpath", [root], root_output) != 0 or root_output.is_empty():
		return false
	var canonical_root := str(root_output[0]).strip_edges()
	# Current macOS keeps many system dylibs only in dyld's shared cache, so an
	# individual file may not exist. When it does exist, require its physical path
	# to remain under the canonical system root; cache-only names retain the
	# already strict, traversal-free lexical classification above.
	if FileAccess.file_exists(normalized):
		var canonical := _canonical_macos_dependency(normalized)
		return (not canonical.is_empty()
			and canonical.begins_with(canonical_root + "/"))
	var cache_probe := []
	return (FileAccess.file_exists("/usr/bin/dyld_info")
		and OS.execute("/usr/bin/dyld_info", ["-dependents", normalized], cache_probe) == 0)


static func _expand_macos_path(path: String, loader: String,
		executable_dir: String) -> String:
	var expanded := path.replace("@loader_path", loader)
	expanded = expanded.replace("@executable_path", executable_dir)
	return "" if expanded.contains("@") else expanded


static func _dependency_candidates(dependency: String, loader: String,
		executable_dir: String, rpaths: PackedStringArray) -> PackedStringArray:
	var candidates := PackedStringArray()
	if dependency.begins_with("@rpath/"):
		var leaf := dependency.trim_prefix("@rpath/")
		for root in rpaths:
			candidates.append(root.path_join(leaf).simplify_path())
	elif dependency.begins_with("@loader_path/") or dependency.begins_with("@executable_path/"):
		var expanded := _expand_macos_path(dependency, loader, executable_dir)
		if not expanded.is_empty():
			candidates.append(expanded.simplify_path())
	elif dependency.is_absolute_path():
		candidates.append(dependency.simplify_path())
	return candidates


static func _canonical_macos_dependency(path: String) -> String:
	if path.is_empty() or not path.is_absolute_path() or not FileAccess.file_exists(path):
		return ""
	var output := []
	if OS.execute("/bin/realpath", [path], output) != 0 or output.is_empty():
		return ""
	var canonical := str(output[0]).strip_edges()
	if (canonical.is_empty() or not canonical.is_absolute_path()
			or not FileAccess.file_exists(canonical) or _path_contains_link(canonical)):
		return ""
	return canonical


static func _resolve_macos_dependency(dependency: String, loader: String,
		executable_dir: String, rpaths: PackedStringArray, canonicalize: bool) -> String:
	for candidate in _dependency_candidates(dependency, loader, executable_dir, rpaths):
		var resolved := (_canonical_macos_dependency(candidate)
			if canonicalize else candidate)
		if (not resolved.is_empty() and FileAccess.file_exists(resolved)
				and not _path_contains_link(resolved)):
			return resolved
	return ""


static func dev_dependencies_resolve(dependencies: PackedStringArray,
		rpaths: PackedStringArray, loader: String) -> bool:
	for dependency in dependencies:
		if _is_macos_system_dependency(dependency):
			continue
		var expanded_rpaths := PackedStringArray()
		for raw in rpaths:
			var expanded := _expand_macos_path(raw, loader, loader)
			if not expanded.is_empty():
				expanded_rpaths.append(expanded)
		if _resolve_macos_dependency(dependency, loader, loader,
				expanded_rpaths, false).is_empty():
			return false
	return true


## Pure fixture seam for the same DFS/path rules used by the otool-backed walk.
## Values are parsed metadata dictionaries keyed by physical image path.
static func dev_dependency_graph_resolves(graph: Dictionary, root: String,
		executable_dir: String) -> bool:
	return _dev_dependency_graph_dfs(graph, root, executable_dir,
		PackedStringArray(), {})


static func _dev_dependency_graph_dfs(graph: Dictionary, path: String,
		executable_dir: String, inherited_rpaths: PackedStringArray,
		visited: Dictionary) -> bool:
	if visited.has(path):
		return true
	if (not graph.has(path) or not FileAccess.file_exists(path)
			or _path_contains_link(path)):
		return false
	visited[path] = true
	var metadata: Dictionary = graph[path]
	if not metadata.has("dependencies") or not metadata.has("rpaths"):
		return false
	var rpaths := inherited_rpaths.duplicate()
	for raw in metadata["rpaths"]:
		var expanded := _expand_macos_path(str(raw), path.get_base_dir(), executable_dir)
		if expanded.is_empty() or not expanded.is_absolute_path():
			return false
		expanded = expanded.simplify_path()
		if not rpaths.has(expanded):
			rpaths.append(expanded)
	for dependency in metadata["dependencies"]:
		var raw_dependency := str(dependency)
		if _is_macos_system_dependency(raw_dependency):
			continue
		var resolved := _resolve_macos_dependency(raw_dependency,
			path.get_base_dir(), executable_dir, rpaths, false)
		if (resolved.is_empty() or not _dev_dependency_graph_dfs(
				graph, resolved, executable_dir, rpaths, visited)):
			return false
	return true


static func _u32be(bytes: PackedByteArray, offset: int) -> int:
	return ((int(bytes[offset]) << 24) | (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8) | int(bytes[offset + 3]))


## Search order, widest override first. The point of the list is that the two
## machine-specific answers — where the repository was cloned and where the
## models were downloaded — are the two things a fresh checkout cannot know, and
## the user should have to say each of them at most once.
func _find_library() -> String:
	var name := _library_name()
	var candidates := PackedStringArray()
	candidates.append(_work_path(name))
	candidates.append(OS.get_executable_path().get_base_dir().path_join("qwen3-tts").path_join(name))
	# The conventional dev layout: a clone with its build directory in place.
	var home := _home()
	if not home.is_empty():
		for parent in ["git_project", "src", "Projects", "code", ""]:
			var root := home.path_join(parent) if not parent.is_empty() else home
			candidates.append(root.path_join("qwen3-tts.cpp/build").path_join(name))
	# Homebrew's prefix on Apple Silicon, which is where a Mac would actually put
	# this — /usr/local is the Intel one, and neither is where /usr/lib is.
	candidates.append("/opt/homebrew/lib".path_join(name))
	candidates.append("/usr/local/lib".path_join(name))
	candidates.append("/usr/lib".path_join(name))
	for path in candidates:
		if not path.is_empty() and FileAccess.file_exists(path):
			return path
	return ""


## `<library>/../models` is the rule that carries the most weight here: given the
## library, the repository's own model directory is one level up, so finding one
## finds the other no matter where the clone lives.
func _find_models() -> String:
	var candidates := PackedStringArray()
	candidates.append(_work_path("models"))
	if not _library.is_empty():
		candidates.append(_library.get_base_dir().get_base_dir().path_join("models"))
	candidates.append(OS.get_executable_path().get_base_dir().path_join("qwen3-tts/models"))
	candidates.append("/opt/homebrew/share/qwen3-tts/models")
	candidates.append("/usr/local/share/qwen3-tts/models")
	candidates.append("/usr/share/qwen3-tts/models")
	for path in candidates:
		if not path.is_empty() and _holds_models(path):
			return path
	return ""


func _holds_models(path: String) -> bool:
	if ModelFetcher.has_models(path):
		return true
	# Compatibility for pre-downloader/manual f16 installations. There is no
	# audited byte size or digest for that talker artifact, so do not invent one:
	# require both substantial GGUF files and leave full tensor validation to the
	# real loader. The downloadable q8 pair above remains exact-size pinned.
	return (_looks_like_legacy_gguf(path.path_join(WEIGHT_FILES[0]))
		and _looks_like_legacy_gguf(path.path_join(TOKENIZER_FILE)))


static func _looks_like_legacy_gguf(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < LEGACY_MODEL_MIN_BYTES:
		if file != null:
			file.close()
		return false
	var magic := file.get_buffer(4)
	file.close()
	return magic == "GGUF".to_ascii_buffer()


## Well-known paths before shelling out, so the common case costs no process.
##
## The package managers' prefixes come **before** `/usr/bin` on macOS, and that
## order is the whole point: on a Mac without the Xcode command line tools,
## `/usr/bin/python3` exists as a stub that pops the "install the developer
## tools" dialog and exits — which `file_exists()` cannot tell from an
## interpreter. Preferring a real one where there is a real one costs nothing;
## where there isn't, the stub is still the only candidate and the failure lands
## at the first sentence rather than at the menu, which is why the launch log
## exists.
func _find_python() -> String:
	var candidates := PackedStringArray([
		str(Config.get_value("tts", "python", "")),
		OS.get_environment("GODOT_PET_PYTHON"),
	])
	if OS.has_feature("macos"):
		candidates.append_array(["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
			"/usr/bin/python3"])
	else:
		candidates.append_array(["/usr/bin/python3", "/usr/local/bin/python3",
			"/opt/homebrew/bin/python3"])
	for path in candidates:
		if _runs_python(path):
			return path
	var output := []
	if OS.execute("/bin/sh", ["-c", "command -v python3"], output) == 0 and not output.is_empty():
		var found := str(output[0]).strip_edges()
		if _runs_python(found):
			return found
	return ""


## Existing is not the same as working. `FileAccess.file_exists()` cannot tell an
## interpreter from the Command Line Tools stub macOS ships at
## `/usr/bin/python3`, which pops a "install the developer tools" dialog and
## exits — so a machine with no Python would report the voice *available*, offer
## the row, and fail at the first thing the pet tried to say.
##
## The cost is one process per candidate, at most once per session: `_check()`
## caches its answer and stops at the first candidate that runs.
func _runs_python(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var output := []
	return OS.execute(path, ["-c", "pass"], output) == 0


func _home() -> String:
	var home := OS.get_environment("HOME")
	return home if not home.is_empty() else OS.get_environment("USERPROFILE")


## Where pre-rendered lines for the voice currently selected are kept.
##
## Per voice, because the audio is the voice: switching to `tiffy` must not play
## back `lulu`. The default voice has no file and so no name, hence the literal —
## it cannot collide with a real one, which `sanitise_voice_name()` strips
## leading dots from.
##
## This folder is machine-owned, unlike the outbox. The names are hashes because
## the lookup is by exact text, and they carry the rate and sample count so a
## truncated or half-written file is rejected by the same parser that guards the
## helper's own output rather than played as noise.
func _report_prerender(ok: bool) -> void:
	if ok:
		_prerendered += 1
	line_prerendered.emit(_prerendered, _cache_fills.size())
	if _cache_fills.is_empty():
		_prerendered = 0


## Every outstanding fill given up on at once, for the paths that discard the
## whole queue rather than one request — `stop()` and a helper that died.
func _abandon_cache_fills() -> void:
	if _cache_fills.is_empty():
		return
	_cache_fills.clear()
	line_prerendered.emit(_prerendered, 0)
	_prerendered = 0


func _cache_dir() -> String:
	var voice := active_voice()
	return _work_path(CACHE_DIR).path_join(voice if not voice.is_empty() else ".default")


func _cache_key(text: String) -> String:
	return text.sha256_text()


## The cached file for this exact text, or "" — the text being the **respelled**
## one, since that is what `TTSService` hands every backend. A 破音字 rule that
## changes how a line is spoken therefore changes its key, so the old audio stops
## being found on its own. Nothing has to remember to clear it, and nothing can
## forget to: a cache that kept playing the pronunciation a new rule was written
## to fix would silently undo the whole table.
func _cached_path(text: String) -> String:
	var directory := _cache_dir()
	var dir := DirAccess.open(directory)
	if dir == null:
		return ""
	var prefix := _cache_key(text) + "-"
	for file in dir.get_files():
		if file.begins_with(prefix) and file.get_extension() == "wav" and not dir.is_link(file):
			return directory.path_join(file)
	return ""


func _cached_stream(text: String) -> AudioStreamWAV:
	var path := _cached_path(text)
	if path.is_empty():
		return null
	var parts := path.get_file().get_basename().split("-")
	if parts.size() != 3:
		return null
	var wav := parse_native_wav(FileAccess.get_file_as_bytes(path),
		int(parts[1]), int(parts[2]))
	if wav.is_empty():
		# Rejected rather than repaired: the next thing this function's caller
		# does is synthesise the line for real, so a bad cache file costs one
		# ordinary utterance and nothing else.
		push_warning("Qwen3Voice: ignoring unreadable cached line %s" % path.get_file())
		return null
	return TTSBackend.pcm_stream(wav["data"], int(wav["rate"]))


func _write_cache(directory: String, text: String, pcm: PackedByteArray, rate: int) -> void:
	var samples := pcm.size() >> 1
	if samples <= 0 or rate <= 0 or directory.is_empty() or text.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("%s-%d-%d.wav" % [_cache_key(text), rate, samples])
	if TTSBackend.pcm_stream(pcm, rate).save_to_wav(path) != OK:
		push_warning("Qwen3Voice: could not write cached line to %s" % path)


func _work_path(leaf: String) -> String:
	var base := (_work_root_override if not _work_root_override.is_empty()
		else ProjectSettings.globalize_path(WORK_DIR))
	return base if leaf.is_empty() else base.path_join(leaf)


# --- Speaking -----------------------------------------------------------------

func _sync_outstanding() -> void:
	_outstanding = _pending_say_ids.size() + (0 if _clone_request.is_empty() else 1)


func _consume_pending_say(request_id: int) -> bool:
	if request_id <= 0 or not _pending_say_ids.has(request_id):
		return false
	_pending_say_ids.erase(request_id)
	_sync_outstanding()
	return true

func speak(text: String) -> void:
	# **Before `_ensure_running()`, which is the whole point.** A nudge arrives at
	# least eight minutes after the last one (`Nudger.COOLDOWN_MINUTES`) and the
	# engine unloads after five (`qwen3_idle_seconds`), so the two can never
	# overlap: every unprompted line reloads the model and takes 2.6 GB of VRAM
	# back — measured — to say one of eighteen sentences that never change.
	var cached := _cached_stream(text)
	if cached != null:
		_queue.append(cached)
		_play_next()
		return
	if not _ensure_running():
		return
	_next_id += 1
	_pending_say_ids[_next_id] = true
	_sync_outstanding()
	_send({
		"op": "say", "id": _next_id, "text": text,
		"lang": str(Config.get_value("tts", "qwen3_language", "zh")),
		"voice": _voice_path(active_voice()),
	})
	set_process(true)


## Render `lines` to the cache without playing any of them.
##
## Returns how many were actually asked for: one that is already cached costs
## nothing, so re-running this after adding a 破音字 rule only redoes the lines
## that rule touched.
func prerender(lines: PackedStringArray) -> int:
	var wanted := PackedStringArray()
	for line in lines:
		var text := line.strip_edges()
		if not text.is_empty() and _cached_path(text).is_empty():
			wanted.append(text)
	if wanted.is_empty():
		return 0
	if not _ensure_running():
		return 0
	# The destination is fixed here rather than looked up when each line lands.
	# A batch takes about a second a line and switching voice is the obvious
	# thing to do next, so the folder can change mid-flight — and a fill that
	# followed it would file this voice's audio under the new one's name, which
	# plays as the wrong voice forever with nothing to show for it.
	var directory := _cache_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	for text in wanted:
		_next_id += 1
		_pending_say_ids[_next_id] = true
		_cache_fills[_next_id] = {"text": text, "dir": directory}
		_send({
			"op": "say", "id": _next_id, "text": text,
			"lang": str(Config.get_value("tts", "qwen3_language", "zh")),
			"voice": _voice_path(active_voice()),
		})
	_sync_outstanding()
	set_process(true)
	return wanted.size()


func stop() -> void:
	# Everything asked for so far is unwanted, including whatever is being
	# generated right now — the library cannot be interrupted mid-utterance, so
	# the audio may still arrive and has to be thrown away on this side.
	_epoch = _next_id
	_queue.clear()
	_pending_say_ids.clear()
	# A batch is abandoned by anything that stops the voice — the user typing,
	# a reply starting. Whatever already landed stays cached and the next run
	# picks up only what is still missing, so this costs nothing but time.
	_abandon_cache_fills()
	_sync_outstanding()
	_drop_deferred_say_requests()
	if _player != null:
		_player.stop()
	if _pid != -1:
		_send({"op": "cancel"})


func shutdown() -> void:
	stop()
	if not _clone_request.is_empty():
		# Answered before it is forgotten, and forgotten before the next helper
		# can inherit it. Left set, a clone abandoned here would be silently
		# replayed by a restart minutes later — the pet changing its voice in
		# response to a button pressed in a session that has since ended.
		_clone_request = {}
		_clone_replays = 0
		_sync_outstanding()
		voice_cloned.emit(false, "換聲音的事我沒做完，再按一次好嗎？")
	if _pid == -1:
		return
	_send({"op": "quit"})
	# Same rule CodexCli and WorkService follow: an OS.execute_with_pipe child
	# outlives the app, and an abandoned helper would hold the model and the GPU
	# for as long as the session lasts.
	if OS.is_process_running(_pid):
		OS.kill(_pid)
	_forget_helper()
	set_process(false)


## Let go of a helper that is gone or going. Closing the pipe is not optional:
## PresenceService documents the same fd leak, and this one is worse because a
## backend can be swapped away from and back several times in a session.
##
## Forgetting what it owed us belongs here too. Anything outstanding died with
## it, and a count left standing is a `_process` that never switches off.
func _forget_helper() -> void:
	if _stdio != null:
		_stdio.close()
		_stdio = null
	_pid = -1
	_sync_outstanding()
	_running_backend = ""
	_native_ready = false
	_native_ready_deadline_msec = 0
	_deferred_native_requests.clear()


## Every observed death funnels through here, whether found by `_process` or by
## `_ensure_running` before the next poll. Sentences are never replayed; the one
## clone request is, with a budget that ready events deliberately do not reset.
func _handle_helper_death(reason: String) -> bool:
	if _running_backend == BACKEND_NATIVE and not _native_ready:
		return _attempt_python_fallback(reason)
	_pending_say_ids.clear()
	_drop_deferred_say_requests()
	var has_clone := not _clone_request.is_empty()
	_forget_helper()
	_sync_outstanding()
	if has_clone:
		if _clone_replays >= MAX_CLONE_REPLAYS:
			_finish_clone_failure("換聲音時引擎一直停掉，這次先不再重試了。")
			_fail(reason)
			return false
		_clone_replays += 1
		push_warning("Qwen3Voice: helper died; replaying clone (%d/%d)" %
			[_clone_replays, MAX_CLONE_REPLAYS])
	elif _restarts < MAX_RESTARTS:
		_restarts += 1
		push_warning("Qwen3Voice: the helper died; starting it again")
	else:
		_fail(reason)
		return false
	if not _start():
		return false
	if has_clone and not _clone_request.is_empty():
		_send(_clone_request)
	return true


func _finish_clone_failure(message: String) -> void:
	if _clone_request.is_empty():
		return
	_clone_request = {}
	_clone_replays = 0
	_sync_outstanding()
	voice_cloned.emit(false, message)


## Driven from two places — a new stream arriving, and `_player.finished` — which
## is only safe because of two measured facts about Godot 4.7's AudioStreamPlayer:
## `stop()` does **not** emit `finished` (so a cancel cannot start the next item
## behind its own back), and a zero-length stream **does** (so a bad utterance can
## never leave the queue stalled with the player idle).
func _play_next() -> void:
	# The null check is not paranoia about `_ready()`: the cached path reaches
	# here without any helper traffic having happened first, so this is now
	# callable on a Qwen3Voice that was never put in the tree.
	if _player == null or _player.playing or _queue.is_empty():
		return
	_player.stream = _queue.pop_front()
	_player.play()


# --- The cloned voice ---------------------------------------------------------

## Every voice available here, by name, alphabetical. The empty string is not in
## it: that is the model's own default voice, which is always available and is
## not a file.
func list_voices() -> PackedStringArray:
	var names := PackedStringArray()
	if not _voices_dir_is_safe(false):
		return names
	_seed_voices()
	if not _voices_dir_is_safe(true):
		return names
	var dir := DirAccess.open(_work_path(VOICES_DIR))
	if dir == null:
		return names
	for file in dir.get_files():
		if file.get_extension() == VOICE_EXTENSION and not dir.is_link(file):
			names.append(file.get_basename())
	names.sort()
	return names


## Which one is speaking. Empty means the model's default voice — and it is the
## default *because* a fresh install has no cloned voice, not because it is
## preferred; `_seed_voices()` may well have put one there instead.
func active_voice() -> String:
	var name := str(Config.get_value("tts", "qwen3_voice", ""))
	# A voice deleted outside the app, or one whose file never arrived, must not
	# leave the pet mute — and must not leave the menu showing a tick on a row
	# that is no longer there.
	return name if name.is_empty() or _voice_file_is_valid(name) else ""


## Persisted: which voice the pet has is a choice, not a default.
func set_active_voice(name: String) -> void:
	Config.set_value("tts", "qwen3_voice",
		name if name.is_empty() or _voice_file_is_valid(name) else "")


func delete_voice(name: String) -> bool:
	var leaf := sanitise_voice_name(name)
	if leaf.is_empty() or leaf != name or not _voice_file_is_valid(leaf):
		return false
	var was_active := str(Config.get_value("tts", "qwen3_voice", "")) == leaf
	if DirAccess.remove_absolute(_voice_path(leaf)) != OK:
		return false
	if was_active:
		set_active_voice("")
	return true


## For the menu row that opens the folder, so a voice can be renamed or removed
## with the file manager. Renaming the file renames the voice, which is the whole
## reason the name is the filename and not a field inside it.
func voices_folder() -> String:
	if not _voices_dir_is_safe(false):
		return ""
	_seed_voices()
	return _work_path(VOICES_DIR) if _voices_dir_is_safe(true) else ""


func has_cloned_voice() -> bool:
	return not active_voice().is_empty()


## Take the pet's voice from a recording. `wav_path` is a real filesystem path —
## in practice something RecorderService wrote into the outbox folder.
##
## The reference does not have to be prepared: measured, the library resamples
## and downmixes internally, and an embedding taken from a 44.1 kHz stereo file
## matched the one from the same audio at 24 kHz mono to a cosine similarity of
## 0.999. Which means no ffmpeg, which is one fewer thing to install elsewhere.
func clone_from(wav_path: String, name: String) -> bool:
	if not _clone_request.is_empty():
		voice_cloned.emit(false, "我還在處理上一個聲音，完成後再試一次好嗎？")
		return false
	var leaf := sanitise_voice_name(name)
	if leaf.is_empty():
		voice_cloned.emit(false, "這個名字我沒辦法拿來當檔名，換一個好嗎？")
		return false
	if not FileAccess.file_exists(wav_path):
		voice_cloned.emit(false, "找不到那個錄音檔。")
		return false
	var target := _voice_path(leaf)
	if not _clone_output_is_safe(target):
		voice_cloned.emit(false, "聲音檔的位置不能是符號連結。")
		return false
	if not _ensure_running():
		voice_cloned.emit(false, unavailable_reason() if not is_available()
			else "本機語音引擎起不來。")
		return false
	# Recheck after directory creation/startup and immediately before handing the
	# path across the process boundary. The legacy daemon opens `<out>.part`
	# directly, so both predictable leaves belong to this check.
	if not _clone_output_is_safe(target):
		voice_cloned.emit(false, "聲音檔的位置不能是符號連結。")
		return false
	_next_id += 1
	# Kept, not just sent. A sentence lost with a dying helper is one gap in a
	# reply; a clone lost the same way is a button that did nothing and a user
	# still waiting, since `voice_cloned` is the only thing the panel and the pet
	# are listening for. This is the one request worth carrying across a restart.
	DirAccess.make_dir_recursive_absolute(_work_path(VOICES_DIR))
	_clone_request = {"op": "clone", "id": _next_id, "wav": wav_path,
		"out": target, "name": leaf}
	_clone_replays = 0
	_sync_outstanding()
	_send(_clone_request)
	set_process(true)
	return true


func _clone_output_is_safe(target: String) -> bool:
	return (not target.is_empty() and not _existing_path_has_link(target)
		and not _existing_path_has_link(target + ".part"))


## Back to the model's own voice, keeping every cloned one on disk. Wiping them
## is what the folder is for.
func clear_cloned_voice() -> void:
	set_active_voice("")


## Empty name -> empty path, which the helper reads as "use the default voice".
func _voice_path(name: String) -> String:
	if name.is_empty():
		return ""
	if sanitise_voice_name(name) != name:
		return ""
	return _work_path(VOICES_DIR).path_join("%s.%s" % [name, VOICE_EXTENSION])


func _voices_dir_is_safe(require_exists: bool) -> bool:
	var path := _work_path(VOICES_DIR)
	if _existing_path_has_link(path):
		return false
	if not DirAccess.dir_exists_absolute(path):
		return not require_exists
	return not _path_contains_link(path)


func _voice_file_is_valid(name: String) -> bool:
	if name.is_empty() or sanitise_voice_name(name) != name or not _voices_dir_is_safe(true):
		return false
	var leaf := "%s.%s" % [name, VOICE_EXTENSION]
	var dir := DirAccess.open(_work_path(VOICES_DIR))
	return (dir != null and dir.get_files().has(leaf) and not dir.is_link(leaf)
		and FileAccess.file_exists(_work_path(VOICES_DIR).path_join(leaf)))


## A voice name is a filename, so it is reduced to one — the same discipline
## OutboxService applies, and for a sharper reason: this name is typed by the
## user into a field that is one keystroke away from the chat input.
func sanitise_voice_name(raw: String) -> String:
	var leaf := raw.replace("\\", "/").get_file().strip_edges()
	while leaf.begins_with("."):
		leaf = leaf.substr(1)
	leaf = leaf.validate_filename().strip_edges()
	if leaf.length() > MAX_VOICE_NAME:
		leaf = leaf.substr(0, MAX_VOICE_NAME).strip_edges()
	return leaf


## Copy the shipped voices out once. Cheap enough to call from list_voices():
## after the first run every candidate already exists and this is one directory
## listing.
func _seed_voices() -> void:
	var target := _work_path(VOICES_DIR)
	if not _voices_dir_is_safe(false):
		return
	DirAccess.make_dir_recursive_absolute(target)
	if not _voices_dir_is_safe(true):
		return
	var source := DirAccess.open(SEED_DIR)
	if source == null:
		return
	for file in source.get_files():
		if file.get_extension() != VOICE_EXTENSION:
			continue
		var destination := target.path_join(file)
		if _existing_path_has_link(destination):
			push_warning("Qwen3Voice: refused linked seed voice '%s'" % file)
			continue
		if FileAccess.file_exists(destination):
			continue
		var bytes := FileAccess.get_file_as_bytes(SEED_DIR.path_join(file))
		if bytes.is_empty():
			continue
		var handle := FileAccess.open(destination, FileAccess.WRITE)
		if handle == null:
			push_warning("Qwen3Voice: cannot seed voice '%s'" % file)
			continue
		handle.store_buffer(bytes)
		handle.close()


# --- The helper ---------------------------------------------------------------

func _ensure_running() -> bool:
	if _pid != -1 and OS.is_process_running(_pid):
		return true
	if _pid != -1:
		# The pre-poll path must use the same accounting/replay policy as `_process`.
		return _handle_helper_death("本機語音的引擎停了。")
	return _start()


func _start() -> bool:
	if not is_available():
		return false
	if not _prepare_work_dirs():
		return false
	if _spawn_backend():
		return true
	if _backend_kind == BACKEND_NATIVE:
		return _attempt_python_fallback("開發版 native helper 無法啟動。")
	_fail("本機語音引擎起不來。")
	return false


func _spawn_backend() -> bool:
	if _backend_kind == BACKEND_PYTHON and not _install_daemon():
		return false

	var response := _work_path("response.jsonl")
	DirAccess.remove_absolute(response)
	_offset = 0
	_pending = PackedByteArray()
	_clear_spool()

	var process: Dictionary
	if _backend_kind == BACKEND_NATIVE:
		_native_ready = false
		process = OS.execute_with_pipe(_helper, _native_arguments())
	else:
		process = OS.execute_with_pipe("/bin/sh", PackedStringArray(["-c", _command()]))
	if process.is_empty():
		return false
	_pid = int(process["pid"])
	_stdio = process["stdio"]
	_running_backend = _backend_kind
	_spawn_generation += 1
	_native_ready_deadline_msec = (Time.get_ticks_msec() + NATIVE_READY_TIMEOUT_MSEC
		if _running_backend == BACKEND_NATIVE else 0)
	# stderr's pipe is never read — the helper redirects its own, so nothing is
	# written to it. Closing it here would close the same end the shell gave the
	# child on some platforms, so it is left to the process teardown.
	set_process(true)
	return true


## One fallback attempt per discovery session. Requests waiting behind native
## ready remain correlated and are written to Python only after its process has
## spawned. A helper that dies after it was ready uses the normal restart path;
## this fallback is only for spawn/startup incompatibility and timeout.
func _attempt_python_fallback(reason: String) -> bool:
	if _native_fallback_attempted:
		_fail(reason)
		return false
	_native_fallback_attempted = true
	var deferred := _deferred_native_requests.duplicate(true)
	var pending_says := _pending_say_ids.duplicate(true)
	var pending_clone := _clone_request.duplicate(true)
	if _pid != -1:
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		# Teardown is unconditional once a pid was owned; a dead child still has
		# a pipe and backend state that must not leak into Python fallback.
		_forget_helper()
	else:
		_forget_helper()
	_pending_say_ids = pending_says
	_clone_request = pending_clone
	_sync_outstanding()
	if not _check_python_engine():
		_fail(reason)
		return false
	_backend_kind = BACKEND_PYTHON
	if not _spawn_backend():
		_fail(reason)
		return false
	for request in deferred:
		var op := str(request.get("op", ""))
		var request_id := int(request.get("id", 0))
		if ((op == "say" and _pending_say_ids.has(request_id))
				or (op == "clone" and not _clone_request.is_empty()
					and request_id == int(_clone_request.get("id", -1)))):
			_write_request(request)
	return true


func _prepare_work_dirs() -> bool:
	var paths := PackedStringArray([
		_work_path(""), _work_path("spool"), _work_path(VOICES_DIR)])
	for path in paths:
		if _existing_path_has_link(path):
			_fail("本機語音的工作資料夾不能經過符號連結。")
			return false
	if (DirAccess.make_dir_recursive_absolute(paths[0]) != OK
			or DirAccess.make_dir_recursive_absolute(paths[1]) != OK
			or DirAccess.make_dir_recursive_absolute(paths[2]) != OK):
		_fail("沒辦法建立本機語音的工作資料夾。")
		return false
	for path in paths:
		if _path_contains_link(path):
			_fail("本機語音的工作資料夾不能經過符號連結。")
			return false
	# These are the predictable leaves opened with truncation/append by this app,
	# the native helper, or the legacy shell. Existing regular files retain the
	# normal restart behavior; a link hard-fails before any helper can spawn.
	for leaf in ["response.jsonl", "engine.log", "daemon.py"]:
		if _existing_path_has_link(_work_path(leaf)):
			_fail("本機語音的工作檔案不能是符號連結。")
			return false
	return true


static func _existing_path_has_link(path: String) -> bool:
	var normalized := path.simplify_path()
	if not normalized.is_absolute_path() or not normalized.begins_with("/"):
		return true
	var current := "/"
	for component in normalized.trim_prefix("/").split("/", false):
		var directory := DirAccess.open(current)
		if directory == null:
			return false
		if directory.is_link(component):
			return true
		current = current.path_join(component)
	return false


## The native process redirects stdout/stderr to `--log` before loading qwen,
## so it can be launched directly. Keeping the actual helper pid means quit,
## crash detection and the bounded restart retain the same lifecycle as the
## legacy shell+Python path.
func _native_arguments() -> PackedStringArray:
	return PackedStringArray([
		"--models", _models,
		"--out", _work_path("response.jsonl"),
		"--spool", _work_path("spool"),
		"--log", _work_path("engine.log"),
		"--threads", str(mini(8, maxi(2, OS.get_processor_count()))),
		"--idle", str(float(Config.get_value("tts", "qwen3_idle_seconds", 300.0))),
		"--protocol", str(HELPER_PROTOCOL),
		# The same two limits `_command()` passes the Python daemon, read from the
		# same config keys. The helper treats both as optional and falls back to
		# the library's defaults without them — which is the combination measured
		# to run away — so a backend that stops naming them goes quiet about it.
		"--max-tokens", str(int(Config.get_value("tts", "qwen3_max_tokens", MAX_AUDIO_TOKENS))),
		"--temperature", str(float(Config.get_value("tts", "qwen3_temperature", DEFAULT_TEMPERATURE))),
	])


## `exec` is load-bearing: without it the pid we keep is the shell's and the
## helper becomes its orphaned child, holding the model and the GPU with nothing
## able to stop it. Exactly the failure WorkService measured and documents.
func _command() -> String:
	# ggml installs its own terminate handler and, on an abort, forks **gdb** and
	# lets it print to stdout. Nothing here parses stdout, so that alone would be
	# survivable — but a crashing voice that stops to run a debugger takes seconds
	# to die, and the pet is waiting on the process to disappear before it can
	# fall back. Measured upstream: with this set the same crash writes nothing.
	var parts := PackedStringArray(["export", "GGML_NO_BACKTRACE=1;"])
	var extra := str(Config.get_value("tts", "qwen3_lib_path", ""))
	if not extra.is_empty():
		# An escape hatch for a library copied away from the build tree that
		# baked its RUNPATH: measured, the .so resolves libggml-cuda through an
		# absolute RUNPATH, which only holds where it was built.
		#
		# **On macOS this hatch may not open.** dyld strips `DYLD_*` when exec'ing
		# a restricted binary, and a system Python is exactly that — so exporting
		# it in the shell does not survive into the interpreter. Set here anyway,
		# since a Homebrew python is not restricted; a Mac that needs it and has
		# the system one has to move the ggml libraries beside the .so instead.
		var variable := "DYLD_LIBRARY_PATH" if OS.has_feature("macos") else "LD_LIBRARY_PATH"
		parts.append_array(["export", "%s=%s;" % [variable, _sh_quote(extra)]])
	parts.append_array([
		"exec", _sh_quote(_python), _sh_quote(_work_path("daemon.py")),
		"--lib", _sh_quote(_library),
		"--models", _sh_quote(_models),
		# Belt as well as braces, and the only one of the two that works on a Mac:
		# the helper opens these itself with RTLD_GLOBAL rather than trusting an
		# environment variable to survive the exec.
		"--lib-path", _sh_quote(extra if not extra.is_empty() else _library.get_base_dir()),
		"--out", _sh_quote(_work_path("response.jsonl")),
		"--spool", _sh_quote(_work_path("spool")),
		"--threads", str(mini(8, maxi(2, OS.get_processor_count()))),
		"--idle", str(float(Config.get_value("tts", "qwen3_idle_seconds", 300.0))),
		"--max-tokens", str(int(Config.get_value("tts", "qwen3_max_tokens", MAX_AUDIO_TOKENS))),
		"--temperature", str(float(Config.get_value("tts", "qwen3_temperature", DEFAULT_TEMPERATURE))),
		">%s" % _sh_quote(_work_path("engine.log")),
		"2>&1",
	])
	return " ".join(parts)


## Copied rather than run in place: `res://` is inside the pack in an exported
## build and has no path a Python interpreter could open. Copied every start
## rather than once, so an app update can never leave an old helper behind
## talking a protocol this build no longer speaks.
func _install_daemon() -> bool:
	var source := FileAccess.get_file_as_bytes(DAEMON_SOURCE)
	if source.is_empty():
		push_warning("Qwen3Voice: missing %s" % DAEMON_SOURCE)
		return false
	var file := FileAccess.open(_work_path("daemon.py"), FileAccess.WRITE)
	if file == null:
		push_warning("Qwen3Voice: cannot install legacy daemon")
		return false
	file.store_buffer(source)
	file.close()
	return true


func _clear_spool() -> void:
	var spool := _work_path("spool")
	if _path_contains_link(spool):
		push_warning("Qwen3Voice: refused to clear symlinked spool path")
		return
	var dir := DirAccess.open(spool)
	if dir == null:
		return
	for name in dir.get_files():
		if is_owned_spool_leaf(name) and not dir.is_link(name):
			DirAccess.remove_absolute(spool.path_join(name))


static func is_owned_spool_leaf(name: String) -> bool:
	var extension := name.get_extension()
	if extension != "wav" and extension != "pcm":
		return false
	var stem := name.get_basename()
	if stem.is_empty():
		return false
	for character in stem:
		if character < "0" or character > "9":
			return false
	var request_id := int(stem)
	return request_id > 0 and str(request_id) == stem


func _send(request: Dictionary) -> void:
	if _running_backend == BACKEND_NATIVE and not _native_ready:
		match str(request.get("op", "")):
			"say", "clone":
				_defer_request_once(request)
				if (_pid == -1 or _stdio == null or not OS.is_process_running(_pid)):
					_handle_helper_death("開發版 native helper 在接收請求前停止了。")
				return
			"cancel":
				_drop_deferred_say_requests()
				return
	if _stdio == null or _pid == -1 or not OS.is_process_running(_pid):
		if _pid != -1:
			_handle_helper_death("本機語音的引擎停了。")
		return
	_write_request(request)


func _defer_request_once(request: Dictionary) -> void:
	var op := str(request.get("op", ""))
	var request_id := int(request.get("id", 0))
	for existing in _deferred_native_requests:
		if str(existing.get("op", "")) == op and int(existing.get("id", -1)) == request_id:
			return
	_deferred_native_requests.append(request.duplicate(true))


func _write_request(request: Dictionary) -> void:
	if _stdio == null or _pid == -1 or not OS.is_process_running(_pid):
		return
	_stdio.store_line(JSON.stringify(request))
	_stdio.flush()


func _drop_deferred_say_requests() -> void:
	var kept: Array[Dictionary] = []
	for request in _deferred_native_requests:
		if str(request.get("op", "")) != "say":
			kept.append(request)
	_deferred_native_requests = kept


func _flush_deferred_native_requests() -> void:
	var requests := _deferred_native_requests
	_deferred_native_requests = []
	for request in requests:
		_write_request(request)


func _sh_quote(text: String) -> String:
	return "'%s'" % text.replace("'", "'\\''")


# --- Listening ----------------------------------------------------------------

func _process(delta: float) -> void:
	_since_poll += delta
	if _since_poll < POLL:
		return
	_since_poll = 0.0
	_drain()
	if (_pid != -1 and _running_backend == BACKEND_NATIVE and not _native_ready
			and Time.get_ticks_msec() >= _native_ready_deadline_msec):
		_attempt_python_fallback("開發版 native helper 啟動逾時。")
		return
	# Checked after draining, so a helper that wrote its reason and then exited
	# still gets to say why — a fatal load error arrives on the line before the
	# process disappears, and reading it is what turns "it stopped" into a
	# sentence naming the file that wasn't there.
	if _pid != -1 and not OS.is_process_running(_pid):
		_handle_helper_death("本機語音的引擎停了。")
		return
	if (_outstanding <= 0 and _queue.is_empty()
			and (_player == null or not _player.playing)):
		set_process(false)


## Read whatever is new, by byte offset. A regular file, so this never blocks —
## the whole reason the responses go to one.
func _drain() -> void:
	var file := FileAccess.open(_work_path("response.jsonl"), FileAccess.READ)
	if file == null:
		return
	var length := file.get_length()
	if length <= _offset:
		file.close()
		return
	file.seek(_offset)
	var chunk := file.get_buffer(length - _offset)
	file.close()
	_offset = length
	_pending.append_array(chunk)

	# Split on the newline **byte**: a read can end mid-character, and 0x0A
	# cannot occur inside a UTF-8 sequence, so this is the safe cut.
	var last_break := -1
	for i in range(_pending.size() - 1, -1, -1):
		if _pending[i] == 10:
			last_break = i
			break
	if last_break < 0:
		return
	var complete := _pending.slice(0, last_break)
	_pending = _pending.slice(last_break + 1)
	_handle_response_lines(complete.get_string_from_utf8().split("\n", false))


func _handle_response_lines(lines: PackedStringArray) -> void:
	var source_generation := _spawn_generation
	var source_backend := _running_backend
	var source_pid := _pid
	for line in lines:
		_handle_line(line)
		# A line can kill native and spawn Python. Every later line came from the
		# old response source and must not be reinterpreted as Python output.
		if (_spawn_generation != source_generation
				or _running_backend != source_backend or _pid != source_pid):
			return


func _handle_line(line: String) -> void:
	var data: Variant = JSON.parse_string(line)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var event := str(data.get("event", ""))
	if (_running_backend == BACKEND_NATIVE and not _native_ready
			and event != "ready"):
		_attempt_python_fallback("開發版 native helper 沒有先完成相容性確認。")
		return
	match event:
		"ready":
			_on_ready(data)
		"audio":
			_on_audio(data)
		"cloned":
			_on_cloned(data)
		"error":
			_on_error(data)


func _on_ready(data: Dictionary) -> void:
	if _running_backend == BACKEND_NATIVE:
		# JSON numbers are floats in Godot. Keep the type checks: `"1"` and a
		# truthy value are not protocol negotiation.
		if (typeof(data.get("protocol")) != TYPE_FLOAT
				or data.get("protocol") != float(HELPER_PROTOCOL)
				or typeof(data.get("engine")) != TYPE_STRING
				or data.get("engine") != "qwen3-tts"):
			_attempt_python_fallback("開發版 native helper 的通訊版本或引擎不相容。")
			return
		_native_ready = true
		_flush_deferred_native_requests()
	# It got all the way to ready, so whatever killed the last one was not a
	# standing condition. Python has no protocol fields and remains compatible.
	_restarts = 0


func _on_cloned(data: Dictionary) -> void:
	if (_clone_request.is_empty()
			or int(data.get("id", -1)) != int(_clone_request.get("id", -2))):
		push_warning("Qwen3Voice: ignored stale or unknown cloned event")
		return
	var named := str(_clone_request.get("name", ""))
	_clone_request = {}
	_clone_replays = 0
	_sync_outstanding()
	# Cloning a voice is also choosing it: nobody records a take, names it and
	# then wants to go on hearing the old one.
	if not named.is_empty():
		set_active_voice(named)
	voice_cloned.emit(true, "好，以後我就用「%s」這個聲音講話。" % named)


func _on_audio(data: Dictionary) -> void:
	var event_id := int(data.get("id", 0))
	if not _consume_pending_say(event_id):
		push_warning("Qwen3Voice: ignored stale, duplicate, or unknown audio event")
		return
	# Taken before any of the early returns below: a fill that is dropped still
	# has to be counted, or the batch never reaches zero and the caller waits on
	# a line nobody is still making.
	var fill: Dictionary = _cache_fills.get(event_id, {})
	_cache_fills.erase(event_id)
	var path := str(data.get("path", ""))
	var leaf := _expected_audio_leaf(event_id)
	var accepted_path := is_expected_spool_file(path, _work_path("spool"), leaf)
	var bytes := (read_expected_spool_file(path, _work_path("spool"), leaf)
		if accepted_path else PackedByteArray())
	# Removed whether or not it is wanted: the spool must not accumulate the
	# audio of everything the user interrupted.
	if accepted_path and is_expected_spool_file(path, _work_path("spool"), leaf):
		DirAccess.remove_absolute(path)
	if event_id <= _epoch or bytes.is_empty():
		if not fill.is_empty():
			_report_prerender(false)
		return

	var samples := int(data.get("samples", 0))
	var rate := int(data.get("rate", 24000))
	if _running_backend == BACKEND_NATIVE:
		var wav := parse_native_wav(bytes, rate, samples)
		if wav.is_empty():
			push_warning("Qwen3Voice: native helper returned an invalid PCM16 WAV")
			return
		bytes = wav["data"]
		rate = int(wav["rate"])
		samples = int(wav["samples"])
	if not fill.is_empty():
		# Written and never played. `_watch_speed` is skipped too: it exists to
		# say the voice is lagging behind speech, and during a batch there is no
		# speech to lag behind — the warning would be true of the number and
		# wrong about what it means.
		_write_cache(str(fill.get("dir", "")), str(fill.get("text", "")), bytes, rate)
		_report_prerender(true)
		return
	_watch_speed(int(data.get("ms", 0)), samples, rate)

	_queue.append(TTSBackend.pcm_stream(bytes, rate))
	_play_next()


func _expected_audio_leaf(event_id: int) -> String:
	if event_id <= 0:
		return ""
	if _running_backend == BACKEND_NATIVE:
		return "%d.wav" % event_id
	if _running_backend == BACKEND_PYTHON:
		return "%d.pcm" % event_id
	return ""


## The event id and backend determine the only filename that can be read. A
## lexical parent check alone is insufficient because a symlink inside that
## directory could point at an unrelated file.
static func is_expected_spool_file(path: String, spool: String,
		expected_leaf: String) -> bool:
	if path.is_empty() or expected_leaf.is_empty() or not path.is_absolute_path():
		return false
	if path != spool.path_join(expected_leaf):
		return false
	if _path_contains_link(spool):
		return false
	var directory := DirAccess.open(spool)
	return (directory != null and not directory.is_link(expected_leaf)
		and FileAccess.file_exists(path))


static func _path_contains_link(path: String) -> bool:
	var normalized := path.simplify_path()
	if not normalized.is_absolute_path() or not normalized.begins_with("/"):
		return true
	var current := "/"
	for component in normalized.trim_prefix("/").split("/", false):
		var directory := DirAccess.open(current)
		if directory == null or directory.is_link(component):
			return true
		current = current.path_join(component)
	return false


## Inspect links and size both before and after the read. Godot FileAccess does
## not expose O_NOFOLLOW or descriptor-relative opens, so this does not claim to
## defeat a malicious same-account process racing path replacement. Phase 2A's
## fixed development helper is trusted at that boundary; these checks prevent
## accidental/stale path traversal and ordinary symlink substitution.
static func read_expected_spool_file(path: String, spool: String,
		expected_leaf: String) -> PackedByteArray:
	if not is_expected_spool_file(path, spool, expected_leaf):
		return PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var length := file.get_length()
	if length <= 0 or length > MAX_NATIVE_WAV_BYTES:
		file.close()
		push_warning("Qwen3Voice: refused oversized or empty audio file")
		return PackedByteArray()
	var bytes := file.get_buffer(length)
	var final_length := file.get_length()
	file.close()
	if (bytes.size() != length or final_length != length
			or not is_expected_spool_file(path, spool, expected_leaf)):
		return PackedByteArray()
	return bytes


## Parse the native helper's PCM16 WAV rather than feeding its 44-byte RIFF
## header to AudioStreamWAV as samples. Chunk lengths are checked before every
## seek/slice, and neither the file's fmt nor data length can trigger an
## unbounded allocation here.
static func parse_native_wav(bytes: PackedByteArray, expected_rate: int,
		expected_samples: int) -> Dictionary:
	if (bytes.size() < 44 or bytes.size() > MAX_NATIVE_WAV_BYTES
			or _fourcc(bytes, 0) != "RIFF" or _fourcc(bytes, 8) != "WAVE"):
		return {}
	var riff_size := _u32le(bytes, 4)
	if riff_size < 36 or riff_size + 8 != bytes.size():
		return {}

	var cursor := 12
	var chunks := 0
	var found_fmt := false
	var found_data := false
	var pcm := PackedByteArray()
	var rate := 0
	while cursor < bytes.size():
		chunks += 1
		if chunks > MAX_WAV_CHUNKS or cursor + 8 > bytes.size():
			return {}
		var kind := _fourcc(bytes, cursor)
		var chunk_size := _u32le(bytes, cursor + 4)
		var content := cursor + 8
		if chunk_size > bytes.size() - content:
			return {}
		var chunk_end := content + chunk_size
		match kind:
			"fmt ":
				if found_fmt or chunk_size < 16 or chunk_size > MAX_FMT_CHUNK_BYTES:
					return {}
				found_fmt = true
				var audio_format := _u16le(bytes, content)
				var channels := _u16le(bytes, content + 2)
				rate = _u32le(bytes, content + 4)
				var byte_rate := _u32le(bytes, content + 8)
				var block_align := _u16le(bytes, content + 12)
				var bits := _u16le(bytes, content + 14)
				if (audio_format != 1 or channels != 1 or bits != 16
						or block_align != 2 or rate <= 0
						or byte_rate != rate * block_align):
					return {}
			"data":
				if (found_data or chunk_size <= 0 or chunk_size > MAX_NATIVE_WAV_BYTES
						or chunk_size % 2 != 0):
					return {}
				found_data = true
				pcm = bytes.slice(content, chunk_end)
		cursor = chunk_end + (chunk_size & 1)
		if cursor > bytes.size():
			return {}
	if cursor != bytes.size() or not found_fmt or not found_data:
		return {}
	var samples := pcm.size() >> 1
	if (expected_rate <= 0 or rate != expected_rate or expected_samples <= 0
			or samples != expected_samples):
		return {}
	return {"data": pcm, "rate": rate, "samples": samples}


static func _fourcc(bytes: PackedByteArray, offset: int) -> String:
	if offset < 0 or offset + 4 > bytes.size():
		return ""
	return bytes.slice(offset, offset + 4).get_string_from_ascii()


static func _u16le(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)


static func _u32le(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) | (int(bytes[offset + 1]) << 8)
		| (int(bytes[offset + 2]) << 16) | (int(bytes[offset + 3]) << 24))


## Which request failed matters more than what it said, so the helper tags every
## error with the op that produced it. Matching on the message text instead would
## be matching on the wording of a C++ exception nobody here controls.
func _on_error(data: Dictionary) -> void:
	var message := str(data.get("message", ""))
	var code := str(data.get("code", ""))
	var op := str(data.get("op", ""))
	if (op == "clone" and (_clone_request.is_empty()
			or int(data.get("id", -1)) != int(_clone_request.get("id", -2)))):
		push_warning("Qwen3Voice: ignored stale or unknown clone error")
		return
	if op == "say":
		var failed_id := int(data.get("id", 0))
		if not _consume_pending_say(failed_id):
			if code != "cancelled" and code != "empty":
				push_warning("Qwen3Voice: ignored stale, duplicate, or unknown say error")
			return
		# A line that failed is one the batch is no longer waiting for. Nothing
		# is written, so the next run simply asks for it again.
		if _cache_fills.erase(failed_id):
			_report_prerender(false)
	elif op != "clone" and op != "load":
		push_warning("Qwen3Voice: ignored error with unknown op")
		return
	# A cancelled sentence is not a fault — it is the reply that keeps the
	# outstanding count honest after the user interrupted. Warning about each one
	# would fill the log every time somebody types over the pet mid-reply.
	if code != "cancelled" and code != "empty":
		push_warning("Qwen3Voice: %s" % message)
	match op:
		"clone":
			_clone_request = {}
			_clone_replays = 0
			_sync_outstanding()
			# The likely failure by far, and the one worth naming: the engine
			# takes a speaker embedding out of a silent room without complaint
			# and the pet then talks in a voice nobody picked.
			if code == "silent":
				voice_cloned.emit(false, "這段幾乎沒有聲音，我聽不出是誰。要不要再錄一段？")
			else:
				voice_cloned.emit(false, "這段錄音沒辦法拿來當聲音。")
		"load":
			# Fatal: without the model there is no backend. Note the log, because
			# a failed `qwen3_tts_create` deletes its own error message before
			# returning — stderr is genuinely the only account of what happened.
			_fail("本機語音載不起來，詳情在 %s。" % _work_path("engine.log"))
		_:
			# One correlated sentence going unsaid is survivable. Swapping the
			# voice out mid-reply would be far more alarming than the gap.
			pass


## Whether this machine can keep up, measured rather than assumed. A CPU-only
## build runs at roughly 1.7x realtime upstream, which means the pet falls
## further behind with every sentence — worth saying once, and worth *only*
## saying, since a voice that lags is still a voice.
func _watch_speed(ms: int, samples: int, rate: int) -> void:
	if _slow_reported or samples <= 0 or rate <= 0 or ms <= 0:
		return
	_rtf.append((ms / 1000.0) / (float(samples) / float(rate)))
	if _rtf.size() < RTF_SAMPLES:
		return
	var total := 0.0
	for value in _rtf:
		total += value
	if total / _rtf.size() > RTF_TOO_SLOW:
		_slow_reported = true
		warned.emit("這台機器合成聲音比我講話還慢，我可能會愈拖愈久。想順一點的話，可以在選單把聲音換回系統語音。")
	_rtf.clear()


## The single give-up point, so nothing is left holding a model behind us.
##
## What is already queued stops too, and deliberately: `broke` makes TTSService
## swap this backend out, which calls `shutdown()` — and the pet is about to say
## out loud that its voice broke. Two more sentences in the old voice playing
## underneath that would read as the failure notice being the thing that is wrong.
func _fail(reason: String) -> void:
	if not _clone_request.is_empty():
		# Somebody is waiting on a button they pressed. Answering the general
		# failure is not enough — nothing else will ever emit voice_cloned.
		_finish_clone_failure("換聲音的時候引擎停了，等一下再試一次好嗎？")
	_pending_say_ids.clear()
	_deferred_native_requests.clear()
	# Same reason the clone above is answered: a batch waiting on a helper that
	# is gone would otherwise leave the menu row saying it is still working for
	# the rest of the session.
	_abandon_cache_fills()
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_forget_helper()
	set_process(false)
	_sync_outstanding()
	broke.emit(reason)
