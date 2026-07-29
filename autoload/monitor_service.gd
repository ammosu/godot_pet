extends Node

## What is running on this machine and what it is costing, sampled on a slow
## timer during working hours only.
##
## Sibling of PresenceService, and deliberately the other half of the same
## question. That one watches *you* — which app you are in, how long you have
## been there. This one watches the *machine* — what is running behind your back
## and what it is eating. Neither ever sends anything anywhere; both are read
## locally and kept in memory.
##
## The shape follows what a desk pet can usefully do with the answer. Scanning
## every twenty minutes and reporting every twenty minutes are different
## decisions: the scan is cheap and its value is the record it builds, while a
## line spoken out loud every twenty minutes is just noise. So the pet only opens
## its mouth when a threshold below is crossed, and everything else lives in
## MonitorPanel for whenever you want to look.
##
## Nothing here is written to disk. The process list is a list of programs you
## are running, which is not as revealing as a window title but is not nothing
## either — the same call PresenceService makes, for the same reason.

## Twenty minutes, which is what was asked for. Long enough that the two `ps`
## calls below cost nothing measurable, short enough that a runaway process is
## noticed while you are still at the desk.
const SCAN_INTERVAL := 1200.0

## One scan is two samples this far apart, and every CPU figure is the average
## over exactly that gap.
##
## The alternative — diffing against the *previous scan* twenty minutes ago —
## was rejected. It sounds more thorough and reads worse: a build that pegged
## every core for four minutes and finished would still be shown as the top
## consumer sixteen minutes later, which is the single most confusing thing a
## resource monitor can say. Two seconds answers "what is eating my machine
## right now", which is what the question actually means. The long view is the
## history strip in the panel, built out of these.
const WINDOW := 2.0

## Per ranking, not in total. Two rankings, because no single order answers both
## halves of the question — a compiler pinning four cores has a tiny footprint,
## and an editor sitting on 6 GB may be using no CPU at all.
const TOP_N := 5

## Kept in memory only, and only the two machine-wide numbers per scan — never
## the process list. A working day at twenty-minute steps, so the strip covers
## the hours the scan actually runs.
const HISTORY_LIMIT := 36

## macOS only — see _sample_processes(). `ps` over 722 processes measured 18 ms
## on the development machine. The budget is generous against that because the
## wait blocks the main thread, and the cost of being wrong is asymmetric: a scan
## skipped is invisible, a frozen pet is not.
const PROC_TIMEOUT_MS := 600
const PROC_POLL_MS := 2

const PS_PATHS := ["/bin/ps", "/usr/bin/ps"]
## `comm` goes last on purpose: it is the only field that can contain a space,
## and macOS reports a full bundle path there. Everything before it is split on
## whitespace; everything from the fourth field on is the name.
const PS_FORMAT := "pid=,rss=,time=,comm="

## Linux reports CPU time in these, and the kernel fixes them at 100 for the
## procfs ABI whatever the configured tick rate is. So the figures below have
## 10 ms resolution — which is the whole reason Linux doesn't use `ps`.
const USER_HZ := 100.0
const DEFAULT_PAGE_SIZE := 4096

const DEFAULT_START_HOUR := 9
const DEFAULT_END_HOUR := 18

## --- What counts as worth speaking up about ---------------------------------
##
## Three thresholds, all whole-machine consequences rather than curiosities. A
## single process using a lot of CPU is normal on a developer's machine and is
## deliberately *not* on this list; a machine with no memory left is not.
##
## All three are read from config.cfg's [monitor] section at startup, because
## what counts as "too much" is a property of the machine rather than of this
## app: 12% of 8 GB and 12% of 64 GB are not the same amount of trouble. There is
## no UI for them, deliberately — they are the same kind of dial as
## PetState's DECAY constants, and get the same treatment.

## Below this share of RAM still available, everything starts swapping.
const DEFAULT_MEM_TIGHT := 0.12
## One process holding this much of total RAM is worth naming, even when the
## machine as a whole is coping.
const DEFAULT_PROC_MEM_SHARE := 0.25
## Averaged across every core, over the two-second window.
const DEFAULT_CPU_BUSY := 85.0

## Per kind, so a machine that stays busy all afternoon says so once an hour
## rather than every scan. Not persisted — the same judgement Nudger makes about
## `_last_nudge_at`, and for the same reason: a fresh run should be allowed to
## tell you what it just found.
const ALERT_COOLDOWN := 3600.0

const ALERT_MEM_TIGHT := "mem_tight"
const ALERT_PROC_MEM := "proc_mem"
const ALERT_CPU_BUSY := "cpu_busy"

var _enabled := false
var _start_hour := DEFAULT_START_HOUR
var _end_hour := DEFAULT_END_HOUR
var _weekdays_only := true
var _mem_tight := DEFAULT_MEM_TIGHT
var _proc_mem_share := DEFAULT_PROC_MEM_SHARE
var _cpu_busy := DEFAULT_CPU_BUSY
var _ps := ""
## Only meaningful on Linux, and derived once — see _detect_page_size().
var _page_size := DEFAULT_PAGE_SIZE
var _timer: Timer
## The most recent completed scan, in the shape _build_sample() returns. Empty
## until one has finished.
var _latest := {}
## {at, cpu, mem_ratio} per scan, oldest first.
var _history: Array[Dictionary] = []
## Guards against a second scan starting during the two-second window — the
## panel's button and the timer can both call scan().
var _scanning := false
var _alerted_at := {}


func _ready() -> void:
	_enabled = bool(Config.get_value("monitor", "enabled", false))
	_start_hour = int(Config.get_value("monitor", "start_hour", DEFAULT_START_HOUR))
	_end_hour = int(Config.get_value("monitor", "end_hour", DEFAULT_END_HOUR))
	_weekdays_only = bool(Config.get_value("monitor", "weekdays_only", true))
	_mem_tight = float(Config.get_value("monitor", "mem_tight", DEFAULT_MEM_TIGHT))
	_proc_mem_share = float(Config.get_value("monitor", "proc_mem_share", DEFAULT_PROC_MEM_SHARE))
	_cpu_busy = float(Config.get_value("monitor", "cpu_busy", DEFAULT_CPU_BUSY))
	_ps = _first_existing(PS_PATHS)
	if OS.get_name() == "Linux":
		_page_size = _detect_page_size()

	_timer = Timer.new()
	_timer.wait_time = SCAN_INTERVAL
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	if _enabled and is_supported():
		_timer.start()
		_on_tick()


func is_supported() -> bool:
	match OS.get_name():
		"Linux":
			return DirAccess.dir_exists_absolute("/proc/self")
		"macOS":
			return not _ps.is_empty()
		_:
			# Windows has no `ps`, and the PowerShell equivalent (Get-Process
			# piped through a calculated CPU property) costs most of a second to
			# start — the same objection PresenceService records for
			# GetForegroundWindow, and the same answer: say so rather than
			# stalling the pet on a repeating timer.
			return false


func is_enabled() -> bool:
	return _enabled


func set_enabled(enabled: bool) -> void:
	if enabled and not is_supported():
		return
	_enabled = enabled
	Config.set_value("monitor", "enabled", enabled)
	if enabled:
		if _timer.is_stopped():
			_timer.start()
		_on_tick()
	else:
		_timer.stop()


func start_hour() -> int:
	return _start_hour


func end_hour() -> int:
	return _end_hour


func weekdays_only() -> bool:
	return _weekdays_only


## Human-readable, for the one place that has to explain when this runs.
func hours_label() -> String:
	return "%02d:00–%02d:00%s" % [_start_hour, _end_hour,
		"　週一至週五" if _weekdays_only else ""]


func in_work_hours() -> bool:
	var now := Time.get_datetime_dict_from_system()
	var weekday := int(now["weekday"])
	if _weekdays_only and (weekday == Time.WEEKDAY_SUNDAY or weekday == Time.WEEKDAY_SATURDAY):
		return false
	var hour := int(now["hour"])
	return hour >= _start_hour and hour < _end_hour


func latest() -> Dictionary:
	return _latest


func history() -> Array[Dictionary]:
	return _history


## The timer fires all day; the work-hours test lives here rather than in
## start/stop so changing the hours needs no timer surgery, and so a scan the
## user asks for from the panel can ignore it.
func _on_tick() -> void:
	if not in_work_hours():
		return
	scan()


## Two `ps` calls, WINDOW apart. Awaits rather than blocking: the gap is two
## whole seconds, which as a busy wait would be a frozen pet, and there is
## nothing here anyone is waiting on.
func scan() -> void:
	if _scanning or not is_supported():
		return
	_scanning = true
	var before := _sample_processes()
	var cpu_before := _machine_cpu_counters()
	if before.is_empty():
		_scanning = false
		return

	await get_tree().create_timer(WINDOW).timeout
	# set_enabled(false) or a quit can land inside that wait.
	if not is_inside_tree():
		_scanning = false
		return

	var after := _sample_processes()
	var cpu_after := _machine_cpu_counters()
	_scanning = false
	if after.is_empty():
		return

	_latest = _build_sample(before, after, cpu_before, cpu_after)
	_history.append({
		"at": _latest["at"],
		"cpu": _latest["cpu"],
		"mem_ratio": _latest["mem_ratio"],
	})
	if _history.size() > HISTORY_LIMIT:
		_history = _history.slice(_history.size() - HISTORY_LIMIT)

	EventBus.resources_sampled.emit(_latest)
	_check_alerts(_latest)


## Turns the two raw `ps` readings into the one dictionary everything else uses.
func _build_sample(before: Dictionary, after: Dictionary,
		cpu_before: Dictionary, cpu_after: Dictionary) -> Dictionary:
	var mem := _machine_memory()
	var total: int = mem["total"]

	var rows: Array[Dictionary] = []
	var summed := 0.0
	for pid in after:
		var now: Dictionary = after[pid]
		# A process that started inside the window has no baseline; counting all
		# of its CPU time against the window is an upper bound on its average,
		# never an impossible one, and treating it as zero would hide exactly the
		# thing worth noticing.
		var was: float = float(before[pid]["cpu_seconds"]) if before.has(pid) else 0.0
		var used: float = maxf(0.0, float(now["cpu_seconds"]) - was)
		summed += used
		rows.append({
			"name": str(now["name"]),
			"cpu": used / WINDOW * 100.0,
			"rss": int(now["rss"]),
			"mem_ratio": float(now["rss"]) / float(total) if total > 0 else 0.0,
		})

	var by_cpu := rows.duplicate()
	by_cpu.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["cpu"]) > float(b["cpu"]))
	var by_mem := rows.duplicate()
	by_mem.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["rss"]) > int(b["rss"]))

	return {
		"at": Time.get_unix_time_from_system(),
		"window": WINDOW,
		"cpu": _machine_cpu(cpu_before, cpu_after, summed),
		"mem_total": total,
		"mem_available": int(mem["available"]),
		"mem_ratio": 1.0 - float(mem["available"]) / float(total) if total > 0 else 0.0,
		"process_count": rows.size(),
		"top_cpu": by_cpu.slice(0, TOP_N),
		"top_mem": by_mem.slice(0, TOP_N),
	}


# --- Reading the machine ------------------------------------------------------

## pid -> {name, rss (bytes), cpu_seconds}. Empty when the read failed, which
## the caller treats as "skip this scan" rather than "nothing is running".
##
## Linux does not go through `ps`, and the reason is resolution rather than
## speed. `ps -o time` prints **whole seconds** there, so across a two-second
## window every process resolves to 0%, 50% or 100% and the CPU ranking is
## noise — measured, and it put three unrelated processes at exactly 50%.
## /proc/<pid>/stat counts in USER_HZ ticks, which is 10 ms. It is also faster:
## 741 processes read in 12.5 ms against `ps`'s 18 ms, and with no subprocess
## there is no blocking wait to bound at all.
##
## macOS keeps `ps`, where the same field carries hundredths ("0:00.42") and so
## has the resolution Linux's lacks.
func _sample_processes() -> Dictionary:
	return _sample_proc() if OS.get_name() == "Linux" else _sample_ps()


func _sample_proc() -> Dictionary:
	var dir := DirAccess.open("/proc")
	if dir == null:
		return {}
	var rows := {}
	for entry in dir.get_directories():
		if not entry.is_valid_int():
			continue
		# Processes come and go while this loop runs; one that exited is a
		# failed open, not a failed scan.
		var row := _parse_proc_stat(_read_first_line("/proc/%s/stat" % entry))
		if not row.is_empty():
			row["rss"] = int(row["rss_pages"]) * _page_size
			rows[int(row["pid"])] = row
	return rows


## "3905329 (godot) R 3905327 … 7 3 0 0 20 0 32 0 30784269 2612232192 30086 …"
##
## Split on the **last** ')' rather than on whitespace. The second field is the
## executable name in parentheses, and the kernel neither escapes nor quotes it,
## so a process named "foo) bar" is a legal way to defeat a naive parser.
## Everything after that paren is fixed-position, starting at field 3.
func _parse_proc_stat(line: String) -> Dictionary:
	var open_paren := line.find("(")
	var close_paren := line.rfind(")")
	if open_paren < 0 or close_paren < open_paren:
		return {}
	var rest := line.substr(close_paren + 1).strip_edges().split(" ", false)
	# rest[0] is `state`, which is field 3 — so field N lives at rest[N - 3].
	if rest.size() < 22:
		return {}
	return {
		"pid": int(line.substr(0, open_paren)),
		"name": _display_name(line.substr(open_paren + 1, close_paren - open_paren - 1)),
		# utime (14) + stime (15). Children's time is deliberately left out: it
		# only lands on the parent once a child is reaped, which would credit a
		# shell with everything it ever ran in one lump.
		"cpu_seconds": (float(rest[11]) + float(rest[12])) / USER_HZ,
		"rss_pages": int(rest[21]),
	}


func _sample_ps() -> Dictionary:
	var out := _run(_ps, PackedStringArray(["-Ao", PS_FORMAT]))
	var rows := {}
	for line in out.split("\n", false):
		var row := _parse_ps_line(line)
		if not row.is_empty():
			rows[int(row["pid"])] = row
	return rows


## "910549 7956468 0:16.55 Google Chrome" — three fixed fields then a name that
## may itself contain spaces, so the split is bounded rather than greedy.
func _parse_ps_line(line: String) -> Dictionary:
	var parts := line.strip_edges().split(" ", false, 3)
	if parts.size() < 4:
		return {}
	if not parts[0].is_valid_int():
		return {}
	return {
		"pid": int(parts[0]),
		# `ps` reports RSS in kilobytes.
		"rss": int(parts[1]) * 1024,
		"cpu_seconds": _cpu_seconds(parts[2]),
		# macOS reports a full executable path here; the leaf is the only part
		# that means anything to a person, and the only part worth showing.
		"name": _display_name(parts[3].strip_edges().get_file()),
	}


## Linux truncates a process name to 15 characters and does not care where the
## cut lands, so a Node server that titles itself "next-server (v15.2.1)" arrives
## as "next-server (v1". In the panel that is merely untidy; in the sentence the
## pet says out loud it came out as 「跑最兇的是 next-server (v1。」 — an
## unclosed bracket against a full stop, which reads as the app having broken
## mid-word. Dropping the orphaned fragment keeps the part that identifies the
## program and loses only the part that was cut off anyway.
static func _display_name(raw: String) -> String:
	var name := raw.strip_edges()
	var open_paren := name.find("(")
	if open_paren > 0 and name.find(")", open_paren) < 0:
		name = name.substr(0, open_paren).strip_edges()
	return name if not name.is_empty() else raw


## /proc reports RSS in pages, and Godot exposes no page size. Asking the same
## process both ways answers it exactly: `stat` counts pages, `status` counts
## kilobytes. It is 4096 everywhere x86 Linux has ever run, but an ARM kernel can
## be built at 16k or 64k, where a hard-coded constant would misreport every
## process's memory by a factor of four.
func _detect_page_size() -> int:
	var stat := _parse_proc_stat(_read_first_line("/proc/self/stat"))
	var status := _read_proc_kv("/proc/self/status", ["VmRSS"])
	if stat.is_empty() or not status.has("VmRSS") or int(stat["rss_pages"]) <= 0:
		return DEFAULT_PAGE_SIZE
	var size := roundi(float(status["VmRSS"]) * 1024.0 / float(stat["rss_pages"]))
	# Only ever a power of two in this range; anything else means the derivation
	# went wrong, and then the constant is the safer answer.
	return size if size in [4096, 8192, 16384, 65536] else DEFAULT_PAGE_SIZE


func _read_first_line(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var line := file.get_line()
	file.close()
	return line


## Accepts both shapes `ps` produces: "[[dd-]hh:]mm:ss" and "mm:ss.ff".
## Folding left by 60 handles however many colon-separated fields turn up
## without caring which is which.
static func _cpu_seconds(field: String) -> float:
	var text := field
	var days := 0.0
	var dash := text.find("-")
	if dash >= 0:
		days = float(text.substr(0, dash))
		text = text.substr(dash + 1)
	var total := 0.0
	for part in text.split(":"):
		total = total * 60.0 + float(part)
	return days * 86400.0 + total


## Total and available bytes.
##
## On Linux this reads /proc/meminfo rather than calling OS.get_memory_info(),
## because the two disagree and only one of them answers the question. Measured
## on the development machine: MemAvailable said 29.1 GB, get_memory_info()'s
## `available` said 13.4 GB — less than half, which would trip the "memory is
## tight" threshold on a machine with 44% of its RAM free.
func _machine_memory() -> Dictionary:
	if OS.get_name() == "Linux":
		var values := _read_proc_kv("/proc/meminfo", ["MemTotal", "MemAvailable"])
		if values.has("MemTotal") and values.has("MemAvailable"):
			return {
				"total": int(values["MemTotal"]) * 1024,
				"available": int(values["MemAvailable"]) * 1024,
			}
	var info := OS.get_memory_info()
	return {"total": int(info["physical"]), "available": int(info["available"])}


## Whole-machine CPU percentage, 0-100 regardless of core count.
##
## `summed` — every process's CPU seconds over the window, divided by the cores
## available — is the portable answer and is what macOS gets. It has one real
## blind spot: work done by processes that started *and finished* inside the
## window is only partly attributable, so a build spawning short-lived compilers
## under-reports. /proc/stat has no such gap, so Linux uses it.
func _machine_cpu(before: Dictionary, after: Dictionary, summed: float) -> float:
	if not before.is_empty() and not after.is_empty():
		var busy := float(after["busy"]) - float(before["busy"])
		var total := float(after["total"]) - float(before["total"])
		if total > 0.0:
			return clampf(busy / total * 100.0, 0.0, 100.0)
	var cores := maxi(1, OS.get_processor_count())
	return clampf(summed / (WINDOW * float(cores)) * 100.0, 0.0, 100.0)


## The aggregate "cpu" line of /proc/stat, split into busy and total jiffies.
## Empty on anything without procfs, which sends _machine_cpu() to its fallback.
func _machine_cpu_counters() -> Dictionary:
	if OS.get_name() != "Linux":
		return {}
	# "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
	var fields := _read_first_line("/proc/stat").split(" ", false)
	if fields.size() < 8 or fields[0] != "cpu":
		return {}
	var total := 0.0
	for i in range(1, fields.size()):
		total += float(fields[i])
	# Idle and iowait are both the machine having nothing to do.
	var idle := float(fields[4]) + float(fields[5])
	return {"busy": total - idle, "total": total}


## Reads the "Key: value kB" files under /proc.
##
## Line by line, never FileAccess.get_as_text(). Measured: procfs reports a
## length of 0 for these files, so get_as_text() hands back an **empty string**
## with no error of any kind — the read silently succeeds at nothing, and every
## number downstream becomes a zero.
func _read_proc_kv(path: String, wanted: Array) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var found := {}
	while not file.eof_reached() and found.size() < wanted.size():
		var line := file.get_line()
		var colon := line.find(":")
		if colon < 0:
			continue
		var key := line.substr(0, colon)
		if not wanted.has(key):
			continue
		var rest := line.substr(colon + 1).strip_edges().split(" ", false)
		if not rest.is_empty():
			found[key] = int(rest[0])
	file.close()
	return found


## Bounded wait on a subprocess, the same shape PresenceService uses — including
## closing stdio explicitly, since this also runs on a timer that lives as long
## as the process and a leaked pipe handle would be a slow fd leak.
func _run(tool: String, args: PackedStringArray) -> String:
	var process := OS.execute_with_pipe(tool, args)
	if process.is_empty():
		return ""
	var pid: int = process["pid"]
	var stdio: FileAccess = process["stdio"]
	var waited := 0
	while OS.is_process_running(pid) and waited < PROC_TIMEOUT_MS:
		OS.delay_msec(PROC_POLL_MS)
		waited += PROC_POLL_MS
	if OS.is_process_running(pid):
		OS.kill(pid)
		stdio.close()
		return ""
	var text := stdio.get_as_text() if OS.get_process_exit_code(pid) == 0 else ""
	stdio.close()
	return text


func _first_existing(candidates: Array) -> String:
	for path in candidates:
		if FileAccess.file_exists(path):
			return path
	return ""


# --- Speaking up --------------------------------------------------------------

## At most one line per scan, and the most consequential one wins: no memory
## left beats one program holding a lot of it, which beats a busy CPU. Three
## lines at once would be the pet reading out a dashboard, which is exactly what
## the panel is for.
func _check_alerts(sample: Dictionary) -> void:
	var total: int = sample["mem_total"]
	if total <= 0:
		return
	var free_ratio := float(sample["mem_available"]) / float(total)
	if free_ratio < _mem_tight and _may_alert(ALERT_MEM_TIGHT):
		_raise(ALERT_MEM_TIGHT, {"percent": free_ratio * 100.0})
		return

	var top_mem: Array = sample["top_mem"]
	if not top_mem.is_empty() and float(top_mem[0]["mem_ratio"]) >= _proc_mem_share \
			and _may_alert(ALERT_PROC_MEM):
		_raise(ALERT_PROC_MEM, {
			"name": str(top_mem[0]["name"]),
			"percent": float(top_mem[0]["mem_ratio"]) * 100.0,
		})
		return

	var top_cpu: Array = sample["top_cpu"]
	if float(sample["cpu"]) >= _cpu_busy and _may_alert(ALERT_CPU_BUSY):
		_raise(ALERT_CPU_BUSY, {
			"name": str(top_cpu[0]["name"]) if not top_cpu.is_empty() else "",
			"percent": float(sample["cpu"]),
		})


func _may_alert(kind: String) -> bool:
	var now := Time.get_unix_time_from_system()
	return now - float(_alerted_at.get(kind, -ALERT_COOLDOWN)) >= ALERT_COOLDOWN


func _raise(kind: String, detail: Dictionary) -> void:
	_alerted_at[kind] = Time.get_unix_time_from_system()
	EventBus.resource_alert.emit(kind, detail)


# --- Formatting shared with the panel -----------------------------------------

static func human_bytes(bytes: int) -> String:
	var mb := float(bytes) / 1048576.0
	if mb < 1024.0:
		return "%d MB" % roundi(mb)
	return "%.1f GB" % (mb / 1024.0)
