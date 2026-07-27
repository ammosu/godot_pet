extends Node
class_name LLMProvider

## What every LLM backend has to look like. Callers only ever see this, so the
## mock used during development and a real streaming HTTP client are
## interchangeable.
##
## `messages` is an array of {"role": "user"|"assistant", "content": String},
## oldest first. The system prompt is passed separately because every provider
## wants it somewhere different.

## Fired repeatedly as the reply streams in. Text is a fragment, not the whole
## reply — concatenating every chunk yields what `finished` reports.
signal chunk_received(text: String)
signal finished(full_text: String)
signal failed(message: String)


func send(_messages: Array, _system: String) -> void:
	push_error("%s does not implement send()" % get_script().resource_path)


## Abandon the in-flight reply. Must be safe to call when idle.
func cancel() -> void:
	pass


func is_busy() -> bool:
	return false
