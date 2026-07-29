extends Node

## The folders the pet is allowed to work in.
##
## This is the whole trust boundary of the work feature, and it starts **empty**.
## OutboxService owns one fixed folder that exists for the pet, so it needs no
## allowlist; this points at the user's own projects, where the risk is not
## clutter but their code. Nothing is inferred, nothing is scanned, and there is
## no "current directory" — a folder is here because the user put it here, one at
## a time.
##
## Each entry carries its own level, so a repo can be demoted to read-only
## without removing it. The default for a newly added folder is LEVEL_EDIT: the
## user chose that deliberately, having been shown what it means.

## A workspace was added, removed or had its level changed.
signal changed

const SECTION := "work"
const KEY_SPACES := "spaces"

## What the agent may do in a given folder.
##
## READ maps to an agent that plans and reads but cannot write; EDIT maps to one
## that changes files in place. There is deliberately no third level above EDIT —
## "and may also reach outside the folder" is not a thing this offers.
const LEVEL_READ := "read"
const LEVEL_EDIT := "edit"
const DEFAULT_LEVEL := LEVEL_EDIT

## Long enough to be sure, short enough that a wedged `git` can't hold the frame.
## Every git call here is on the main thread, so all of them are cheap ones.
const GIT_TIMEOUT_MS := 4000

## Guards the diff listing against a repo with an enormous uncommitted change —
## the panel shows what changed, it is not a diff viewer.
const MAX_DIFF_LINES := 40


func _ready() -> void:
	pass


## Every workspace, oldest first — the order the user added them, which is the
## only order they have a reason to expect.
func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = Config.get_value(SECTION, KEY_SPACES, [])
	if not (raw is Array):
		return out
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var path := str(entry.get("path", ""))
		if path.is_empty():
			continue
		out.append({
			"path": path,
			"name": path.get_file(),
			"level": _valid_level(str(entry.get("level", DEFAULT_LEVEL))),
			# Answered on read rather than stored: a folder can be deleted or
			# renamed while the pet is running, and a stale "yes" would send an
			# agent at a path that isn't there.
			"exists": DirAccess.dir_exists_absolute(path),
		})
	return out


func is_empty() -> bool:
	return list().is_empty()


func has(path: String) -> bool:
	var wanted := normalise(path)
	for space in list():
		if str(space["path"]) == wanted:
			return true
	return false


func get_space(path: String) -> Dictionary:
	var wanted := normalise(path)
	for space in list():
		if str(space["path"]) == wanted:
			return space
	return {}


## Strip a trailing separator and normalise Windows backslashes, so the same
## folder added twice by two different routes is recognised as one.
func normalise(path: String) -> String:
	var clean := path.replace("\\", "/").strip_edges()
	while clean.length() > 1 and clean.ends_with("/"):
		clean = clean.substr(0, clean.length() - 1)
	return clean


## Why a path can't be a workspace, or empty if it can.
##
## Returned as a sentence rather than a bool because every caller here has a
## person waiting on an answer, and "no" without "why" is the shape of a feature
## that looks broken.
func rejection_reason(raw: String) -> String:
	var path := normalise(raw)
	if path.is_empty():
		return "這不是一個資料夾路徑。"
	if not path.begins_with("/") and not path.contains(":/"):
		return "我需要完整的路徑才找得到。"
	if not DirAccess.dir_exists_absolute(path):
		return "找不到這個資料夾，或者那是一個檔案。"

	# The whole disk, or the whole home directory. Either one makes the allowlist
	# meaningless in a single click, which is exactly what an allowlist is for.
	if path == "/" or path.get_slice_count("/") <= 2:
		return "這個範圍太大了，給我一個專案資料夾就好。"
	var home := normalise(OS.get_environment("HOME"))
	if not home.is_empty() and path == home:
		return "整個家目錄太大了，給我裡面某一個專案就好。"

	# One rule instead of a list of names: ~/.ssh, ~/.gnupg, ~/.config, ~/.codex
	# and ~/.claude are all hidden, and so is every future one. A dotted component
	# anywhere in the path is enough to refuse — a project living inside a hidden
	# folder is rare, and being wrong in that direction costs the user nothing
	# worse than typing a different path.
	for part in path.split("/", false):
		if part.begins_with("."):
			return "這是隱藏資料夾，裡面通常放設定和金鑰，我不碰。"

	# Its own outbox. Not dangerous, just wrong: that folder is the pet's own
	# (OutboxService), and pointing an agent at it would make "what changed"
	# ambiguous between the two.
	if path == normalise(OutboxService.folder_path()):
		return "那是我放東西的資料夾，本來就歸我管。"

	if has(path):
		return "這個已經在清單裡了。"
	return ""


## Add a folder. Returns the reason it couldn't be, or empty on success.
func add(raw: String, level := DEFAULT_LEVEL) -> String:
	var reason := rejection_reason(raw)
	if not reason.is_empty():
		return reason
	var spaces := _raw_list()
	spaces.append({"path": normalise(raw), "level": _valid_level(level)})
	_store(spaces)
	return ""


func remove(raw: String) -> void:
	var wanted := normalise(raw)
	var kept := []
	for entry in _raw_list():
		if entry is Dictionary and str(entry.get("path", "")) == wanted:
			continue
		kept.append(entry)
	_store(kept)


func set_level(raw: String, level: String) -> void:
	var wanted := normalise(raw)
	var spaces := _raw_list()
	for entry in spaces:
		if entry is Dictionary and str(entry.get("path", "")) == wanted:
			entry["level"] = _valid_level(level)
	_store(spaces)


func level_label(level: String) -> String:
	return "可以改" if level == LEVEL_EDIT else "只能看"


# --- Sessions -----------------------------------------------------------------

## The agent conversation attached to this folder, or empty.
##
## Kept **per workspace**, not globally: a session carries what the agent read and
## concluded, and resuming it somewhere else would answer questions about the
## wrong project. Stored inside the workspace entry so removing the folder takes
## the session with it, with no separate table to keep in step.
func get_session(raw: String) -> String:
	var wanted := normalise(raw)
	for entry in _raw_list():
		if entry is Dictionary and str(entry.get("path", "")) == wanted:
			return str(entry.get("session", ""))
	return ""


func set_session(raw: String, session_id: String) -> void:
	var wanted := normalise(raw)
	var spaces := _raw_list()
	var touched := false
	for entry in spaces:
		if entry is Dictionary and str(entry.get("path", "")) == wanted:
			entry["session"] = session_id
			touched = true
	if touched:
		# Deliberately not through _store(): a session id changing is not a change
		# to the *list*, and emitting `changed` here would rebuild the menu and the
		# panel rows after every single job.
		Config.set_value(SECTION, KEY_SPACES, spaces)


func clear_session(raw: String) -> void:
	set_session(raw, "")


func _valid_level(level: String) -> String:
	return LEVEL_EDIT if level == LEVEL_EDIT else LEVEL_READ


func _raw_list() -> Array:
	var raw: Variant = Config.get_value(SECTION, KEY_SPACES, [])
	return raw.duplicate(true) if raw is Array else []


func _store(spaces: Array) -> void:
	Config.set_value(SECTION, KEY_SPACES, spaces)
	changed.emit()


# --- Git ----------------------------------------------------------------------

## Whether git can be run at all. Not having it isn't fatal — a workspace can
## still be worked in — it only means the "what changed" report and the
## uncommitted-work warning go quiet.
func has_git() -> bool:
	if _git_present == -1:
		var out := []
		_git_present = 1 if OS.execute("git", ["--version"], out, true) == 0 else 0
	return _git_present == 1

var _git_present := -1


func is_repo(path: String) -> bool:
	if not has_git():
		return false
	return _git(path, ["rev-parse", "--is-inside-work-tree"])["ok"]


## Files with uncommitted changes, as a count. The warning shown before a job
## starts is built from this.
##
## Deliberately counts **staged, unstaged and untracked alike** — the question the
## user is being asked is "is there work here that git cannot get back for you",
## and an untracked file answers yes just as loudly as a modified one.
func dirty_count(path: String) -> int:
	if not is_repo(path):
		return 0
	var result := _git(path, ["status", "--porcelain"])
	if not result["ok"]:
		return 0
	var count := 0
	for line in str(result["out"]).split("\n", false):
		if not line.strip_edges().is_empty():
			count += 1
	return count


## Current commit, so what the agent did can be described as a range afterwards.
func head(path: String) -> String:
	if not is_repo(path):
		return ""
	var result := _git(path, ["rev-parse", "HEAD"])
	return str(result["out"]).strip_edges() if result["ok"] else ""


## What changed in the working tree, as `git diff --stat` lines.
##
## Includes untracked files by name, which `diff` alone never shows — an agent
## asked to add a file would otherwise report as having changed nothing at all,
## which is the single most confusing thing this panel could say.
func changes(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not is_repo(path):
		return out
	var diff := _git(path, ["diff", "--stat", "--no-color"])
	if diff["ok"]:
		for line in str(diff["out"]).split("\n", false):
			var text := line.strip_edges()
			# `--stat` ends with its own summary ("1 file changed, 1 insertion(+)"),
			# which is a sentence about the list rather than a member of it. Counting
			# it made a single-file change report as 「改了 2 項」.
			if text.is_empty() or text.contains("file changed") or text.contains("files changed"):
				continue
			out.append(text)
	var untracked := _git(path, ["ls-files", "--others", "--exclude-standard"])
	if untracked["ok"]:
		for line in str(untracked["out"]).split("\n", false):
			var name := line.strip_edges()
			if not name.is_empty():
				out.append("%s（新檔案）" % name)
	if out.size() > MAX_DIFF_LINES:
		var trimmed := out.slice(0, MAX_DIFF_LINES)
		trimmed.append("…還有 %d 項" % (out.size() - MAX_DIFF_LINES))
		return trimmed
	return out


## `git -C <path>` rather than changing this process's working directory: there is
## one of those and the whole app shares it.
func _git(path: String, args: Array) -> Dictionary:
	var full := ["-C", path]
	full.append_array(args)
	var out := []
	var code := OS.execute("git", full, out, true)
	return {
		"ok": code == 0,
		"out": out[0] if not out.is_empty() else "",
	}
