extends LLMProvider

## Fake backend for building the UI against. Streams a canned reply a few
## characters at a time with a plausible delay, so bubble layout, the typewriter
## effect, interruption and the talking animation can all be exercised without
## spending tokens or needing a key.

const THINK_DELAY := Vector2(0.4, 0.9)
const CHARS_PER_SECOND := 26.0

const REPLIES: Array[String] = [
	"嗯……我在聽喔。今天過得還好嗎？",
	"欸，你終於想起我了！我剛剛在這邊發呆好久欸。",
	"這個我知道！大概啦。你要不要再說詳細一點？",
	"好喔，那我先記著。不過我記性沒有很好，你可能要多提醒我幾次。",
	"你打字的時候我都有在旁邊看，只是不好意思打擾你。",
	"我覺得你該休息一下了，桌面都被視窗塞滿了。",
]

var _busy := false
var _remaining := ""
var _emitted := ""
var _delay := 0.0
var _carry := 0.0


func _ready() -> void:
	set_process(false)


func send(messages: Array, _system: String) -> void:
	if _busy:
		return
	_busy = true
	_emitted = ""
	_carry = 0.0
	_delay = randf_range(THINK_DELAY.x, THINK_DELAY.y)
	_remaining = _pick_reply(messages)
	set_process(true)


func cancel() -> void:
	if not _busy:
		return
	_busy = false
	_remaining = ""
	set_process(false)


func is_busy() -> bool:
	return _busy


func _process(delta: float) -> void:
	if _delay > 0.0:
		_delay -= delta
		return

	_carry += CHARS_PER_SECOND * delta
	var take := int(_carry)
	if take <= 0:
		return
	_carry -= take

	var chunk := _remaining.substr(0, take)
	_remaining = _remaining.substr(chunk.length())
	_emitted += chunk
	chunk_received.emit(chunk)

	if _remaining.is_empty():
		_busy = false
		set_process(false)
		finished.emit(_emitted)


## Echo something related to the last thing said, so replies don't feel totally
## disconnected while testing.
func _pick_reply(messages: Array) -> String:
	var last := ""
	if not messages.is_empty():
		last = str(messages[-1].get("content", ""))
	if last.ends_with("?") or last.ends_with("？"):
		return "唔……這個問題有點難欸。你先告訴我你自己怎麼想的？"
	if last.length() > 40:
		return "哇，你講了好多。我大概聽懂了一半，重點是不是「%s」？" % last.substr(0, 12)
	return REPLIES[randi() % REPLIES.size()]
