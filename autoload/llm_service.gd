extends Node

## Turns "the user said something" into "the pet replied", and owns everything
## in between: which backend is active, the conversation history, and the system
## prompt. Everyone else talks to it through EventBus.
##
## Phase 6 folds the needs system into the system prompt; Phase 9 adds long-term
## memory. Both plug in at `build_system_prompt()`.

const PERSONA_PATH := "res://prompts/persona.md"

## Turns of conversation kept verbatim. Older turns get dropped; Phase 9
## replaces this with summarise-and-drop.
const HISTORY_TURNS := 20

const PROVIDERS := {
	"mock": "res://llm/providers/mock_provider.gd",
	"openai": "res://llm/providers/openai_provider.gd",
}

var _provider: LLMProvider = null
var _provider_name := ""
var _history: Array[Dictionary] = []
var _persona := ""


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
	_provider.chunk_received.connect(EventBus.reply_chunk.emit)
	_provider.finished.connect(_on_finished)
	_provider.failed.connect(_on_failed)

	_provider_name = name


func is_busy() -> bool:
	return _provider != null and _provider.is_busy()


## Abandon the in-flight reply — the user interrupted.
func interrupt() -> void:
	if _provider != null:
		_provider.cancel()


func clear_history() -> void:
	_history.clear()


func build_system_prompt() -> String:
	return _persona


func _on_user_said(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_empty() or _provider == null:
		return
	# A new message replaces whatever the pet was mid-way through saying.
	if _provider.is_busy():
		_provider.cancel()

	_history.append({"role": "user", "content": trimmed})
	_trim_history()
	_provider.send(_history.duplicate(true), build_system_prompt())


func _on_finished(full_text: String) -> void:
	_history.append({"role": "assistant", "content": full_text})
	_trim_history()
	EventBus.reply_finished.emit(full_text)


func _on_failed(message: String) -> void:
	# Drop the unanswered user turn so a retry doesn't stack duplicates.
	if not _history.is_empty() and _history[-1].get("role") == "user":
		_history.pop_back()
	push_warning("LLMService: %s" % message)
	EventBus.reply_failed.emit(message)


func _trim_history() -> void:
	var excess := _history.size() - HISTORY_TURNS * 2
	if excess > 0:
		_history = _history.slice(excess)


func _load_persona() -> String:
	var text := FileAccess.get_file_as_string(PERSONA_PATH)
	if text.is_empty():
		push_warning("LLMService: no persona at %s" % PERSONA_PATH)
		return "你是一隻住在使用者桌面上的小寵物，用繁體中文簡短回話。"
	return text
