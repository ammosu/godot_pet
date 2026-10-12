extends Node

## MicrophoneFlow asks pet.gd for the indicator, the attention and the chat turn
## rather than doing them itself. Only the paths that never open the microphone,
## write config or reach a model are exercised.

var _failures := 0
var _checks := 0
var _finished: Array[String] = []
var _events: Array[Array] = []


func _ready() -> void:
	var tests := {
		"the recording indicator names its stop": _test_recording_indicator,
		"a transcription closes the indicator first": _test_transcription_order,
		"a failed turn closes and says why": _test_failed_turn,
	}
	for name: String in tests:
		_events.clear()
		(tests[name] as Callable).call()
	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("MicrophoneFlow: the '%s' test did not run to the end" % name)
	if _failures == 0:
		print("MicrophoneFlow: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("MicrophoneFlow: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _done(name: String) -> void:
	_finished.append(name)


## Not set up: setup() connects to the live recorder and speech-input services.
func _flow() -> MicrophoneFlow:
	var flow := MicrophoneFlow.new()
	add_child(flow)
	flow.said.connect(func(emotion: String, text: String, record: bool, unprompted: bool) -> void:
		_events.append(["said", emotion, text, record, unprompted]))
	flow.holding.connect(func(message: String, action: String) -> void:
		_events.append(["holding", message, action]))
	flow.holding_ended.connect(func() -> void: _events.append(["holding_ended"]))
	flow.transcribed.connect(func(text: String) -> void: _events.append(["transcribed", text]))
	return flow


## Between the microphone opening and closing, the indicator is the only thing on
## screen saying so — and it has to say how to stop.
func _test_recording_indicator() -> void:
	var flow := _flow()
	flow._on_recording_tick("0:05")
	_expect(_events == [["holding", "● 錄音中 0:05", "停止錄音"]],
		"the recording indicator changed: %s" % [_events])
	flow.free()
	_done("the recording indicator names its stop")


## The bubble is the indicator and the reply's surface both; closing it after
## the turn starts would close the reply instead.
func _test_transcription_order() -> void:
	var flow := _flow()
	flow._on_speech_transcribed("今天天氣如何")
	_expect(_events == [["holding_ended"], ["transcribed", "今天天氣如何"]],
		"a transcription arrived out of order: %s" % [_events])
	flow.free()
	_done("a transcription closes the indicator first")


func _test_failed_turn() -> void:
	var flow := _flow()
	flow._on_speech_input_failed("聽不清楚")
	_expect(_events == [["holding_ended"], ["said", "sad", "聽不清楚", false, false]],
		"a failed voice turn changed shape: %s" % [_events])
	flow.free()
	_done("a failed turn closes and says why")
