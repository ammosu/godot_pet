extends LLMProvider

## OpenAI Chat Completions with real SSE streaming.
##
## Uses HTTPClient rather than HTTPRequest: HTTPRequest only hands back the whole
## body at once, which would mean waiting for the entire reply before the pet
## says a word. HTTPClient is polled from _process — it never blocks, so there's
## no thread and no cross-thread signal marshalling to get wrong.

const HOST := "api.openai.com"
const PORT := 443
const ENDPOINT := "/v1/chat/completions"
## Not nano, despite nano being cheaper and perfectly good at chatting. The pet
## asks to see the screen by emitting `[look]` in the mood-tag slot, and nano
## simply doesn't: measured 0/12 on questions that plainly need a screenshot
## ("我現在在幹嘛？", "這個錯誤是什麼意思？"), where mini scores 9/9 and still
## correctly declines on questions that don't. Nano *can* read a screenshot once
## one is attached — it just never asks for one, so the feature is dead on it.
## Override with `openai_model` under `[llm]` in config.cfg.
const DEFAULT_MODEL := "gpt-5.4-mini"
const KEY_NAME := "OPENAI_API_KEY"

## Abandon the request if nothing arrives for this long.
const STALL_TIMEOUT := 45.0

enum Stage { IDLE, CONNECTING, REQUESTING, READING }

var _client: HTTPClient = null
var _stage := Stage.IDLE
var _body := PackedByteArray()
var _buffer := PackedByteArray()
var _reply := ""
var _http_code := 0
var _saw_done := false
var _quiet_for := 0.0
## Held only for the duration of one request, so the key isn't kept in memory.
var _authorization := ""


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	_shutdown()


func is_busy() -> bool:
	return _stage != Stage.IDLE


func send(messages: Array, system: String) -> void:
	if is_busy():
		return

	var key := Config.get_secret(KEY_NAME)
	if key.is_empty():
		failed.emit("找不到 %s，請設環境變數或寫進 .env" % KEY_NAME)
		return

	_reply = ""
	_buffer = PackedByteArray()
	_http_code = 0
	_saw_done = false
	_quiet_for = 0.0
	_body = _build_payload(messages, system).to_utf8_buffer()

	_client = HTTPClient.new()
	var err := _client.connect_to_host(HOST, PORT, TLSOptions.client())
	if err != OK:
		_client = null
		failed.emit("無法連線到 %s（%d）" % [HOST, err])
		return

	_authorization = "Authorization: Bearer %s" % key
	_stage = Stage.CONNECTING
	set_process(true)


func cancel() -> void:
	if _stage == Stage.IDLE:
		return
	_shutdown()


func _process(delta: float) -> void:
	_quiet_for += delta
	if _quiet_for > STALL_TIMEOUT:
		_fail("等太久了，先放棄這次回話")
		return

	_client.poll()
	match _stage:
		Stage.CONNECTING:
			_poll_connect()
		Stage.REQUESTING:
			_poll_request()
		Stage.READING:
			_poll_body()


func _poll_connect() -> void:
	match _client.get_status():
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
			return
		HTTPClient.STATUS_CONNECTED:
			var headers := [
				_authorization,
				"Content-Type: application/json",
				"Accept: text/event-stream",
			]
			var err := _client.request_raw(HTTPClient.METHOD_POST, ENDPOINT, headers, _body)
			_authorization = ""
			_body = PackedByteArray()
			if err != OK:
				_fail("送出請求失敗（%d）" % err)
				return
			_quiet_for = 0.0
			_stage = Stage.REQUESTING
		_:
			_fail("連不上 %s" % HOST)


func _poll_request() -> void:
	if _client.get_status() == HTTPClient.STATUS_REQUESTING:
		return
	if not _client.has_response():
		_fail("伺服器沒有回應")
		return
	_http_code = _client.get_response_code()
	_quiet_for = 0.0
	_stage = Stage.READING


func _poll_body() -> void:
	while true:
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			break
		_quiet_for = 0.0
		_buffer.append_array(_strip_cr(chunk))
		if _http_code == 200:
			_drain_events()
			# A chunk handler is free to cancel us — the pet does exactly that
			# when the model asks to see the screen — and _client is gone by the
			# time the emit returns.
			if _stage != Stage.READING:
				return

	if _client.get_status() == HTTPClient.STATUS_BODY:
		return

	# Connection finished. Anything non-200 left its error JSON in the buffer.
	if _http_code != 200:
		_fail(_describe_http_error())
		return
	# The stream ended without [DONE] and without a word: the connection dropped
	# rather than completed, so report it instead of showing an empty bubble.
	if not _saw_done and _reply.is_empty():
		_fail("回應中斷了")
		return
	var reply := _reply
	_shutdown()
	finished.emit(reply)


# --- SSE ----------------------------------------------------------------------

## Events are separated by a blank line. Splitting on raw bytes keeps multi-byte
## UTF-8 characters intact when a chunk lands mid-character.
func _drain_events() -> void:
	while true:
		var end := _find_event_end()
		if end < 0:
			return
		var raw := _buffer.slice(0, end).get_string_from_utf8()
		_buffer = _buffer.slice(end + 2)
		_handle_event(raw)


func _find_event_end() -> int:
	var from := 0
	while from < _buffer.size():
		var i := _buffer.find(0x0A, from)
		if i < 0 or i + 1 >= _buffer.size():
			return -1
		if _buffer[i + 1] == 0x0A:
			return i
		from = i + 1
	return -1


func _handle_event(raw: String) -> void:
	for line in raw.split("\n", false):
		if not line.begins_with("data:"):
			continue
		var payload := line.substr(5).strip_edges()
		if payload == "[DONE]":
			_saw_done = true
			return
		var data: Variant = JSON.parse_string(payload)
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var choices: Array = data.get("choices", [])
		if choices.is_empty():
			continue
		var delta: Dictionary = choices[0].get("delta", {})
		var text := str(delta.get("content", ""))
		if not text.is_empty():
			_reply += text
			chunk_received.emit(text)


## JSON never contains a bare CR, so dropping them lets one blank-line search
## handle servers that use \r\n.
func _strip_cr(chunk: PackedByteArray) -> PackedByteArray:
	if chunk.find(0x0D) < 0:
		return chunk
	var out := PackedByteArray()
	for b in chunk:
		if b != 0x0D:
			out.append(b)
	return out


# --- Plumbing -----------------------------------------------------------------

func _build_payload(messages: Array, system: String) -> String:
	var wire: Array = [{"role": "system", "content": system}]
	for message in messages:
		wire.append({"role": message.get("role", "user"), "content": message.get("content", "")})
	return JSON.stringify({
		"model": str(Config.get_value("llm", "openai_model", DEFAULT_MODEL)),
		"stream": true,
		# A backstop against a runaway reply, not a style control — the persona
		# handles length. Verified against gpt-5.4-nano, which spends no reasoning
		# tokens here, so the cap won't quietly swallow the answer.
		"max_completion_tokens": int(Config.get_value("llm", "max_reply_tokens", 320)),
		"messages": wire,
	})


func _describe_http_error() -> String:
	var data: Variant = JSON.parse_string(_buffer.get_string_from_utf8())
	if typeof(data) == TYPE_DICTIONARY:
		var detail: Variant = data.get("error", {})
		if typeof(detail) == TYPE_DICTIONARY and detail.has("message"):
			return "%d %s" % [_http_code, detail["message"]]
	return "HTTP %d" % _http_code


func _fail(message: String) -> void:
	_shutdown()
	failed.emit(message)


func _shutdown() -> void:
	set_process(false)
	_stage = Stage.IDLE
	_authorization = ""
	_body = PackedByteArray()
	_buffer = PackedByteArray()
	if _client != null:
		_client.close()
		_client = null
