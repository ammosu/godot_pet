extends Node

## Persisted user settings, in `user://config.cfg`.
## On macOS that lives in ~/Library/Application Support/Godot/app_userdata/Godot Pet/
## — outside the repo, which is where secrets belong. Phase 3 stores the LLM API
## key here, so this file must never be committed.

const PATH := "user://config.cfg"

var _file := ConfigFile.new()


func _ready() -> void:
	var err := _file.load(PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("Config: failed to load %s (%d)" % [PATH, err])


func get_value(section: String, key: String, default: Variant = null) -> Variant:
	return _file.get_value(section, key, default)


func set_value(section: String, key: String, value: Variant) -> void:
	_file.set_value(section, key, value)
	var err := _file.save(PATH)
	if err != OK:
		push_warning("Config: failed to save %s (%d)" % [PATH, err])
