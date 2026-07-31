extends Node
class_name ModelFetcher

## Downloads the two GGUF files `Qwen3Voice` needs, so a machine that has the
## engine but not the weights can get them without a terminal.
##
## **This deliberately fetches only the models.** A native helper now replaces
## the loose shared library on the preferred path, but its signed/notarized
## release bundle and manifest belong to the runtime-installer phase. Until that
## bundle exists there is no immutable binary URL this class can safely install.
## `Qwen3Voice._check()` therefore requires either the fixed development helper
## or the legacy Python + library engine first, and only offers this 1.7 GB
## download once one of those engines can consume it. Existing targets count as
## complete only at the exact published byte lengths; a zero/truncated file is
## downloaded to `.part`, verified, then atomically renamed over the old target.
##
## Why these two files and not the ones upstream's own README produces: those
## are made locally by `scripts/setup_pipeline_models.py`, which downloads ~5 GB
## of safetensors from HuggingFace and converts them with torch. Asking a desk
## pet's user to install torch is not a feature. These are the same artifacts,
## already converted, published by a third party.
##
## Which third party is not a coin toss. GGUF names its tensors, and two
## independent conversions of this model do **not** agree: measured against a
## known-working local file, `cstr/qwen3-tts-*-GGUF` — the most-downloaded
## conversion, made for CrispASR — differs on 109 of 478 tensor names in the
## talker (`speaker.blocks.0.conv.weight` where this loader wants
## `spk_enc.conv0.weight`) and on all 448 in the tokenizer, and declares
## `general.architecture=qwen3tts` where this loader wants `qwen3-tts`. It would
## download perfectly and fail to load. The files below were verified the same
## way and match on every tensor name, every shape, and the architecture string.
## **Re-run that check before changing a URL here** — the filename tells you
## nothing, and `tools/check_model_source.py` is the check.

## Where each file comes from, what it must be called once it lands, and how to
## know it arrived intact.
##
## `name` is not cosmetic: `src/qwen3_tts.cpp` hardcodes both filenames, and the
## tokenizer is spelled `-f16` there with no alternative accepted, so the file
## keeps that name regardless of what it was called upstream. The talker is
## looked for as q8_0 *before* f16, which is why the quantised one is worth
## fetching — it is half a gigabyte smaller and is the one the loader prefers.
const FILES := [
	{
		"url": "https://huggingface.co/khimaros/Qwen3-TTS-12Hz-0.6B-Base-GGUF/resolve/main/Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf",
		"name": "qwen3-tts-0.6b-q8_0.gguf",
		"sha256": "a2084cb3b7082670305779130e902c6d3207c770cd98b3977df4be077bf1f533",
		"bytes": 1342926400,
	},
	{
		"url": "https://huggingface.co/khimaros/Qwen3-TTS-Tokenizer-12Hz-GGUF/resolve/main/Qwen3-TTS-Tokenizer-12Hz-F16.gguf",
		"name": "qwen3-tts-tokenizer-f16.gguf",
		"sha256": "f553f984c8c82ef1881f4fdb6ff0f68c02f3ac710fd971b63d044cf6ab1c5fd2",
		"bytes": 341157120,
	},
]

## Shown wherever the download has to be described before it starts.
const TOTAL_BYTES := 1684083520
const SOURCE_LABEL := "HuggingFace（khimaros，Apache-2.0）"

## Partial downloads land here and are only renamed into place once the hash
## matches, so an interrupted download can never look like a usable model — the
## failure that would otherwise surface as the engine refusing to load, minutes
## later and with no visible connection to the download.
const PART_SUFFIX := ".part"

## How much of the file is hashed per frame. The check runs over 1.7 GB and the
## pet is a live animation, so doing it in one call would freeze the character
## for seconds. At this size the whole verification costs about a second, spread
## thinly enough not to drop a frame.
const HASH_CHUNK := 8 << 20

## Headroom over the download itself, for the filesystem and for the user. Disk
## filling up mid-download is a failure worth catching *before* spending twenty
## minutes of someone's bandwidth.
const SPACE_MARGIN := 300 << 20

## Progress, as a finished sentence ready for the bubble.
signal progress(text: String)
## Ended, either way. `ok` false covers refusal, failure and cancellation alike;
## the caller shows `message` and never branches on the reason.
signal finished(ok: bool, message: String)

enum Phase { IDLE, DOWNLOAD, HASH }

var _http: HTTPRequest
var _phase := Phase.IDLE
var _index := 0
var _dir := ""

var _hash: HashingContext
var _hash_file: FileAccess
var _hash_done := 0

## Bytes already on disk from files finished earlier this run, so the percentage
## covers the whole job rather than restarting at each file.
var _carried := 0


func _ready() -> void:
	set_process(false)
	_ensure_http()


## Built on demand rather than only in `_ready()`. `start()` used to assume that
## had already run, which is true when pet.gd adds this in its own `_ready()` and
## false the moment anything constructs one and calls `start()` in the same
## breath — where the symptom is an assignment to a null `download_file` and a
## `start()` that returned true having done nothing.
func _ensure_http() -> void:
	if _http != null:
		return
	_http = HTTPRequest.new()
	# Off the main thread: this writes gigabytes, and the pet has to keep moving
	# while it does. Godot's own download_file path still hands us the bytes
	# through the node, so nothing here becomes thread-unsafe.
	_http.use_threads = true
	# The default 64 KB chunk means more syscalls than a file this size needs.
	_http.download_chunk_size = 1 << 20
	# `_begin_file()` sets this to that entry's exact audited size before every
	# request. It is not left unlimited between different-size artifacts.
	_http.body_size_limit = 0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func is_running() -> bool:
	return _phase != Phase.IDLE


## Whether every file is already in place. Checked by size as well as existence:
## a `.part` left by an older interrupted run has the right name only after the
## rename, but a truncated file that somehow got there would otherwise be taken
## for a finished download.
static func has_models(dir: String) -> bool:
	return has_expected_files(dir, FILES)


static func has_expected_files(dir: String, entries: Array) -> bool:
	for entry in entries:
		if not file_matches_entry(dir.path_join(str(entry["name"])), entry):
			return false
	return true


static func file_matches_entry(path: String, entry: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var matches := file.get_length() == int(entry["bytes"])
	file.close()
	return matches


static func remaining_bytes(dir: String, entries: Array = FILES) -> int:
	var remaining := 0
	for entry in entries:
		if not file_matches_entry(dir.path_join(str(entry["name"])), entry):
			remaining += int(entry["bytes"])
	return remaining


static func required_free_bytes(dir: String, entries: Array = FILES) -> int:
	return remaining_bytes(dir, entries) + SPACE_MARGIN


static func completed_bytes(dir: String, entries: Array = FILES) -> int:
	var completed := 0
	for entry in entries:
		if file_matches_entry(dir.path_join(str(entry["name"])), entry):
			completed += int(entry["bytes"])
	return completed


## Start fetching into `dir`. Returns false when it could not begin, having
## already emitted `finished` with the reason — so the caller has one path.
## Disk headroom is based only on entries that are not already exact-size; a
## surviving talker means a tokenizer-only retry does not demand another 1.7 GB.
func start(dir: String) -> bool:
	if is_running():
		return false
	_ensure_http()
	_initialise_run(dir)

	if DirAccess.make_dir_recursive_absolute(_dir) != OK:
		_fail("沒辦法建立放模型的資料夾：%s" % _dir)
		return false
	var required := required_free_bytes(_dir)
	var free := _free_space(_dir)
	if free >= 0 and free < required:
		# Said before the download rather than after it fills the disk, and with
		# both numbers, because "空間不足" alone gives the user nothing to act on.
		_fail("磁碟空間不夠：還要 %s，這裡只剩 %s。" \
			% [size_text(required), size_text(free)])
		return false

	_begin_file()
	return true


## Stop and clean up. The partial file is deleted rather than kept: resuming is
## not implemented, so leaving it would only consume the space its own retry
## needs.
func cancel() -> void:
	if not is_running():
		return
	_http.cancel_request()
	_close_hash()
	_discard_part()
	_phase = Phase.IDLE
	set_process(false)
	finished.emit(false, "好，那我先不下載了。")


func _begin_file() -> void:
	_skip_completed_entries()
	if _index >= FILES.size():
		_succeed()
		return

	var entry: Dictionary = FILES[_index]
	_discard_part()
	_http.download_file = _part(_index)
	_set_current_body_limit()
	var error := _http.request(str(entry["url"]))
	if error != OK:
		_fail("連不上下載的網站（錯誤 %d）。" % error)
		return
	_phase = Phase.DOWNLOAD
	set_process(true)
	_report_download(0)


func _initialise_run(dir: String, entries: Array = FILES) -> void:
	_dir = dir
	_index = 0
	# Count every completed artifact, not only a prefix. A surviving tokenizer is
	# already progress even while the missing talker (index zero) downloads.
	_carried = completed_bytes(_dir, entries)


func _skip_completed_entries(entries: Array = FILES) -> void:
	while (_index < entries.size()
			and file_matches_entry(
				_dir.path_join(str(entries[_index]["name"])), entries[_index])):
		# `_initialise_run()` counted it regardless of position; only advance.
		_index += 1


func _set_current_body_limit() -> void:
	# Godot stores this property as signed int64; both audited sizes fit without
	# conversion through float.
	_http.body_size_limit = int(FILES[_index]["bytes"])


func _process(_delta: float) -> void:
	match _phase:
		Phase.DOWNLOAD:
			_report_download(_http.get_downloaded_bytes())
		Phase.HASH:
			_step_hash()


func _report_download(done: int) -> void:
	var total := TOTAL_BYTES
	var so_far := _carried + maxi(done, 0)
	# No "you can cancel in the menu" here: the bubble carries its own stop
	# button, the same way the recorder's does. A sentence pointing at a second
	# place to stop is one more thing to keep true.
	progress.emit("下載語音模型 %d%%（%s / %s）" \
		% [_percent(so_far, total), size_text(so_far), size_text(total)])


func _on_request_completed(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	if _phase != Phase.DOWNLOAD:
		# A cancel already tore this down; the signal is still delivered.
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_discard_part()
		_fail("下載中斷了（錯誤 %d）。網路穩定的時候再試一次。" % result)
		return
	if code != 200:
		_discard_part()
		# 404 here means the file moved upstream, which is a different problem
		# from a flaky connection and needs saying differently.
		var extra := "" if code != 404 else "\n檔案可能被搬走了，這要改程式才能修。"
		_fail("下載失敗（HTTP %d）。%s" % [code, extra])
		return
	_start_hash()


## Verifying is not optional, and not only against corruption. These files come
## from a third party over the network; the hash is what makes that a fixed,
## known artifact rather than whatever the URL happens to serve today.
func _start_hash() -> void:
	_hash_file = FileAccess.open(_part(_index), FileAccess.READ)
	if _hash_file == null:
		_discard_part()
		_fail("下載好的檔案讀不到（錯誤 %d）。" % FileAccess.get_open_error())
		return
	_hash = HashingContext.new()
	_hash.start(HashingContext.HASH_SHA256)
	_hash_done = 0
	_phase = Phase.HASH
	progress.emit("檢查下載的檔案…")


func _step_hash() -> void:
	var chunk := _hash_file.get_buffer(HASH_CHUNK)
	if not chunk.is_empty():
		_hash.update(chunk)
		_hash_done += chunk.size()
		return

	var digest := _hash.finish().hex_encode()
	var size := _hash_file.get_length()
	_close_hash()

	if (size != int(FILES[_index]["bytes"])
			or digest != str(FILES[_index]["sha256"])):
		_discard_part()
		_fail("下載的檔案跟原本的對不起來，可能中途壞掉了。再試一次看看。")
		return

	var error := DirAccess.rename_absolute(_part(_index), _target(_index))
	if error != OK:
		_discard_part()
		_fail("檔案存不進去（錯誤 %d）。" % error)
		return

	_carried += size
	_index += 1
	_begin_file()


func _succeed() -> void:
	_phase = Phase.IDLE
	set_process(false)
	finished.emit(true, "模型抓好了！")


func _fail(message: String) -> void:
	_close_hash()
	_phase = Phase.IDLE
	set_process(false)
	finished.emit(false, message)


func _close_hash() -> void:
	if _hash_file != null:
		_hash_file.close()
		_hash_file = null
	_hash = null


func _discard_part() -> void:
	var path := _part(_index)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _target(index: int) -> String:
	return _dir.path_join(str(FILES[index]["name"]))


func _part(index: int) -> String:
	return _target(index) + PART_SUFFIX


## Free bytes on the filesystem holding `path`, or -1 where that can't be
## answered. Godot exposes no API for this, so run `df` directly with the path as
## one argv element. No shell quoting or interpolation participates.
static func _free_space(path: String) -> int:
	var output := []
	if OS.execute("/bin/df", ["-Pk", path], output) != 0:
		return -1
	if output.is_empty():
		return -1
	var lines := str(output[0]).strip_edges().split("\n")
	if lines.size() < 2:
		return -1
	# POSIX order: filesystem, 1024-blocks, used, available, capacity, mount.
	var fields := lines[1].split(" ", false)
	if fields.size() < 4:
		return -1
	return int(fields[3]) * 1024


static func _percent(done: int, total: int) -> int:
	if total <= 0:
		return 0
	return clampi(roundi(100.0 * float(done) / float(total)), 0, 100)


static func size_text(bytes: int) -> String:
	if bytes >= 1 << 30:
		return "%.1f GB" % (float(bytes) / float(1 << 30))
	return "%d MB" % (bytes >> 20)
