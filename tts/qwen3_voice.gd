extends TTSBackend
class_name Qwen3Voice

## A local neural voice, from qwen3-tts.cpp running in a helper process.
##
## Everything here still happens on this machine — no API, no network, no cost —
## but unlike `OSVoice` it depends on three things the repository cannot carry:
## a built shared library, two model files totalling 2.1 GB, and a Python to
## drive them. So the whole class is written around one assumption: **on most
## machines this will not be present**, and the honest answer to that is a
## sentence naming what is missing, not a disabled row.
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

## Voices the project ships, copied out to `user://` on first run for the same
## reason `daemon.py` is: `res://` is inside the pack in an exported build and
## has nothing an outside process could open. Copied only when absent, never
## over the top — a voice the user re-cloned under a shipped name is theirs.
const SEED_DIR := "res://voices"
## Where every voice lives once it is usable, shipped or cloned alike. One folder
## rather than two, so nothing downstream has to know where a voice came from.
const VOICES_DIR := "voices"
const VOICE_EXTENSION := "emb"
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

## Emitted when a cloning attempt finishes, either way.
signal voice_cloned(ok: bool, message: String)

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

var _player: AudioStreamPlayer
var _queue: Array[AudioStreamWAV] = []

## Which check failed, as something other code can branch on. `_reason` is a
## sentence for a person and must stay one — matching on its wording is how a
## reworded message silently turns a feature off.
##
## Only `GAP_MODELS` is actionable from inside the app: the models can be
## downloaded, and nothing else here can. See ModelFetcher for why the library
## is not on that list.
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

## The one in-flight request that must survive a helper restart — see clone_from().
var _clone_request := {}
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


## Re-run discovery. Called every time the menu opens, so a library built or a
## model downloaded while the pet was running is picked up without a restart.
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


## Whether the models are the *only* thing missing, which is the one gap the app
## can close by itself.
##
## Deliberately not "are the models absent": `_check()` returns at the first
## failure, so on a machine with no engine at all this is false — and it has to
## be, or the pet would offer a 1.7 GB download that leaves the voice exactly as
## unavailable as it was. The library has to be there first.
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
	_gap = GAP_NONE

	if not _platform_supported():
		# Windows has no /bin/sh to launch through, which is the same wall
		# WorkService and PresenceService hit. Disabled, never hidden.
		_gap = GAP_PLATFORM
		_reason = "這個系統上還不能用本機語音。"
		return
	if FileAccess.get_file_as_bytes(DAEMON_SOURCE).is_empty():
		_gap = GAP_DAEMON
		_reason = "找不到 %s，這個版本可能沒把它打包進去。" % DAEMON_SOURCE
		return
	_python = _find_python()
	if _python.is_empty():
		_gap = GAP_PYTHON
		# Naming the setting matters here more than anywhere else in this list: a
		# pet launched from the GNOME dash or from Finder inherits a thin PATH
		# that never sourced a shell profile, so a pyenv/asdf/conda/nix python is
		# invisible to both the candidate list and `command -v`. The machine has
		# one; nothing here can see it, and only the user can say where.
		_reason = ("找不到 python3，本機語音要靠它驅動引擎。"
			+ "可以把路徑寫進 config.cfg 的 [tts] python，改完要重開我一次。")
		return
	# A path the user wrote down is not a first guess, it is the answer. Falling
	# through to the search when it doesn't exist means quietly loading a
	# *different* library than the one named — which on the machine this was
	# built on hid a broken override completely, because the search found the
	# real one and everything appeared to work.
	var stated := _stated("qwen3_lib", "GODOT_PET_QWEN3_LIB")
	if not stated.is_empty():
		if not FileAccess.file_exists(stated):
			_gap = GAP_LIBRARY
			_reason = "設定裡指定的 %s 不在那裡。" % stated
			return
		_library = stated
	else:
		_library = _find_library()
		if _library.is_empty():
			_gap = GAP_LIBRARY
			# Two routes, and they are not equivalent — which is exactly why both
			# are named. Dropping the file into the pet's own folder is picked up
			# the next time this menu opens; writing the path into config.cfg is
			# not, because Config reads that file once at startup.
			_reason = ("找不到 %s。編好 qwen3-tts.cpp 之後，把它放到 %s（開一次選單就會找到），"
				+ "或把路徑寫進 config.cfg 的 [tts] qwen3_lib 再重開我一次。") \
				% [_library_name(), _work_path("")]
			return

	stated = _stated("qwen3_models", "GODOT_PET_QWEN3_MODELS")
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
	if not FileAccess.file_exists(path.path_join(TOKENIZER_FILE)):
		return false
	for weights in WEIGHT_FILES:
		if FileAccess.file_exists(path.path_join(weights)):
			return true
	return false


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


func _work_path(leaf: String) -> String:
	var base := ProjectSettings.globalize_path(WORK_DIR)
	return base if leaf.is_empty() else base.path_join(leaf)


# --- Speaking -----------------------------------------------------------------

func speak(text: String) -> void:
	if not _ensure_running():
		return
	_next_id += 1
	_outstanding += 1
	_send({
		"op": "say", "id": _next_id, "text": text,
		"lang": str(Config.get_value("tts", "qwen3_language", "zh")),
		"voice": _voice_path(active_voice()),
	})
	set_process(true)


func stop() -> void:
	# Everything asked for so far is unwanted, including whatever is being
	# generated right now — the library cannot be interrupted mid-utterance, so
	# the audio may still arrive and has to be thrown away on this side.
	_epoch = _next_id
	_queue.clear()
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
	_outstanding = 0


## Driven from two places — a new stream arriving, and `_player.finished` — which
## is only safe because of two measured facts about Godot 4.7's AudioStreamPlayer:
## `stop()` does **not** emit `finished` (so a cancel cannot start the next item
## behind its own back), and a zero-length stream **does** (so a bad utterance can
## never leave the queue stalled with the player idle).
func _play_next() -> void:
	if _player.playing or _queue.is_empty():
		return
	_player.stream = _queue.pop_front()
	_player.play()


# --- The cloned voice ---------------------------------------------------------

## Every voice available here, by name, alphabetical. The empty string is not in
## it: that is the model's own default voice, which is always available and is
## not a file.
func list_voices() -> PackedStringArray:
	_seed_voices()
	var names := PackedStringArray()
	var dir := DirAccess.open(_work_path(VOICES_DIR))
	if dir == null:
		return names
	for file in dir.get_files():
		if file.get_extension().to_lower() == VOICE_EXTENSION:
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
	return name if name.is_empty() or FileAccess.file_exists(_voice_path(name)) else ""


## Persisted: which voice the pet has is a choice, not a default.
func set_active_voice(name: String) -> void:
	Config.set_value("tts", "qwen3_voice", name)


func delete_voice(name: String) -> bool:
	if name.is_empty() or not FileAccess.file_exists(_voice_path(name)):
		return false
	if DirAccess.remove_absolute(_voice_path(name)) != OK:
		return false
	if active_voice() == name:
		set_active_voice("")
	return true


## For the menu row that opens the folder, so a voice can be renamed or removed
## with the file manager. Renaming the file renames the voice, which is the whole
## reason the name is the filename and not a field inside it.
func voices_folder() -> String:
	_seed_voices()
	return _work_path(VOICES_DIR)


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
	var leaf := sanitise_voice_name(name)
	if leaf.is_empty():
		voice_cloned.emit(false, "這個名字我沒辦法拿來當檔名，換一個好嗎？")
		return false
	if not FileAccess.file_exists(wav_path):
		voice_cloned.emit(false, "找不到那個錄音檔。")
		return false
	if not _ensure_running():
		voice_cloned.emit(false, unavailable_reason() if not is_available()
			else "本機語音引擎起不來。")
		return false
	_next_id += 1
	_outstanding += 1
	# Kept, not just sent. A sentence lost with a dying helper is one gap in a
	# reply; a clone lost the same way is a button that did nothing and a user
	# still waiting, since `voice_cloned` is the only thing the panel and the pet
	# are listening for. This is the one request worth carrying across a restart.
	DirAccess.make_dir_recursive_absolute(_work_path(VOICES_DIR))
	_clone_request = {"op": "clone", "id": _next_id, "wav": wav_path,
		"out": _voice_path(leaf), "name": leaf}
	_send(_clone_request)
	set_process(true)
	return true


## Back to the model's own voice, keeping every cloned one on disk. Wiping them
## is what the folder is for.
func clear_cloned_voice() -> void:
	set_active_voice("")


## Empty name -> empty path, which the helper reads as "use the default voice".
func _voice_path(name: String) -> String:
	if name.is_empty():
		return ""
	return _work_path(VOICES_DIR).path_join("%s.%s" % [name, VOICE_EXTENSION])


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
	DirAccess.make_dir_recursive_absolute(target)
	var source := DirAccess.open(SEED_DIR)
	if source == null:
		return
	for file in source.get_files():
		if file.get_extension().to_lower() != VOICE_EXTENSION:
			continue
		var destination := target.path_join(file)
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
	# It died while we weren't looking. Clear up before trying again, so a stale
	# pipe is never written to — measured, Godot survives that (40 writes to a
	# killed child's pipe returned error 13 and nothing worse), but the write
	# silently goes nowhere and the pet would wait for a reply that cannot come.
	_forget_helper()
	return _start()


func _start() -> bool:
	if not is_available():
		return false
	if not _install_daemon():
		return false

	var response := _work_path("response.jsonl")
	DirAccess.remove_absolute(response)
	_offset = 0
	_pending = PackedByteArray()
	_clear_spool()

	var process := OS.execute_with_pipe("/bin/sh", PackedStringArray(["-c", _command()]))
	if process.is_empty():
		_fail("本機語音引擎起不來。")
		return false
	_pid = int(process["pid"])
	_stdio = process["stdio"]
	# stderr's pipe is never read — the helper redirects its own, so nothing is
	# written to it. Closing it here would close the same end the shell gave the
	# child on some platforms, so it is left to the process teardown.
	set_process(true)
	return true


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
		_fail("找不到 %s。" % DAEMON_SOURCE)
		return false
	DirAccess.make_dir_recursive_absolute(_work_path(""))
	DirAccess.make_dir_recursive_absolute(_work_path("spool"))
	var file := FileAccess.open(_work_path("daemon.py"), FileAccess.WRITE)
	if file == null:
		_fail("寫不出語音引擎的程式檔。")
		return false
	file.store_buffer(source)
	file.close()
	return true


func _clear_spool() -> void:
	var spool := _work_path("spool")
	var dir := DirAccess.open(spool)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute(spool.path_join(name))


func _send(request: Dictionary) -> void:
	if _stdio == null or _pid == -1 or not OS.is_process_running(_pid):
		return
	_stdio.store_line(JSON.stringify(request))
	_stdio.flush()


func _sh_quote(text: String) -> String:
	return "'%s'" % text.replace("'", "'\\''")


# --- Listening ----------------------------------------------------------------

func _process(delta: float) -> void:
	_since_poll += delta
	if _since_poll < POLL:
		return
	_since_poll = 0.0
	_drain()
	# Checked after draining, so a helper that wrote its reason and then exited
	# still gets to say why — a fatal load error arrives on the line before the
	# process disappears, and reading it is what turns "it stopped" into a
	# sentence naming the file that wasn't there.
	if _pid != -1 and not OS.is_process_running(_pid):
		_forget_helper()
		if _restarts < MAX_RESTARTS:
			_restarts += 1
			push_warning("Qwen3Voice: the helper died; starting it again")
			# Whatever was in flight died with it. The audio already queued is
			# unaffected and keeps playing.
			_outstanding = 0
			if _start():
				if not _clone_request.is_empty():
					_outstanding += 1
					_send(_clone_request)
				return
		# States what happened and promises nothing. Whether there is anything to
		# fall back *to* is TTSService's question, not this backend's — and on a
		# machine with no Chinese system voice there isn't.
		_fail("本機語音的引擎停了。")
		return
	if _outstanding <= 0 and _queue.is_empty() and not _player.playing:
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
	for line in complete.get_string_from_utf8().split("\n", false):
		_handle_line(line)


func _handle_line(line: String) -> void:
	var data: Variant = JSON.parse_string(line)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var event := str(data.get("event", ""))
	match event:
		"ready":
			# It got all the way to loaded, so whatever killed the last one was
			# not a standing condition. Only a helper that comes back is worth
			# forgiving twice.
			_restarts = 0
		"audio":
			_on_audio(data)
		"cloned":
			_outstanding = maxi(0, _outstanding - 1)
			var named := str(_clone_request.get("name", ""))
			_clone_request = {}
			# Cloning a voice is also choosing it: nobody records a take, names it
			# and then wants to go on hearing the old one.
			if not named.is_empty():
				set_active_voice(named)
			voice_cloned.emit(true, "好，以後我就用「%s」這個聲音講話。" % named)
		"error":
			_on_error(data)


func _on_audio(data: Dictionary) -> void:
	_outstanding = maxi(0, _outstanding - 1)
	var path := str(data.get("path", ""))
	var bytes := FileAccess.get_file_as_bytes(path)
	# Removed whether or not it is wanted: the spool must not accumulate the
	# audio of everything the user interrupted.
	DirAccess.remove_absolute(path)
	if int(data.get("id", 0)) <= _epoch or bytes.is_empty():
		return

	var samples := int(data.get("samples", 0))
	var rate := int(data.get("rate", 24000))
	_watch_speed(int(data.get("ms", 0)), samples, rate)

	var stream := AudioStreamWAV.new()
	# Raw PCM16 rather than a .wav file, so nothing here depends on which Godot
	# version learned to parse one, and the helper needs no wav writer.
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = bytes
	_queue.append(stream)
	_play_next()


## Which request failed matters more than what it said, so the helper tags every
## error with the op that produced it. Matching on the message text instead would
## be matching on the wording of a C++ exception nobody here controls.
func _on_error(data: Dictionary) -> void:
	var message := str(data.get("message", ""))
	var code := str(data.get("code", ""))
	# A cancelled sentence is not a fault — it is the reply that keeps the
	# outstanding count honest after the user interrupted. Warning about each one
	# would fill the log every time somebody types over the pet mid-reply.
	if code != "cancelled" and code != "empty":
		push_warning("Qwen3Voice: %s" % message)
	match str(data.get("op", "")):
		"clone":
			_outstanding = maxi(0, _outstanding - 1)
			_clone_request = {}
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
			# One sentence going unsaid is survivable. Swapping the voice out
			# mid-reply would be far more alarming than the gap.
			_outstanding = maxi(0, _outstanding - 1)


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
		_clone_request = {}
		voice_cloned.emit(false, "換聲音的時候引擎停了，等一下再試一次好嗎？")
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_forget_helper()
	set_process(false)
	_outstanding = 0
	broke.emit(reason)
