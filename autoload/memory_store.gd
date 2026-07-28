extends Node

## What the pet remembers, and the only reason it feels like the same pet
## tomorrow. Owns the conversation history outright — LLMService asks for the
## messages to send rather than keeping its own copy.
##
## Three layers, cheapest first:
##   history  recent turns, verbatim, so a restart resumes mid-conversation
##   summary  older turns folded into a paragraph by the model
##   facts    durable one-liners about the user, kept until they're forgotten
##
## Folding costs an API call, so it happens in batches rather than every turn.

const PATH := "user://memory.json"

## Messages (not exchanges) kept verbatim and sent with every request.
const RECENT_MESSAGES := 16
## Wait for this many messages to fall out of the window before paying for a
## fold. Folding every single turn would roughly double the API calls.
const CONDENSE_BATCH := 12
## If folding keeps failing, drop the oldest anyway rather than growing forever.
const HARD_MAX_MESSAGES := 60
const MAX_FACTS := 30

const CONDENSE_SYSTEM := """你是一個記憶整理器，不是對話助手。

根據「既有摘要」和「新對話」，輸出一個 JSON 物件，格式如下：
{"summary": "...", "facts": ["...", "..."]}

- summary：把既有摘要與新對話合併成一段**不超過 200 字**的敘述，只保留對日後對話有用的脈絡
- facts：關於使用者的**長期事實**（名字、工作、喜好、討厭的東西、習慣、長期在做的事），每則不超過 20 字。沒有就給空陣列
- facts 只寫使用者**明確說過**的，不要推測、不要引申
- 幾天後就會過期的事（今天修了什麼 bug、今天開幾個會、當下心情）不要寫進 facts，那些留在 summary 就好
- 寒暄和一次性閒聊兩邊都不要寫

只輸出 JSON，前後不要有任何其他文字。"""

var _history: Array[Dictionary] = []
var _facts: PackedStringArray = []
var _summary := ""
var _condensing := false
var _dirty := false
## Bumped every time the history is thrown away, so a fold already in flight can
## tell that it is about to write turns the user has since asked to forget.
var _epoch := 0


func _ready() -> void:
	_load()
	var timer := Timer.new()
	timer.wait_time = 20.0
	timer.timeout.connect(_save_if_dirty)
	add_child(timer)
	timer.start()


func _exit_tree() -> void:
	_save_if_dirty()


# --- Conversation -------------------------------------------------------------

## `ephemeral` turns describe something that was only true for a moment — what
## was on screen, say. They stay in the recent window so follow-up questions
## still make sense, but never reach the summary, the facts, or the save file.
func append(role: String, content: String, ephemeral := false) -> void:
	var text := content.strip_edges()
	if text.is_empty():
		return
	_history.append({"role": role, "content": text, "ephemeral": ephemeral})
	_dirty = true


## Undo the last turn — used when a request failed, so a retry doesn't stack
## duplicate user messages.
func drop_trailing_user_turn() -> void:
	if not _history.is_empty() and _history[-1].get("role") == "user":
		_history.pop_back()
		_dirty = true


## Every verbatim turn still held, `ephemeral` flag and all — for the transcript
## window, which is the one caller that has to show what won't survive the
## session. Deliberately not recent_messages(): that one is the wire format, cut
## to the window the API sees and stripped of anything the API mustn't get.
func history() -> Array[Dictionary]:
	return _history.duplicate(true)


## Start a fresh conversation without becoming a stranger: the verbatim turns go,
## the summary and the facts stay.
##
## Those are two different kinds of memory — what we were just talking about, and
## who you are — and only the first is what "new conversation" means. Wiping both
## is still available, one window along, as 全部忘掉.
func clear_history() -> bool:
	if _history.is_empty():
		return false
	_history.clear()
	_epoch += 1
	_dirty = true
	_save_if_dirty()
	return true


## Wire format only: the bookkeeping flag must not reach the API.
func recent_messages() -> Array:
	var start := maxi(0, _history.size() - RECENT_MESSAGES)
	var out := []
	for message in _history.slice(start):
		out.append({"role": message["role"], "content": message["content"]})
	return out


# --- Prompt -------------------------------------------------------------------

## The block describing what the pet already knows. Empty on a fresh install, so
## the prompt doesn't carry a heading with nothing under it.
func context_block() -> String:
	var parts := PackedStringArray()
	if not _facts.is_empty():
		var lines := PackedStringArray()
		for fact in _facts:
			lines.append("- %s" % fact)
		parts.append("## 你記得關於使用者的事\n%s" % "\n".join(lines))
	if not _summary.is_empty():
		parts.append("## 你們之前聊過什麼\n%s" % _summary)
	return "\n\n".join(parts)


func facts() -> PackedStringArray:
	return _facts.duplicate()


func summary() -> String:
	return _summary


## Drop one remembered line. Memory you can't correct is memory you have to wipe
## wholesale, and a single wrong fact is a bad reason to lose the rest.
func forget_fact(fact: String) -> bool:
	var index := Array(_facts).find(fact)
	if index < 0:
		return false
	_facts.remove_at(index)
	_dirty = true
	_save_if_dirty()
	return true


## The summary is written by the model and can't be edited line by line, so
## clearing it is all or nothing.
func forget_summary() -> void:
	if _summary.is_empty():
		return
	_summary = ""
	_dirty = true
	_save_if_dirty()


func has_memories() -> bool:
	return not _facts.is_empty() or not _summary.is_empty()


func forget_all() -> void:
	_history.clear()
	_epoch += 1
	_facts = PackedStringArray()
	_summary = ""
	_dirty = true
	_save_if_dirty()


# --- Condensing ---------------------------------------------------------------

## Called after each completed exchange. Folds the messages that have aged out
## of the verbatim window into the summary and facts.
func maybe_condense() -> void:
	if _condensing:
		return
	var overflow := _history.size() - RECENT_MESSAGES
	if overflow < CONDENSE_BATCH:
		return

	var aged := _history.slice(0, overflow)
	_condensing = true
	var epoch := _epoch
	var sent: bool = LLMService.request_background(
		CONDENSE_SYSTEM, _condense_prompt(aged),
		func(reply: String) -> void: _on_condensed(reply, overflow, epoch))
	if not sent:
		_condensing = false
		# No backend able to summarise (mock, or no key). Only start discarding
		# once the history is genuinely unwieldy.
		if _history.size() > HARD_MAX_MESSAGES:
			_history = _history.slice(_history.size() - RECENT_MESSAGES)
			_dirty = true


func _condense_prompt(aged: Array) -> String:
	var lines := PackedStringArray()
	for message in aged:
		if message.get("ephemeral", false):
			continue
		var who := "使用者" if message.get("role") == "user" else "寵物"
		lines.append("%s：%s" % [who, message.get("content", "")])
	return "既有摘要：\n%s\n\n新對話：\n%s" % [
		"（還沒有）" if _summary.is_empty() else _summary,
		"\n".join(lines),
	]


func _on_condensed(reply: String, consumed: int, epoch: int) -> void:
	_condensing = false
	# The conversation this was folding no longer exists — the user cleared it
	# while the request was in flight. Writing the summary anyway would put the
	# turns they just dropped somewhere permanent, which is the one outcome
	# 清空 has to rule out.
	if epoch != _epoch:
		return
	var data: Variant = JSON.parse_string(_strip_code_fence(reply))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("MemoryStore: could not parse the fold, keeping the turns")
		return

	var summary := str(data.get("summary", "")).strip_edges()
	if not summary.is_empty():
		_summary = summary
	_merge_facts(data.get("facts", []))

	# Only discard the turns that were actually folded in; anything said while
	# the request was in flight stays.
	_history = _history.slice(mini(consumed, _history.size()))
	_dirty = true
	_save_if_dirty()


## Newest wins on a duplicate, and the oldest fall off the end.
func _merge_facts(incoming: Variant) -> void:
	if typeof(incoming) != TYPE_ARRAY:
		return
	var merged := Array(_facts)
	for entry in incoming:
		var fact := str(entry).strip_edges()
		if fact.is_empty():
			continue
		var existing := merged.find(fact)
		if existing >= 0:
			merged.remove_at(existing)
		merged.append(fact)
	if merged.size() > MAX_FACTS:
		merged = merged.slice(merged.size() - MAX_FACTS)
	_facts = PackedStringArray(merged)


## Models wrap JSON in ``` fences often enough to be worth handling.
func _strip_code_fence(text: String) -> String:
	var trimmed := text.strip_edges()
	if not trimmed.begins_with("```"):
		return trimmed
	var start := trimmed.find("\n")
	var end := trimmed.rfind("```")
	if start < 0 or end <= start:
		return trimmed
	return trimmed.substr(start + 1, end - start - 1).strip_edges()


# --- Persistence --------------------------------------------------------------

func _save_if_dirty() -> void:
	if not _dirty:
		return
	_dirty = false
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		push_warning("MemoryStore: cannot write %s" % PATH)
		return
	# Cap what reaches disk so a long-running session can't grow the file
	# without bound between folds, and drop ephemeral turns entirely — quitting
	# should take whatever the pet saw on screen with it.
	var start := maxi(0, _history.size() - HARD_MAX_MESSAGES)
	var durable := []
	for message in _history.slice(start):
		if not message.get("ephemeral", false):
			durable.append({"role": message["role"], "content": message["content"]})
	file.store_string(JSON.stringify({
		"summary": _summary,
		"facts": Array(_facts),
		"history": durable,
	}))


func _load() -> void:
	var raw := FileAccess.get_file_as_string(PATH)
	if raw.is_empty():
		return
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("MemoryStore: ignoring malformed %s" % PATH)
		return

	_summary = str(data.get("summary", ""))
	_merge_facts(data.get("facts", []))
	for entry in data.get("history", []):
		if typeof(entry) == TYPE_DICTIONARY and entry.has("role") and entry.has("content"):
			_history.append({
				"role": str(entry["role"]),
				"content": str(entry["content"]),
				"ephemeral": false,
			})
