extends Node

const OpenAIProviderScript := preload("res://llm/providers/openai_provider.gd")

var _failures := 0
var _checks := 0
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"defaults and registry": _test_defaults_and_registry,
		"reasoning compatibility": _test_reasoning_compatibility,
		"request payload": _test_request_payload,
	}
	for name: String in tests:
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("OpenAIProvider: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("OpenAIProvider model settings: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("OpenAIProvider model settings: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


func _test_defaults_and_registry() -> void:
	_expect(OpenAIProviderScript.DEFAULT_MODEL == "gpt-5.6-luna",
		"Luna is not the default chat model")
	_expect(OpenAIProviderScript.DEFAULT_REASONING_EFFORT == "none",
		"the default reasoning effort is not none")

	var ids := PackedStringArray()
	var defaults := PackedStringArray()
	for model in OpenAIProviderScript.MODELS:
		ids.append(str(model["id"]))
		if str(model.get("note", "")) == "預設":
			defaults.append(str(model["id"]))
	for wanted in ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]:
		_expect(ids.has(wanted), "model registry is missing %s" % wanted)
	_expect(defaults == PackedStringArray(["gpt-5.6-luna"]),
		"the model registry does not mark only Luna as the default")

	var effort_ids := OpenAIProviderScript.reasoning_effort_ids()
	_expect(effort_ids == PackedStringArray(["none", "low", "medium", "high", "xhigh", "max"]),
		"reasoning effort ids or their display order changed")
	_done("defaults and registry")


func _test_reasoning_compatibility() -> void:
	for model in ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]:
		_expect(OpenAIProviderScript.supported_reasoning_efforts(model).has("max"),
			"%s does not expose max reasoning" % model)
	for model in ["gpt-5.4-nano", "gpt-5.4-mini", "gpt-5.4", "gpt-5.5"]:
		var supported := OpenAIProviderScript.supported_reasoning_efforts(model)
		_expect(supported.has("xhigh") and not supported.has("max"),
			"%s has the wrong reasoning range" % model)
	_expect(OpenAIProviderScript.effective_reasoning_effort("gpt-5.6-luna", "max") == "max",
		"Luna unexpectedly clamps max reasoning")
	_expect(OpenAIProviderScript.effective_reasoning_effort("gpt-5.5", "max") == "xhigh",
		"an older model did not clamp max to xhigh")
	_expect(OpenAIProviderScript.effective_reasoning_effort("gpt-5.6-luna", "broken") == "none",
		"an unknown reasoning effort did not fall back to none")
	_done("reasoning compatibility")


func _test_request_payload() -> void:
	var encoded: String = OpenAIProviderScript.build_payload(
		[{"role": "user", "content": "你好"}], "system", "gpt-5.6-luna", "none", 320)
	var decoded: Variant = JSON.parse_string(encoded)
	_expect(typeof(decoded) == TYPE_DICTIONARY, "request payload is not JSON object")
	if typeof(decoded) != TYPE_DICTIONARY:
		_done("request payload")
		return
	var payload := decoded as Dictionary
	_expect(payload.get("model") == "gpt-5.6-luna", "payload did not use Luna")
	_expect(payload.get("reasoning_effort") == "none", "payload omitted the reasoning effort")
	_expect(payload.get("stream") == true, "payload stopped requesting SSE streaming")
	_expect(payload.get("max_completion_tokens") == 320, "payload changed the reply token cap")
	var messages: Array = payload.get("messages", [])
	_expect(messages.size() == 2, "payload did not preserve system and user messages")
	if messages.size() == 2:
		_expect(messages[0].get("role") == "system" and messages[0].get("content") == "system",
			"payload changed the system message")
		_expect(messages[1].get("role") == "user" and messages[1].get("content") == "你好",
			"payload changed the user message")
	var reasoning_payload: Variant = JSON.parse_string(OpenAIProviderScript.build_payload(
		[], "system", "gpt-5.6-luna", "max", 320))
	_expect(typeof(reasoning_payload) == TYPE_DICTIONARY
		and reasoning_payload.get("max_completion_tokens") == 16384,
		"max reasoning did not receive enough completion-token headroom")
	_done("request payload")
