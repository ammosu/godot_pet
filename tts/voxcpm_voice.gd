extends TTSBackend
class_name VoxCPMVoice

## VoxCPM2, through the HTTP service running on this machine.
##
## Local — nothing leaves the machine, nothing is billed — but
## reached the way `ElevenVoice` is reached, which is most of the point. The
## engine lives in somebody else's process, so this class has no child to spawn,
## no spool to guard, no crash to survive and no model to load; a sentence is one
## POST and one `load_from_buffer`.
##
## Measured against the in-process engine it replaced, on the same line and the same
## voice: 0.63–0.83 s end to end against 383–1278 ms *plus* a 754 ms model load,
## which a nudge always pays because it arrives at least eight minutes after the
## last one and the engine unloads after five.
##
## The service serialises internally — one worker, by correctness requirement,
## since concurrent calls into VoxCPM2 silently corrupt the output rather than
## failing — so this queues on its side too and backs off when told the queue is
## full.

const TTS_PATH := "/v1/tts"
const VOICES_PATH := "/v1/voices"
const HEALTH_PATH := "/health"
const DEFAULT_URL := "http://127.0.0.1:8080"

## Long: the service's own ceiling is 180 s, and a request that outlives it
## should be ended by the service saying 504 rather than by us giving up first
## and leaving it generating audio nobody will read.
const REQUEST_TIMEOUT := 190.0

## The service answers 503 when its queue is full and asks callers to back off.
## Three tries over a few seconds covers a burst; past that the pet is better off
## saying so than queueing sentences nobody is waiting for any more.
const MAX_RETRIES := 3
const RETRY_SECONDS := 1.5

const CACHE_DIR := "user://voxcpm/cache"

## Optional, and empty is the normal case: the service leaves auth off while it
## is bound to 127.0.0.1, and only needs a key once it is reachable from another
## machine. Sent as a bearer token, which it accepts alongside X-API-Key.
const KEY_NAME := "VOXCPM_API_KEY"

## The menu row that pastes one, named here so the sentence telling the user to
## go and click it cannot drift from what the row actually says.
const KEY_ROW_LABEL := "設定 VoxCPM 金鑰…"

var _http: HTTPRequest
var _meta_http: HTTPRequest
var _player: AudioStreamPlayer

var _pending: Array[Dictionary] = []
var _queue: Array[AudioStream] = []
var _current := {}
var _retries := 0

## Bumped by `stop()`. A request already sent cannot be unsent, so its audio
## still arrives and has to be recognised as unwanted.
var _epoch := 0
var _request_epoch := 0

var _voices: Array = []
var _healthy := true
var _reason := ""
## An explicit library refresh requested while the metadata client is busy waits
## for that request to finish, then asks /v1/voices. Opening the menu starts a
## health check just before the user can press the refresh row, so rejecting a
## busy client here would make the row fail precisely when it is used normally.
var _voice_refresh_requested := false

## How a pre-render batch is going. Which voice each job is in lives on the job
## itself, not here: a batch covers the whole library, so the voice being
## rendered is usually not the one selected — and reading the setting at dispatch
## time would file one voice's audio under another's name, permanently, since the
## cache key is a hash of the text and so never expires.
var _prerendered := 0
var _fills_left := 0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	_http.request_completed.connect(_on_audio_received)
	add_child(_http)

	_meta_http = HTTPRequest.new()
	_meta_http.timeout = 10.0
	_meta_http.request_completed.connect(_on_meta_received)
	add_child(_meta_http)

	_player = AudioStreamPlayer.new()
	_player.bus = &"Master"
	_player.finished.connect(_play_next)
	add_child(_player)

	refresh()


## Empty falls back to the default rather than through. A blank value in config
## is not "no service" — it produces `""` + `/health`, which HTTPRequest rejects
## as an unparseable URL, and the backend then reports itself unavailable for a
## reason that names no address at all. Found by a test that restored a setting
## it had read back as empty.
func base_url() -> String:
	var url := str(Config.get_value("tts", "voxcpm_url", DEFAULT_URL)).strip_edges()
	return (url if not url.is_empty() else DEFAULT_URL).rstrip("/")


func _headers(json: bool) -> PackedStringArray:
	var out := PackedStringArray()
	if json:
		out.append("Content-Type: application/json")
	var key := str(Config.get_secret(KEY_NAME)).strip_edges()
	if not key.is_empty():
		out.append("Authorization: Bearer " + key)
	return out


## Optimistic until told otherwise, and this is deliberate. The contract says
## this is called every time the menu is built and must be cheap, which rules
## out asking the network here — so the answer is whatever the last health check
## found, and the first one has not landed yet when the first menu opens. Wrong
## in the direction of letting the user select a backend that turns out to be
## down, which then says so; the other direction hides a working service behind
## a disabled row.
func is_available() -> bool:
	return _healthy


func unavailable_reason() -> String:
	return _reason


## Asks the service how it is, without blocking. `TTSService.rediscover()` calls
## this on every menu open, so a service started or stopped while the pet was
## running is noticed without a restart.
func refresh() -> void:
	if _meta_http != null and _meta_http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_meta_http.request(base_url() + HEALTH_PATH, _headers(false), HTTPClient.METHOD_GET)


## Force a fresh copy of the service's voice library, even when one was already
## discovered this session. If another metadata request is in flight, its reply
## continues the refresh instead of cancelling a useful health check.
func refresh_voice_library() -> void:
	_voice_refresh_requested = true
	if _meta_http != null and _meta_http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_request_voice_library()


func _request_voice_library() -> void:
	var error := _meta_http.request(base_url() + VOICES_PATH, _headers(false),
		HTTPClient.METHOD_GET)
	if error != OK:
		_voice_refresh_requested = false
		_settle(false, "拿不到 VoxCPM 的聲音清單（錯誤 %d）。" % error)


func voice_name() -> String:
	var id := active_voice()
	for entry: Variant in _voices:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("voice_id", "")) == id:
			return str(entry.get("name", id))
	return id


func list_voices() -> PackedStringArray:
	var names := PackedStringArray()
	for entry: Variant in _voices:
		if typeof(entry) == TYPE_DICTIONARY:
			names.append(str(entry.get("voice_id", "")))
	return names


func active_voice() -> String:
	var chosen := str(Config.get_value("tts", "voxcpm_voice", ""))
	var known := list_voices()
	if not chosen.is_empty() and (known.is_empty() or known.has(chosen)):
		return chosen
	# A voice removed from the library must not leave the pet mute with a tick on
	# a row that is gone.
	return known[0] if not known.is_empty() else ""


func select_voice(name: String) -> void:
	Config.set_value("tts", "voxcpm_voice", name)


func speak(text: String) -> void:
	var line := text.strip_edges()
	if line.is_empty():
		return
	var voice := active_voice()
	# Ahead of the request, which is the whole point of the cache: a fixed line
	# costs a file read rather than a round trip to the service.
	var cached := _cached_stream(line, _cache_dir(voice))
	if cached != null:
		_queue.append(cached)
		_play_next()
		return
	_pending.append({"text": line, "cache": "", "voice": voice})
	_send_next()


## Render `lines` into the cache without playing any of them, in `voice` — or in
## whichever one is selected, when that is empty.
##
## Returns how many were actually asked for. One already cached costs nothing,
## which is what makes running this again after adding a single voice pay for
## that voice alone.
func prerender(lines: PackedStringArray, voice := "") -> int:
	var id := voice if not voice.is_empty() else active_voice()
	var directory := _cache_dir(id)
	var wanted := 0
	for line in lines:
		var text := line.strip_edges()
		if text.is_empty() or not _cached_path(text, directory).is_empty():
			continue
		_pending.append({"text": text, "cache": directory, "voice": id})
		wanted += 1
	if wanted == 0:
		return 0
	DirAccess.make_dir_recursive_absolute(directory)
	_fills_left += wanted
	_send_next()
	return wanted


func stop() -> void:
	_epoch += 1
	_pending.clear()
	_queue.clear()
	_current = {}
	_retries = 0
	_abandon_fills()
	if _http != null:
		_http.cancel_request()
	if _player != null:
		_player.stop()


func shutdown() -> void:
	stop()


# --- Requests ----------------------------------------------------------------

func _send_next() -> void:
	if not _current.is_empty() or _pending.is_empty():
		return
	_current = _pending.pop_front()
	_retries = 0
	_request_epoch = _epoch
	_dispatch()


func _dispatch() -> void:
	# The job's own voice, never the setting: a pre-render batch walks the whole
	# library, and by the time this job is sent the selected voice is somebody
	# else's.
	var voice := str(_current.get("voice", ""))
	var body := JSON.stringify({
		"voice_id": voice if not voice.is_empty() else active_voice(),
		"text": str(_current.get("text", "")),
		"format": "wav",
	})
	var error := _http.request(base_url() + TTS_PATH, _headers(true),
		HTTPClient.METHOD_POST, body)
	if error != OK:
		_give_up("連不上本機語音服務（錯誤 %d），先用系統語音。" % error)


func _on_audio_received(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	var job := _current
	var fill := str(job.get("cache", ""))
	if _request_epoch != _epoch:
		# Cancelled while in the air. Discarded without a word — the user is the
		# one who interrupted it.
		_current = {}
		if not fill.is_empty():
			_report_prerender(false)
		_send_next()
		return

	# The service asks for a backoff rather than a failure when its queue is
	# full: it serialises for correctness, so a busy moment is expected rather
	# than broken.
	if code == 503 and _retries < MAX_RETRIES:
		_retries += 1
		await get_tree().create_timer(RETRY_SECONDS * _retries).timeout
		if _request_epoch == _epoch and not _current.is_empty():
			_dispatch()
		return

	_current = {}
	# **Where the failure belongs decides whether the batch survives it.** A
	# pre-render is ninety requests, and the tolerant path below — one line failing
	# is not the backend failing — is written for a line the service chokes on. A
	# connection that has gone away, or a key it will not accept, is a property of
	# the *service*: every remaining clip will fail the same way, so carrying on
	# means eighty-seven doomed requests and eighty-seven identical warnings. Both
	# end the batch instead.
	if result != HTTPRequest.RESULT_SUCCESS:
		_give_up("跟本機語音服務斷了（%d），先用系統語音。" % result)
		return
	if code == 401:
		_give_up(_explain(code, body))
		return
	if code != 200:
		_fail_job(fill, _explain(code, body))
		return
	var stream := AudioStreamWAV.load_from_buffer(body)
	if stream == null or stream.get_length() <= 0.0:
		_fail_job(fill, "本機語音服務傳回來的聲音解不開，先用系統語音。")
		return

	if not fill.is_empty():
		_write_cache(str(job.get("text", "")), fill, body)
		_report_prerender(true)
	else:
		_queue.append(stream)
		_play_next()
	_send_next()


## One line failing is not the same as the backend failing, and a pre-render
## batch must reach zero either way or the menu row says it is still working for
## the rest of the session.
func _fail_job(fill: String, reason: String) -> void:
	if not fill.is_empty():
		# Not `broke`: one line failing is not the backend failing, and the batch
		# reports its own total. But it must not be silent either — a run that
		# says "0 錄成" with no reason anywhere is unfixable.
		push_warning("VoxCPMVoice: pre-render line failed — %s" % reason)
		_report_prerender(false)
		_send_next()
		return
	_give_up(reason)


func _give_up(reason: String) -> void:
	_pending.clear()
	_current = {}
	_abandon_fills()
	_healthy = false
	_reason = reason
	broke.emit(reason)


func _explain(code: int, body: PackedByteArray) -> String:
	var detail := ""
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		detail = str((parsed as Dictionary).get("detail", ""))
	match code:
		401:
			return "本機語音服務要 API key，先用系統語音。"
		404:
			return "本機語音服務找不到這個音色，%s" % (detail if not detail.is_empty()
				else "請到選單重選一個。")
		503:
			return "本機語音服務忙不過來，先用系統語音。"
		504:
			return "本機語音服務生成逾時，先用系統語音。"
		_:
			return "本機語音服務回了 HTTP %d，先用系統語音。" % code


func _on_meta_received(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_voice_refresh_requested = false
		_settle(false, "連不上語音服務（%s）。檢查網址對不對，或在那台機器上啟動 "
			% base_url() + "voxcpm-voice-api。")
		return
	if code != 200:
		_voice_refresh_requested = false
		# It answered, so telling the user to go and start it would send them to
		# restart something that is running perfectly well. 401 is the one that
		# actually happens: the service turns auth on the moment VOXCPM_API_KEY
		# is set, and /health stays open, so this is the first request to notice.
		_settle(false, ("語音服務要 API key。用下面那列「%s」貼上，或把 %s 放進環境變數。"
			% [KEY_ROW_LABEL, KEY_NAME]) if code == 401
			else "語音服務回了 HTTP %d（%s）。" % [code, base_url()])
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_voice_refresh_requested = false
		_settle(false, "語音服務的聲音清單看不懂（%s）。" % base_url())
		return
	var data := parsed as Dictionary
	if data.has("voices") and typeof(data["voices"]) == TYPE_ARRAY:
		# Whether this was startup discovery or an explicit refresh, the voice list
		# is the final answer for the whole metadata exchange.
		_voices = data["voices"]
		_voice_refresh_requested = false
		_settle(true, "")
		return
	# A health reply. `loading` is not a failure — the model takes about a minute
	# from cold — but it is not something to speak through either.
	var status := str(data.get("status", ""))
	var ok := status == "ok"
	if ok and (_voices.is_empty() or _voice_refresh_requested):
		# Not settled: /health is exempt from the API key, so a service with auth
		# on answers it happily and then refuses everything that matters. Whether
		# this backend actually works is decided by the voices request below.
		_healthy = true
		_reason = ""
		_request_voice_library()
		return
	_voice_refresh_requested = false
	_settle(ok, "" if ok
		else "語音服務還在載入模型（%s），等一下再試。" % base_url() if status == "loading"
		else "語音服務還沒準備好（%s）。" % base_url())


## Record what a discovery attempt found, and say so once.
##
## One place rather than five assignments, because `checked` has to fire on every
## outcome — a listener waiting to hear whether a newly-typed address works would
## otherwise hang on exactly the paths that fail.
func _settle(healthy: bool, reason: String) -> void:
	_healthy = healthy
	_reason = reason
	checked.emit(healthy, reason)


# --- The cache ----------------------------------------------------------------

## Per voice, because the audio *is* the voice. Which is also why the batch
## covers the whole library rather than the selected voice: switching voice would
## otherwise silently discard the lot.
##
## What this saves is the round trip, not the model's time — the service keeps
## its own output cache and answers a repeat in about 3 ms. Note what it does
## **not** buy: surviving an outage. A cached line would play with the service
## down, but `TTSService` swaps to the OS voice the moment this backend reports
## `broke`, so nothing asks it again that session.
func _cache_dir(voice: String) -> String:
	return ProjectSettings.globalize_path(CACHE_DIR).path_join(
		voice if not voice.is_empty() else ".default")


func _cached_path(text: String, directory: String) -> String:
	var path := directory.path_join(text.sha256_text() + ".wav")
	return path if FileAccess.file_exists(path) else ""


func _cached_stream(text: String, directory: String) -> AudioStream:
	var path := _cached_path(text, directory)
	if path.is_empty():
		return null
	var stream := AudioStreamWAV.load_from_buffer(FileAccess.get_file_as_bytes(path))
	if stream == null or stream.get_length() <= 0.0:
		# Refused rather than repaired: the caller's next move is to synthesise
		# the line for real, so a bad cache file costs one ordinary sentence.
		push_warning("VoxCPMVoice: ignoring unreadable cached line %s" % path.get_file())
		return null
	return stream


func _write_cache(text: String, directory: String, wav: PackedByteArray) -> void:
	if text.is_empty() or directory.is_empty() or wav.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(directory.path_join(text.sha256_text() + ".wav"),
		FileAccess.WRITE)
	if file == null:
		push_warning("VoxCPMVoice: cannot write cached line")
		return
	file.store_buffer(wav)
	file.close()


## Drop cached audio for lines the pet no longer says. The key is a hash of the
## text, so editing a nudge does not invalidate anything — the old clip simply
## stops being asked for, and would sit there for the life of the install. Not
## expensive, but it makes the folder a record of every wording that ever existed
## rather than of what the pet says now.
##
## **Separate from `prerender()`, which is what it was written inside.** There it
## pruned to whatever set that call happened to carry, so any caller passing a
## subset silently deleted the rest — measured within minutes of writing it, by a
## test that pre-rendered twenty throwaway lines and took a voice's whole cache
## with it. Rendering and forgetting are two operations and only one of them can
## lose data; a caller that wants both now has to say so.
##
## `lines` empty does nothing. A `prompts/nudges.json` that failed to load looks
## exactly like "there are no fixed lines", and the one thing that must not do is
## empty the cache.
func forget_unlisted(lines: PackedStringArray, voice := "") -> void:
	if lines.is_empty():
		return
	var directory := _cache_dir(voice if not voice.is_empty() else active_voice())
	if not DirAccess.dir_exists_absolute(directory):
		return
	var keep := {}
	for line in lines:
		var text := line.strip_edges()
		if not text.is_empty():
			keep[text.sha256_text() + ".wav"] = true
	for name in DirAccess.get_files_at(directory):
		if name.ends_with(".wav") and not keep.has(name):
			DirAccess.remove_absolute(directory.path_join(name))


func _report_prerender(ok: bool) -> void:
	if ok:
		_prerendered += 1
	_fills_left = maxi(_fills_left - 1, 0)
	line_prerendered.emit(_prerendered, _fills_left)
	if _fills_left == 0:
		_prerendered = 0


func _abandon_fills() -> void:
	if _fills_left <= 0:
		return
	_fills_left = 0
	line_prerendered.emit(_prerendered, 0)
	_prerendered = 0


func _play_next() -> void:
	if _player == null or _player.playing or _queue.is_empty():
		return
	_player.stream = _queue.pop_front()
	_player.play()
