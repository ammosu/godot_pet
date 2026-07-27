extends Node

## Turns "the user said something" into "the pet replied": picks the backend,
## assembles the system prompt, and parses the mood tag out of the stream.
## Everyone else talks to it through EventBus.
##
## Conversation history belongs to MemoryStore, not here — keeping a second copy
## alongside the one being persisted is how the two drift apart.

const PERSONA_PATH := "res://prompts/persona.md"

const PROVIDERS := {
	"mock": "res://llm/providers/mock_provider.gd",
	"openai": "res://llm/providers/openai_provider.gd",
}

## Replies are asked to open with a tag like "[happy]" naming the pet's mood.
## It drives the animation and is stripped before the text reaches the bubble.
##
## An inline tag rather than tool use, because it costs no extra round-trip and
## survives streaming: the mood is known from the very first tokens, so the pet
## reacts before it has finished the sentence.
const EMOTIONS := ["neutral", "happy", "excited", "sad", "greeting", "sleepy"]

## Give up on finding a tag after this many characters — the model skipped it.
const TAG_SCAN_LIMIT := 24

var _provider: LLMProvider = null
var _provider_name := ""
var _persona := ""

## Leading-tag parser state. Text is held back until the tag resolves one way or
## the other, so a partially-arrived "[hap" never reaches the bubble.
var _tag_resolved := true
var _tag_buffer := ""
## What the bubble actually showed, which is what goes into the history — the
## model shouldn't have to re-read its own tags.
var _clean_reply := ""
## Set for replies that describe something transient, like the screen, so they
## stay out of the summary, the facts and the save file.
var _reply_is_ephemeral := false


func _ready() -> void:
	_persona = _load_persona()
	set_provider(str(Config.get_value("llm", "provider", _default_provider())))
	EventBus.user_said.connect(_on_user_said)


## Talk to a real model if there's a key to do it with, otherwise fall back to
## the mock so a fresh checkout still does something.
func _default_provider() -> String:
	return "openai" if Config.has_secret("OPENAI_API_KEY") else "mock"


func get_provider_name() -> String:
	return _provider_name


func list_providers() -> PackedStringArray:
	return PackedStringArray(PROVIDERS.keys())


func provider_label(name: String) -> String:
	if name == "openai":
		return "OpenAI · %s" % Config.get_value("llm", "openai_model", "gpt-5.4-nano")
	if name == "mock":
		return "Mock（不呼叫 API）"
	return name


## Switch and remember. Kept apart from `set_provider` so the startup default
## never writes itself to disk — doing that pins whatever the default happened to
## be on first run, and later auto-detection can never take effect.
func select_provider(name: String) -> void:
	set_provider(name)
	Config.set_value("llm", "provider", _provider_name)


func set_provider(name: String) -> void:
	if not PROVIDERS.has(name):
		push_warning("LLMService: unknown provider '%s', using mock" % name)
		name = "mock"
	if name == _provider_name:
		return

	if _provider != null:
		_provider.cancel()
		_provider.queue_free()

	var script: GDScript = load(PROVIDERS[name])
	_provider = script.new()
	_provider.name = "Provider"
	add_child(_provider)
	_provider.chunk_received.connect(_on_chunk)
	_provider.finished.connect(_on_finished)
	_provider.failed.connect(_on_failed)

	_provider_name = name


func is_busy() -> bool:
	return _provider != null and _provider.is_busy()


## Abandon the in-flight reply — the user interrupted.
func interrupt() -> void:
	if _provider != null:
		_provider.cancel()


## A one-off request whose output must never reach the bubble — summarising, and
## anything else the pet does behind its own back.
##
## Runs on a second provider instance rather than a flag on the main one: its
## signals simply aren't wired to EventBus, so there's no path by which a stray
## chunk could be spoken aloud or typed out. Returns false when the active
## backend can't do useful work, so callers can degrade instead of waiting.
func request_background(system: String, prompt: String, on_done: Callable) -> bool:
	if _provider_name == "mock" or not PROVIDERS.has(_provider_name):
		return false
	var script: GDScript = load(PROVIDERS[_provider_name])
	var worker: LLMProvider = script.new()
	worker.name = "BackgroundProvider"
	add_child(worker)
	worker.finished.connect(func(text: String) -> void:
		on_done.call(text)
		worker.queue_free())
	worker.failed.connect(func(message: String) -> void:
		push_warning("LLMService: background request failed — %s" % message)
		worker.queue_free())
	worker.send([{"role": "user", "content": prompt}], system)
	return true


func build_system_prompt() -> String:
	var sections := PackedStringArray([_persona])
	var memories := MemoryStore.context_block()
	if not memories.is_empty():
		sections.append(memories)
	sections.append("## 你現在的狀態\n%s\n\n讓這些狀態影響你的語氣，但**不要直接把它們念出來**，也不要說「我的心情是普通」這種話。"
		% PetState.describe())
	return "\n\n".join(sections)


## Record something the pet said without the model's involvement — an unprompted
## line — so its next reply doesn't contradict it.
func note_pet_said(text: String) -> void:
	MemoryStore.append("assistant", text)


## Ask about a screenshot. Same streaming path as any reply, so it types into
## the bubble and drives the animation the usual way — but the answer is marked
## ephemeral, because it describes whatever happened to be on screen and has no
## business becoming a permanent fact about the user.
func ask_about_image(question: String, data_url: String) -> void:
	if _provider == null:
		return
	if _provider.is_busy():
		_provider.cancel()

	MemoryStore.append("user", question)
	var messages := MemoryStore.recent_messages()
	# The image rides on the newest turn only; earlier turns stay plain text so
	# the pet isn't re-billed for every screenshot it has ever seen.
	messages[-1]["content"] = [
		{"type": "text", "text": question},
		{"type": "image_url", "image_url": {"url": data_url, "detail": VisionService.DETAIL}},
	]

	_tag_resolved = false
	_tag_buffer = ""
	_clean_reply = ""
	_reply_is_ephemeral = true
	_provider.send(messages, build_system_prompt())


func _on_user_said(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_empty() or _provider == null:
		return
	# A new message replaces whatever the pet was mid-way through saying.
	if _provider.is_busy():
		_provider.cancel()

	MemoryStore.append("user", trimmed)
	_tag_resolved = false
	_tag_buffer = ""
	_clean_reply = ""
	_reply_is_ephemeral = false
	_provider.send(MemoryStore.recent_messages(), build_system_prompt())


func _on_finished(full_text: String) -> void:
	# Nothing but a tag arrived, or the tag never closed: release what's left.
	if not _tag_resolved:
		_release_tag_buffer(_tag_buffer.lstrip(" \n\t"))
	var reply := _clean_reply if not _clean_reply.is_empty() else full_text
	MemoryStore.append("assistant", reply, _reply_is_ephemeral)
	# Don't pay to summarise on the back of a turn that can't be summarised.
	if not _reply_is_ephemeral:
		MemoryStore.maybe_condense()
	_reply_is_ephemeral = false
	EventBus.reply_finished.emit(reply)


# --- Emotion tag --------------------------------------------------------------

func _on_chunk(text: String) -> void:
	if _tag_resolved:
		_emit_text(text)
		return

	_tag_buffer += text
	var head := _tag_buffer.lstrip(" \n\t")
	if head.is_empty():
		# Only whitespace so far — the tag may still be on its way.
		if _tag_buffer.length() < TAG_SCAN_LIMIT:
			return
		_release_tag_buffer("")
		return

	if not head.begins_with("["):
		_release_tag_buffer(head)
		return

	var close := head.find("]")
	if close < 0:
		if _tag_buffer.length() > TAG_SCAN_LIMIT:
			_release_tag_buffer(head)
		return

	var emotion := head.substr(1, close - 1).strip_edges().to_lower()
	if EMOTIONS.has(emotion):
		EventBus.emotion_changed.emit(emotion)
	_release_tag_buffer(head.substr(close + 1).lstrip(" \n"))


func _release_tag_buffer(text: String) -> void:
	_tag_resolved = true
	_tag_buffer = ""
	if not text.is_empty():
		_emit_text(text)


func _emit_text(text: String) -> void:
	_clean_reply += text
	EventBus.reply_chunk.emit(text)


func _on_failed(message: String) -> void:
	# Drop the unanswered user turn so a retry doesn't stack duplicates.
	MemoryStore.drop_trailing_user_turn()
	push_warning("LLMService: %s" % message)
	EventBus.reply_failed.emit(message)


func _load_persona() -> String:
	var text := FileAccess.get_file_as_string(PERSONA_PATH)
	if text.is_empty():
		push_warning("LLMService: no persona at %s" % PERSONA_PATH)
		return "你是一隻住在使用者桌面上的小寵物，用繁體中文簡短回話。"
	return text
