extends Node

## Where the pet puts things it makes.
##
## One fixed folder, somewhere the user can actually find — `user://` is buried
## under ~/.local/share (or Application Support) and defeats the whole point: the
## value of a note the pet wrote is that you can open it without being told where
## it went.
##
## **Names arriving here are not trusted.** The pet's own exports compose them, so
## those are fine, but the "make me something" path takes the name from model
## output — and the model's input includes text the user dropped on the pet and
## whatever was legible in a screenshot. Both are places a sentence can be planted.
## So a name is reduced to a leaf, the extension has to be on a list, and an
## existing file is never overwritten.
##
## Nothing here asks permission. Unlike a screen look, writing into a folder that
## exists for this sends nothing anywhere and destroys nothing — the risk is
## clutter, not exposure, and the answer to clutter is that the list is visible
## and every line can be deleted (see ui/outbox_panel.gd).

## Under the user's documents folder.
const FOLDER_NAME := "GodotPet"

## What the pet is allowed to produce.
##
## A whitelist, and deliberately with nothing runnable on it. The pet does not
## write scripts you would then execute — that is the same line persona.md draws
## when it says the pet isn't an assistant, and it means a planted instruction
## cannot turn "write me a note" into "drop a shell script".
const ALLOWED_EXTENSIONS := ["md", "txt", "csv", "json", "svg"]

const DEFAULT_EXTENSION := "md"

## Long enough for a descriptive name, short enough that the panel stays readable
## and no filesystem's own limit is ever the thing that fails.
const MAX_STEM_LENGTH := 60

## A name that sanitised away to nothing still has to produce a file — losing what
## the pet just made is worse than a dull filename.
const FALLBACK_STEM := "小紙條"

## Refuse rather than truncate. Truncation would write half a document and report
## success, which is the failure mode SecretStore.write() exists to avoid.
const MAX_CONTENT_BYTES := 1024 * 1024

## How many collision suffixes to try before giving up. Far past any real case;
## it exists so a bug can't spin here forever.
const MAX_COLLISION_TRIES := 200


## Created on demand — an empty folder appearing on a fresh install would be
## clutter the user never asked for.
func folder_path() -> String:
	var documents := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if documents.is_empty():
		# No documents folder to speak of (a stripped-down Linux, mostly). Better
		# a working folder in the wrong place than a feature that silently does
		# nothing.
		documents = ProjectSettings.globalize_path("user://")
	return documents.path_join(FOLDER_NAME)


func ensure_folder() -> bool:
	var path := folder_path()
	if DirAccess.dir_exists_absolute(path):
		return true
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		push_warning("OutboxService: cannot create '%s' (%d)" % [path, err])
		return false
	return true


## Reduce anything at all to a safe leaf filename with an allowed extension.
## Never returns empty.
func sanitise_name(raw: String) -> String:
	# Windows hands back native backslash paths and String.get_file() only
	# recognises "/", so normalise before taking the leaf — the same one-line fix
	# FileDropService.handle_drop() makes for the same reason.
	var leaf := raw.replace("\\", "/").get_file().strip_edges()

	# ".." survives get_file() untouched — it is a legal filename — and a leading
	# dot would make a hidden file the panel then never lists.
	while leaf.begins_with("."):
		leaf = leaf.substr(1)

	var stem := leaf.get_basename()
	var ext := leaf.get_extension().to_lower()
	if not ALLOWED_EXTENSIONS.has(ext):
		# An extension we don't honour is not a reason to refuse the content. Fold
		# it into the stem instead of dropping it: "run.sh" becomes "run.sh.md",
		# which keeps what was asked for visible while making the result inert.
		if not ext.is_empty():
			stem = leaf
		ext = DEFAULT_EXTENSION

	stem = stem.validate_filename().strip_edges()
	if stem.length() > MAX_STEM_LENGTH:
		stem = stem.substr(0, MAX_STEM_LENGTH).strip_edges()
	if stem.is_empty():
		stem = FALLBACK_STEM
	return "%s.%s" % [stem, ext]


## Write, and report the filename actually used — which may not be the one asked
## for, since names are sanitised and collisions get a suffix. Empty on failure.
func write(raw_name: String, content: String) -> String:
	if content.is_empty():
		return ""
	var bytes := content.to_utf8_buffer()
	if bytes.size() > MAX_CONTENT_BYTES:
		push_warning("OutboxService: refusing %d bytes for '%s'" % [bytes.size(), raw_name])
		return ""
	if not ensure_folder():
		return ""

	var name := _free_name(sanitise_name(raw_name))
	if name.is_empty():
		return ""

	var file := FileAccess.open(folder_path().path_join(name), FileAccess.WRITE)
	if file == null:
		push_warning("OutboxService: cannot write '%s' (%d)"
			% [name, FileAccess.get_open_error()])
		return ""
	file.store_buffer(bytes)
	file.close()
	return name


## Never overwrite. The model picking the same obvious name twice must not eat the
## first thing it wrote.
func _free_name(name: String) -> String:
	var folder := folder_path()
	if not FileAccess.file_exists(folder.path_join(name)):
		return name
	var stem := name.get_basename()
	var ext := name.get_extension()
	for n in range(2, MAX_COLLISION_TRIES + 2):
		var candidate := "%s-%d.%s" % [stem, n, ext]
		if not FileAccess.file_exists(folder.path_join(candidate)):
			return candidate
	push_warning("OutboxService: too many files named like '%s'" % name)
	return ""


## Newest first — what the pet just made is what you came to look at.
func list_files() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var folder := folder_path()
	var dir := DirAccess.open(folder)
	if dir == null:
		return out
	for name in dir.get_files():
		var path := folder.path_join(name)
		var file := FileAccess.open(path, FileAccess.READ)
		var size := file.get_length() if file != null else 0
		if file != null:
			file.close()
		out.append({
			"name": name,
			"size": size,
			"modified": FileAccess.get_modified_time(path),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["modified"]) > int(b["modified"]))
	return out


func is_empty() -> bool:
	return list_files().is_empty()


## Takes a name, never a path. The panel only ever hands back something
## list_files() produced, but re-reducing it to a leaf here means no future caller
## can turn this into an arbitrary unlink.
func delete(raw_name: String) -> bool:
	var name := raw_name.replace("\\", "/").get_file()
	if name.is_empty() or name == "." or name == "..":
		return false
	var path := folder_path().path_join(name)
	if not FileAccess.file_exists(path):
		return false
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_warning("OutboxService: cannot delete '%s' (%d)" % [name, err])
		return false
	return true


func open_folder() -> void:
	if ensure_folder():
		OS.shell_open(folder_path())


func open_file(raw_name: String) -> void:
	var name := raw_name.replace("\\", "/").get_file()
	var path := folder_path().path_join(name)
	if FileAccess.file_exists(path):
		OS.shell_open(path)


func human_size(bytes: int) -> String:
	if bytes >= 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	if bytes >= 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%d B" % bytes
