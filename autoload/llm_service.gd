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

## In the same slot as the mood tag, the model can instead ask to see the screen.
## Asking in words — "看一下我在幹嘛" — is the obvious way to want this, and a
## menu item alone leaves the pet insisting it has no eyes. Letting the model
## decide beats keyword-matching the request, because it also covers "這個錯誤
## 是什麼意思" typed with the error still on screen.
const LOOK_TAG := "look"

## Heading of the persona section that teaches `[look]`, dropped for one turn
## after the user says no. Must match `prompts/persona.md`.
const LOOK_SECTION := "看螢幕"

## Replaces it for that turn.
const NO_LOOK_NOTE := "\n\n## 看螢幕\n你看不到螢幕畫面。使用者剛剛拒絕了截圖，所以這次只能用文字回答，需要的話請他把內容貼給你。不要輸出 `[look]`。"

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
## True while answering with an image attached, so a second [look] can't send it
## round again.
var _in_vision_pass := false
## Set when the user turned a screenshot down, so the model can't just ask again.
var _look_declined := false
## Kept so a [look] can re-ask the same thing with a screenshot attached.
var _last_question := ""


func _ready() -> void:
	_persona = _load_persona()
	set_provider(str(Config.get_value("llm", "provider", _default_provider())))
	EventBus.user_said.connect(_on_user_said)
	EventBus.file_content_said.connect(_on_file_content_said)


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
		var openai: GDScript = load(PROVIDERS["openai"])
		return "OpenAI · %s" % Config.get_value("llm", "openai_model", openai.DEFAULT_MODEL)
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


func build_system_prompt(allow_look := true) -> String:
	var sections := PackedStringArray([_persona if allow_look else _persona_without_looking()])
	var memories := MemoryStore.context_block()
	if not memories.is_empty():
		sections.append(memories)
	sections.append("## 你現在的狀態\n%s\n\n讓這些狀態影響你的語氣，但**不要直接把它們念出來**，也不要說「我的心情是普通」這種話。"
		% PetState.describe())
	return "\n\n".join(sections)


## The persona with its screen section cut out, for the turn after the user says
## no. Merely appending "you can't look this time" doesn't work: the persona
## tells the model to answer a screen question with nothing but `[look]`, and a
## small model follows the character sheet over the footnote — it asked again,
## the tag was swallowed, and the pet ended up saying nothing at all.
func _persona_without_looking() -> String:
	var kept := PackedStringArray()
	for section in _persona.split("\n## "):
		if not section.begins_with(LOOK_SECTION):
			kept.append(section)
	return "\n## ".join(kept) + NO_LOOK_NOTE


## Record something the pet said without the model's involvement — an unprompted
## line — so its next reply doesn't contradict it.
func note_pet_said(text: String) -> void:
	MemoryStore.append("assistant", text)


## Ask about an image. Same streaming path as any reply, so it types into the
## bubble and drives the animation the usual way. Screen-look answers default
## to ephemeral, because they describe whatever happened to be on screen and
## have no business becoming a permanent fact about the user; a dropped image
## is something the user deliberately handed over, so FileDropService passes
## `ephemeral = false` and lets it join ordinary history like any other turn.
func ask_about_image(question: String, data_url: String, record_question := true,
		ephemeral := true) -> void:
	if _provider == null:
		return
	if _provider.is_busy():
		_provider.cancel()

	# Skipped when the model asked to look mid-reply: the question is already the
	# newest turn, and appending it again would leave the pet talking to itself.
	if record_question:
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
	_reply_is_ephemeral = ephemeral
	_in_vision_pass = true
	_provider.send(messages, build_system_prompt())


func _on_user_said(text: String) -> void:
	_start_user_turn(text, true)


## A user turn that isn't literally typed — a dropped file's content, composed
## by FileDropService. Skips the local screen-look phrase match: that match is
## a blind substring test meant for a short typed question, and a dropped
## file's own content — or just its name, e.g. "我的螢幕錄影.mp4" — can trip it
## on text that has nothing to do with the current screen.
func _on_file_content_said(text: String) -> void:
	_start_user_turn(text, false)


func _start_user_turn(text: String, check_look: bool) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_empty() or _provider == null:
		return
	# A new message replaces whatever the pet was mid-way through saying.
	if _provider.is_busy():
		_provider.cancel()

	MemoryStore.append("user", trimmed)
	_last_question = trimmed
	_tag_resolved = false
	_tag_buffer = ""
	_clean_reply = ""
	_reply_is_ephemeral = false
	_in_vision_pass = false
	_look_declined = false

	# Ask for the screen *before* answering, when the question plainly needs it.
	# Waiting for the model to request it costs a wasted round-trip at best, and
	# on a small model it never happens at all.
	if check_look and VisionService.wants_a_look(trimmed):
		EventBus.screen_look_requested.emit(trimmed, false)
		return

	_provider.send(MemoryStore.recent_messages(), build_system_prompt())


## The user said no to a screenshot, so answer the question as best we can
## without one. `_look_declined` makes the reply stick: the model would
## otherwise answer a screen question with `[look]` and ask all over again.
func answer_without_looking() -> void:
	if _provider == null:
		return
	if _provider.is_busy():
		_provider.cancel()
	_tag_resolved = false
	_tag_buffer = ""
	_clean_reply = ""
	_reply_is_ephemeral = false
	_in_vision_pass = false
	_look_declined = true
	# Suppressing `[look]` on the way in isn't enough: the model asked for a
	# reason, and asked again the moment it was re-sent the same question with
	# the same prompt. It has to be told the answer was no.
	_provider.send(MemoryStore.recent_messages(), build_system_prompt(false))


func _on_finished(full_text: String) -> void:
	# Nothing but a tag arrived, or the tag never closed: release what's left.
	if not _tag_resolved:
		_release_tag_buffer(_tag_buffer.lstrip(" \n\t"))
	# Trust the parser once it has resolved: falling back to the raw text there
	# puts a bare `[look]` in the bubble and in history when the reply was
	# nothing but a tag the parser deliberately swallowed.
	var reply := _clean_reply if _tag_resolved else full_text
	if reply.strip_edges().is_empty():
		reply = "……我好像沒話說了，再問我一次？"
		EventBus.reply_chunk.emit(reply)
	MemoryStore.append("assistant", reply, _reply_is_ephemeral)
	# Don't pay to summarise on the back of a turn that can't be summarised.
	if not _reply_is_ephemeral:
		MemoryStore.maybe_condense()
	_reply_is_ephemeral = false
	_in_vision_pass = false
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

	var tag := head.substr(1, close - 1).strip_edges().to_lower()
	if tag == LOOK_TAG and not _in_vision_pass and not _look_declined:
		_take_a_look()
		return
	if EMOTIONS.has(tag):
		EventBus.emotion_changed.emit(tag)
	_release_tag_buffer(head.substr(close + 1).lstrip(" \n"))


## The model asked to see the screen. Throw away the half-formed reply and put
## the request to the user; if they allow it, the same question comes back with
## a screenshot attached. The question is already the last turn in history, so
## it isn't recorded twice.
##
## Deferred because this runs inside the provider's own chunk signal, and tearing
## its HTTP client down mid-poll leaves it reading from a client that's gone.
func _take_a_look() -> void:
	_tag_resolved = true
	_tag_buffer = ""
	_request_look.call_deferred()


func _request_look() -> void:
	_provider.cancel()
	EventBus.screen_look_requested.emit(_last_question, false)


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
	_in_vision_pass = false
	push_warning("LLMService: %s" % message)
	EventBus.reply_failed.emit(message)


func _load_persona() -> String:
	var text := FileAccess.get_file_as_string(PERSONA_PATH)
	if text.is_empty():
		push_warning("LLMService: no persona at %s" % PERSONA_PATH)
		return "你是一隻住在使用者桌面上的小寵物，用繁體中文簡短回話。"
	return text
