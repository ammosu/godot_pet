extends TTSBackend
class_name ElevenVoice

## ElevenLabs, as a third voice beside the operating system's and the local model.
##
## The trade against VoxCPM is the opposite one in every respect: nothing to
## install, no 2.6 GB of VRAM and no model load, in exchange for every sentence
## the pet says leaving this machine and costing money. It is not the default and
## never becomes one — `TTSService` picks a backend at startup and never writes
## one back, so this is only ever in use because somebody chose it.
##
## **It will not fix 破音字.** Measured on the local engine and true of this one
## for the same structural reason: both are end-to-end, with no G2P stage to hang
## a pronunciation dictionary on. ElevenLabs' phoneme tags are documented for
## their English models only, so `prompts/pronunciation.json` remains the only
## lever and keeps working here unchanged — `TTSService._respell()` is applied on
## the way into every backend, this one included.

const ENDPOINT := "https://api.elevenlabs.io/v1/text-to-speech/%s"
const VOICES_ENDPOINT := "https://api.elevenlabs.io/v1/voices"
const KEY_NAME := "ELEVENLABS_API_KEY"

## Flash 2.5 rather than the multilingual default: same 32 languages including
## Chinese, an order of magnitude less latency, and half the credits per
## character. A desk pet interrupts and re-plans constantly, so latency is worth
## more here than the last few percent of expressiveness.
const DEFAULT_MODEL := "eleven_flash_v2_5"

## **MP3, because PCM is a Pro-tier feature** — `pcm_*` and `wav_*` are refused
## below $99/month, and a backend that only worked on the most expensive plan
## would be a backend nobody could try. `mp3_44100_128` is the API's own default
## and available on every tier including free. Someone on Pro can set
## `[tts] eleven_format = "pcm_24000"` and skip the decode.
const DEFAULT_FORMAT := "mp3_44100_128"

## Long enough for a slow link, short enough that a dead network does not leave
## the pet apparently mid-sentence forever.
const REQUEST_TIMEOUT := 30.0

var _http: HTTPRequest
var _voices_http: HTTPRequest
var _player: AudioStreamPlayer

## Sentences waiting to be synthesised, in the order they were said. One request
## at a time: a reply arrives sentence by sentence, and two in flight together
## would race to finish and could play the second half of a thought first.
var _pending: PackedStringArray = []
var _queue: Array[AudioStream] = []
var _speaking := ""

## Bumped by `stop()`. A response that arrives after it is thrown away, the same
## watermark `VoxCPMVoice` keeps — an HTTP request already sent cannot be unsent,
## so the audio still turns up and has to be recognised as unwanted.
var _epoch := 0
var _request_epoch := 0

var _voice_id := ""
var _voices: Array = []
var _voices_asked := false
var _reason := ""


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	_http.request_completed.connect(_on_audio_received)
	add_child(_http)

	_voices_http = HTTPRequest.new()
	_voices_http.timeout = REQUEST_TIMEOUT
	_voices_http.request_completed.connect(_on_voices_received)
	add_child(_voices_http)

	# Unlike the LLM provider this uses HTTPRequest rather than a polled
	# HTTPClient, and the difference is what each one needs from the response.
	# Streaming a reply means acting on deltas as they arrive; a sentence of
	# audio is useless until it is complete, so "hand me the whole body" is
	# exactly right here and costs no `_process` loop.
	_player = AudioStreamPlayer.new()
	_player.bus = &"Master"
	_player.finished.connect(_play_next)
	add_child(_player)

	refresh()


## Cheap and touches nothing: the contract says this runs every time the menu is
## built. Whether the key is *correct* cannot be known without spending a
## request, so that failure arrives later as `broke`.
func is_available() -> bool:
	return not _api_key().is_empty()


func unavailable_reason() -> String:
	return _reason


func refresh() -> void:
	_voice_id = str(Config.get_value("tts", "eleven_voice_id", ""))
	# Reconsidering everything includes the voice list, which is asked for at
	# most once per session so a failing account is not hammered once a sentence.
	# Re-selecting this backend, or pasting a key, is what earns another attempt.
	_voices_asked = false
	# Names the row that actually sets *this* key. The obvious wording — "the
	# 設定 API 金鑰 row" — would have been false: that one writes OPENAI_API_KEY,
	# and following it would leave this backend exactly as disabled while looking
	# like it had been done.
	_reason = ("" if is_available() else
		"還沒有 ElevenLabs 的金鑰。用下面那列「設定 ElevenLabs 金鑰…」貼上，"
		+ "或把 %s 放進環境變數。" % KEY_NAME)


## The configured voice, or the name discovered from the account. Empty until the
## first request tells us — the row then fills itself in.
func voice_name() -> String:
	for entry: Variant in _voices:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("voice_id", "")) == _voice_id:
			return str(entry.get("name", _voice_id))
	return _voice_id


## Every voice on the account, by id. Fetched once per session; the menu can
## offer these without this class knowing anything about menus. Ids rather than
## names because the id is what the API takes and what config stores — the name
## is for the row that says which one is speaking, and `voice_name()` has it.
func list_voices() -> PackedStringArray:
	var out := PackedStringArray()
	for entry: Variant in _voices:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(str(entry.get("voice_id", "")))
	return out


func active_voice() -> String:
	return _voice_id


func select_voice(name: String) -> void:
	_voice_id = name
	Config.set_value("tts", "eleven_voice_id", name)


func speak(text: String) -> void:
	var line := text.strip_edges()
	if line.is_empty():
		return
	if not is_available():
		broke.emit(_reason)
		return
	_pending.append(line)
	_send_next()


func stop() -> void:
	_epoch += 1
	_pending.clear()
	_queue.clear()
	_speaking = ""
	if _http != null:
		_http.cancel_request()
	if _player != null:
		_player.stop()


func shutdown() -> void:
	stop()


# --- Requests ----------------------------------------------------------------

func _api_key() -> String:
	return str(Config.get_secret(KEY_NAME)).strip_edges()


## One in flight at a time. `_speaking` doubles as the busy flag and as what to
## blame if the request fails, so a failure names the sentence it lost.
func _send_next() -> void:
	if not _speaking.is_empty() or _pending.is_empty():
		return
	# A voice has to be chosen before anything can be said, and the account is
	# the only place the ids exist. Asked for once, and the sentence waits rather
	# than being dropped — the pet says it a moment late instead of never.
	if _voice_id.is_empty():
		_fetch_voices()
		return
	_speaking = _pending[0]
	_pending.remove_at(0)
	_request_epoch = _epoch
	var body := JSON.stringify({
		"text": _speaking,
		"model_id": str(Config.get_value("tts", "eleven_model", DEFAULT_MODEL)),
	})
	var url := (ENDPOINT % _voice_id.uri_encode()) + "?output_format=" + _format().uri_encode()
	var error := _http.request(url, _headers(), HTTPClient.METHOD_POST, body)
	if error != OK:
		_give_up("連不上 ElevenLabs（錯誤 %d），先用系統語音。" % error)


func _headers() -> PackedStringArray:
	return PackedStringArray([
		"xi-api-key: " + _api_key(),
		"Content-Type: application/json",
		"Accept: */*",
	])


func _format() -> String:
	return str(Config.get_value("tts", "eleven_format", DEFAULT_FORMAT))


func _fetch_voices() -> void:
	if _voices_asked:
		return
	_voices_asked = true
	var error := _voices_http.request(VOICES_ENDPOINT, _headers(), HTTPClient.METHOD_GET)
	if error != OK:
		_give_up("拿不到 ElevenLabs 的聲音清單（錯誤 %d）。" % error)


func _on_voices_received(_result: int, code: int, _headers_out: PackedStringArray,
		body: PackedByteArray) -> void:
	if code != 200:
		_give_up(_explain(code))
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_give_up("ElevenLabs 的聲音清單看不懂，先用系統語音。")
		return
	_voices = (parsed as Dictionary).get("voices", [])
	if _voice_id.is_empty() and not _voices.is_empty():
		# Not persisted. Which voice to use is a choice, and one made here by
		# taking whatever came first is not the user's — pinning it in config
		# would make an arbitrary pick look like a decision.
		_voice_id = str((_voices[0] as Dictionary).get("voice_id", ""))
	if _voice_id.is_empty():
		_give_up("這個 ElevenLabs 帳號上沒有任何聲音可以用。")
		return
	_send_next()


func _on_audio_received(result: int, code: int, _headers_out: PackedStringArray,
		body: PackedByteArray) -> void:
	var lost := _speaking
	_speaking = ""
	if _request_epoch != _epoch:
		# Interrupted while this was in the air. Thrown away rather than played,
		# and *not* reported: the user is the one who cancelled it.
		_send_next()
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_give_up("跟 ElevenLabs 說話的時候斷了（%d），先用系統語音。" % result)
		return
	if code != 200:
		_give_up(_explain(code))
		return
	var stream := _decode(body, _format())
	if stream == null:
		_give_up("ElevenLabs 傳回來的聲音解不開（%s），先用系統語音。" % _format())
		return
	if not lost.is_empty():
		_queue.append(stream)
		_play_next()
	_send_next()


## Give up on everything outstanding and say why.
##
## Every failure here ends the backend's turn — `TTSService` falls back to the
## OS voice on `broke` — so leaving sentences queued would mean replaying them,
## minutes stale, if the user ever selected this again. The queue is dropped
## rather than kept for the same reason a cancelled sentence is.
func _give_up(reason: String) -> void:
	_pending.clear()
	_speaking = ""
	broke.emit(reason)


## The failures worth telling apart, because only some of them are worth acting
## on. A wrong key and an exhausted quota both stop the voice dead, and a user
## who is told only "it broke" has no way to know which of the two it was.
func _explain(code: int) -> String:
	match code:
		401, 403:
			return "ElevenLabs 說金鑰不對或沒有權限，先用系統語音。"
		422:
			return "ElevenLabs 退回了這段文字，先用系統語音。"
		429:
			return "ElevenLabs 的額度用完了（或請求太密集），先用系統語音。"
		_:
			return "ElevenLabs 回了 HTTP %d，先用系統語音。" % code


## MP3 unless somebody on Pro asked for raw PCM, which needs the sample rate the
## format name carries — `pcm_24000` is 24 kHz, 16-bit, mono.
func _decode(body: PackedByteArray, format: String) -> AudioStream:
	if body.is_empty():
		return null
	if format.begins_with("pcm_"):
		var rate := int(format.substr(4))
		if rate <= 0:
			return null
		return TTSBackend.pcm_stream(body, rate)
	if format.begins_with("wav_"):
		# The engine parses the header itself, so nothing here has to know the
		# rate the format name claims — and a truncated body comes back as a
		# zero-length stream rather than as noise.
		var wav := AudioStreamWAV.load_from_buffer(body)
		return null if wav == null or wav.get_length() <= 0.0 else wav
	var mp3 := AudioStreamMP3.new()
	mp3.data = body
	return null if mp3.get_length() <= 0.0 else mp3


func _play_next() -> void:
	if _player == null or _player.playing or _queue.is_empty():
		return
	_player.stream = _queue.pop_front()
	_player.play()
