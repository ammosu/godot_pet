extends Node

## Lets the user hand the pet a file by dragging it onto its sprite, and gets
## the pet to talk about it.
##
## Classifies and reads the file, then hands off to the existing turn
## machinery instead of inventing a parallel one: text becomes a message on
## EventBus.file_content_said (not user_said — see the comment on that
## signal), and an image rides the exact image_url path VisionService already
## built for screen-looks (LLMService.ask_about_image()).

## Above this, don't even try — decline instead of reading. Either the file
## isn't meant to be skimmed a few KB at a time in the first place, or (for
## an image) decoding it would block the main thread for a while with
## nothing on screen to show for it; there's no worker thread for this, only
## the polled, non-blocking streaming openai_provider.gd already uses.
const MAX_FILE_SIZE := 10 * 1024 * 1024

## How much of a text file's content actually reaches the model. Same order
## of magnitude as a screenshot's ~570 prompt tokens at "low" detail (see
## VisionService.MAX_EDGE) — a dropped file shouldn't cost noticeably more
## than a dropped picture.
const TRUNCATE_BYTES := 4000

const TEXT_EXTENSIONS := [
	"txt", "md", "markdown", "log", "csv", "tsv", "json", "yaml", "yml",
	"ini", "cfg", "conf", "toml", "xml", "html", "htm", "css",
	"gd", "py", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh",
	"c", "h", "cpp", "hpp", "cc", "java", "kt", "rs", "go", "rb", "php",
	"swift", "sql", "gdshader",
]
## Read as text by extension, and then deliberately not read.
##
## `.env` beside the project or the executable is the third place
## `Config.get_secret()` looks for OPENAI_API_KEY, so the most likely `.env` on
## this machine holds the user's own key — and a dropped file is persisted like
## any other turn, so it would go into memory.json and be offered up for fact
## extraction. Dropping one is a deliberate act rather than exfiltration, but a
## project that pipes secrets over stdin to keep them out of `ps` should not
## then paste one into a chat because the extension happened to be on a list.
const SECRET_BASENAMES := ["env", "npmrc", "netrc", "pgpass", "htpasswd"]
const SECRET_EXTENSIONS := ["env", "pem", "key", "p12", "pfx", "keystore", "jks"]
## Common extensionless text files.
const TEXT_BASENAMES := [
	"readme", "license", "changelog", "makefile", "dockerfile", "gitignore",
	"todo", "notice", "authors", "contributing",
]
## Whatever Image.load_from_file() can actually decode without an editor
## import step — pets/pet_pack.gd already relies on exactly this at runtime
## for spritesheets loaded from an arbitrary absolute path.
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]


## Entry point: pet.gd calls this once a drop is confirmed to land on the
## pet. Always ends in exactly one file_content_said emission or one
## LLMService.ask_about_image() call, so the caller never branches on the
## outcome.
func handle_drop(raw_path: String) -> void:
	# Windows hands back native backslash paths; String.get_file() /
	# get_extension() only recognise "/", so an un-normalised path would look
	# like it has no directory and no extension. FileAccess/DirAccess accept
	# forward slashes on Windows too, so normalising once here beats special-
	# casing every string op below.
	var path := raw_path.replace("\\", "/")

	if DirAccess.dir_exists_absolute(path):
		_say(_folder_message(path.get_file()))
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("FileDropService: cannot open '%s' (%d)"
			% [path, FileAccess.get_open_error()])
		_say(_unopenable_message(path.get_file()))
		return

	var name := path.get_file()
	var ext := path.get_extension().to_lower()
	var size := file.get_length()

	# Ahead of every other branch, so that no path reads the bytes.
	if _looks_like_a_secret(name, ext):
		file.close()
		_say(_secret_message(name))
		return

	if size == 0:
		file.close()
		_say(_empty_message(name))
		return

	if size > MAX_FILE_SIZE:
		file.close()
		_say(_too_big_message(name, size))
		return

	if IMAGE_EXTENSIONS.has(ext):
		file.close()
		_handle_image(path, name, ext)
		return

	if TEXT_EXTENSIONS.has(ext) or (ext.is_empty() and TEXT_BASENAMES.has(name.to_lower())):
		var truncated := size > TRUNCATE_BYTES
		var bytes := file.get_buffer(mini(size, TRUNCATE_BYTES))
		file.close()
		_say(_text_message(name, bytes.get_string_from_utf8(), truncated))
		return

	file.close()
	_say(_unreadable_message(name, ext))


func _handle_image(path: String, name: String, ext: String) -> void:
	var image := Image.load_from_file(path)
	if image == null:
		_say(_unreadable_message(name, ext))
		return
	var data_url := VisionService.image_to_data_url(image)
	# record_question: true — this is a fresh turn; nothing has appended it yet.
	# ephemeral: false — unlike a screen look, the user handed this over on
	# purpose. It's the kind of thing worth remembering, not an incidental
	# glimpse of whatever else happened to be open — see the reasoning on
	# LLMService.ask_about_image().
	LLMService.ask_about_image(_image_question(name), data_url, true, false)


## Phrased as if the user said it, so it reads naturally wherever a `user`
## turn's content is used verbatim — MemoryStore._condense_prompt() labels it
## "使用者：…", and it's what the model replies to directly.
func _say(text: String) -> void:
	EventBus.file_content_said.emit(text)


func _text_message(name: String, content: String, truncated: bool) -> String:
	var note := "（有點長，我只貼了前面一段）" if truncated else ""
	return "我拖了一個檔案給你看，檔名是「%s」%s。內容是：\n\n%s" % [name, note, content]


func _image_question(name: String) -> String:
	return "我拖了一張圖片給你看，檔名是「%s」。你看看，說說你看到什麼或想法。" % name


## `.env` has no extension by String.get_extension()'s reckoning — the whole
## filename is the "extension" it reports for a dotfile — so match on both.
func _looks_like_a_secret(name: String, ext: String) -> bool:
	var lower := name.to_lower()
	if SECRET_EXTENSIONS.has(ext):
		return true
	if not lower.begins_with("."):
		return false
	return SECRET_BASENAMES.has(lower.substr(1).get_slice(".", 0))


func _secret_message(name: String) -> String:
	return "我拖了一個檔案給你看，檔名是「%s」，看起來是放密鑰或密碼的，你沒有讀它，也不要問我裡面寫什麼。跟我說一聲你沒看就好。" % name


func _unreadable_message(name: String, ext: String) -> String:
	var kind := ".%s" % ext if not ext.is_empty() else "沒有副檔名的"
	return "我拖了一個檔案給你看，檔名是「%s」，是%s檔，你應該打不開，老實跟我說吧，別假裝看得懂。" % [name, kind]


func _too_big_message(name: String, size: int) -> String:
	return "我拖了一個檔案給你看，檔名是「%s」，有%s，太大了你應該看不完，別勉強自己讀，跟我說一聲就好。" \
		% [name, _human_size(size)]


func _empty_message(name: String) -> String:
	return "我拖了一個檔案給你看，檔名是「%s」，不過打開來好像是空的。" % name


func _folder_message(name: String) -> String:
	return "我把一個資料夾「%s」拖給你看，不是檔案，你應該打不開，跟我說一聲。" % name


func _unopenable_message(name: String) -> String:
	return "我剛剛想拖一個檔案「%s」給你看，但好像打不開，可能被移走了，跟我說一聲就好。" % name


func _human_size(bytes: int) -> String:
	if bytes >= 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	return "%.0f KB" % (bytes / 1024.0)
