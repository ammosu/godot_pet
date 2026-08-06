extends Node


func _ready() -> void:
	if RecorderService.MAX_SECONDS != 3600.0:
		push_error("RecorderService: expected a one-hour limit, got %.1f seconds"
			% RecorderService.MAX_SECONDS)
		get_tree().quit(1)
		return
	print("RecorderService: one-hour recording limit passed")
	get_tree().quit(0)
