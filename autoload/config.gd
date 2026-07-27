extends Node

## Persisted user settings, in `user://config.cfg`.
## On macOS that lives in ~/Library/Application Support/Godot/app_userdata/Godot Pet/
## — outside the repo, which is where secrets belong. Phase 3 stores the LLM API
## key here, so this file must never be committed.

const PATH := "user://config.cfg"

var _file := ConfigFile.new()
var _dotenv := {}


func _ready() -> void:
	var err := _file.load(PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("Config: failed to load %s (%d)" % [PATH, err])
	_load_dotenv()


## API keys and the like. Never log the result.
##
## Order: the real environment first, so a key exported in the shell always wins
## for a one-off run; then the OS credential store, which is where the app puts
## anything the user types in; then .env and the saved config, which are both
## plaintext and exist mainly for development.
func get_secret(key: String) -> String:
	var value := OS.get_environment(key)
	if not value.is_empty():
		return value
	value = SecretStore.read(key)
	if not value.is_empty():
		return value
	if _dotenv.has(key):
		return str(_dotenv[key])
	return str(_file.get_value("secrets", key, ""))


func has_secret(key: String) -> bool:
	return not get_secret(key).is_empty()


## Returns false when it had to fall back to plaintext because the platform has
## no credential store, so callers can say so.
func set_secret(key: String, value: String) -> bool:
	if SecretStore.is_available() and SecretStore.write(key, value):
		# Drop any older plaintext copy now that the real store has it.
		if _file.has_section_key("secrets", key):
			_file.erase_section_key("secrets", key)
			_file.save(PATH)
		return true
	set_value("secrets", key, value)
	return false


func secret_backend_name() -> String:
	return SecretStore.backend_name()


## `.env` beside the project while developing, or beside the executable once
## exported. Godot doesn't do this for us.
func _load_dotenv() -> void:
	var paths := ["res://.env", OS.get_executable_path().get_base_dir().path_join(".env")]
	for path in paths:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		for line in text.split("\n", false):
			var entry := line.strip_edges()
			if entry.is_empty() or entry.begins_with("#"):
				continue
			entry = entry.trim_prefix("export ").strip_edges()
			var split := entry.split("=", true, 1)
			if split.size() != 2:
				continue
			var value := split[1].strip_edges()
			if value.length() >= 2 and (value.begins_with("\"") or value.begins_with("'")):
				value = value.substr(1, value.length() - 2)
			_dotenv[split[0].strip_edges()] = value


func get_value(section: String, key: String, default: Variant = null) -> Variant:
	return _file.get_value(section, key, default)


func set_value(section: String, key: String, value: Variant) -> void:
	_file.set_value(section, key, value)
	var err := _file.save(PATH)
	if err != OK:
		push_warning("Config: failed to save %s (%d)" % [PATH, err])
