#!/bin/sh
# What does the pet cost the rest of the desktop right now?
#
#   tools/compositor_ab.sh                 # pet as configured, vs no pet at all
#   tools/compositor_ab.sh 6 12 30 60      # ...and one pass per --max-fps value
#   FOLDER=~/somewhere tools/compositor_ab.sh
#
# Drives tools/compositor_bench.py around the pet's state and prints a table
# against the no-pet baseline. Every pass restarts the pet; the pet is left
# running on the ordinary launcher whatever happens.
#
# **Keep your hands off the machine while this runs.** The "完全載入" number
# cannot tell a filling list from a moving mouse — see the header of
# compositor_bench.py. A pass is about 75 seconds.
#
# **The pet must run at nice 0.** An agent shell is often niced and children
# inherit it, which an unprivileged renice cannot undo; a niced pet quietly
# under-reports its own cost, because loading a folder is exactly when the CPU is
# contended. systemd-run --user starts it from the user manager instead.
#
# Recorded baselines, and what they were measured on, are in
# docs/desktop-compositor-cost.md. Compare against a fresh no-pet run from this
# script rather than against those numbers: they are specific to one machine,
# one folder, and a warm thumbnail cache.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
launcher=${PET_LAUNCHER:-$HOME/.local/bin/godot-pet}
folder=${FOLDER:-$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME")}
runs=${RUNS:-3}
unit=godot-pet-bench

for tool in xdotool xwd nautilus systemd-run; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 127; }
done
[ -x "$launcher" ] || { echo "no launcher at $launcher" >&2; exit 1; }

godot_pids() { ps -eo pid,comm --no-headers | awk '$2=="godot"{print $1}'; }

stop_pet() {
	systemctl --user stop "$unit" 2>/dev/null || true
	for p in $(godot_pids); do kill "$p" 2>/dev/null || true; done
	sleep 3
}

# $1: extra godot arguments, may be empty. Echoes the pid.
start_pet() {
	if [ -z "$1" ]; then
		systemd-run --user --collect --unit="$unit" --setenv=DISPLAY="$DISPLAY" \
			"$launcher" >/dev/null 2>&1
	else
		systemd-run --user --collect --unit="$unit" --setenv=DISPLAY="$DISPLAY" \
			/bin/sh -c "exec \$HOME/.local/bin/godot --path $(dirname -- "$script_dir") $1 \
				> \$HOME/.local/state/godot_pet/run.log 2>&1" >/dev/null 2>&1
	fi
	sleep 9
	godot_pids | head -1
}

restore() {
	echo
	echo "=== 收尾：用一般 launcher 重啟寵物 ==="
	stop_pet
	start_pet "" >/dev/null
	godot_pids | head -1 | xargs -I{} ps -o pid,ni,args= -p {} --no-headers
}
trap restore EXIT INT TERM

cpu_of() {
	awk '{ n=split($0, f, ") "); split(f[n], g, " "); print (g[12]+g[13])/100 }' \
		"/proc/$1/stat" 2>/dev/null || echo 0
}

echo "資料夾：$folder（$(ls -1 "$folder" | wc -l) 項），每組 $runs 次"
echo "請在這段時間內完全不要碰滑鼠鍵盤。"

echo
echo "########## 基準線：寵物沒有執行 ##########"
stop_pet
python3 "$script_dir/compositor_bench.py" NOPET "$runs" "$folder"

pass() {  # $1 label, $2 godot args, $3 description
	echo
	echo "########## $1：$3 ##########"
	stop_pet
	pid=$(start_pet "$2")
	[ -n "$pid" ] || { echo "！！ 寵物沒有啟動，跳過"; return 0; }
	echo "pid $pid  nice $(ps -o ni= -p "$pid" | tr -d ' ')  $(ps -o args= -p "$pid" | sed 's|.*godot ||')"
	before=$(cpu_of "$pid"); t0=$(date +%s.%N)
	python3 "$script_dir/compositor_bench.py" "$1" "$runs" "$folder"
	after=$(cpu_of "$pid"); t1=$(date +%s.%N)
	echo "$after $before $t1 $t0" \
		| awk '{printf "%s 期間寵物自身 CPU：%.1f%%\n", "'"$1"'", ($1-$2)/($3-$4)*100}'
}

if [ "$#" -eq 0 ]; then
	pass PET "" "寵物依現有設定執行（FrameBudget 決定幀率）"
else
	for fps in "$@"; do
		pass "FPS$fps" "--max-fps $fps" "寵物固定在 $fps fps（蓋過 FrameBudget）"
	done
fi
