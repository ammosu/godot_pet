#!/usr/bin/env python3
"""Time how long a folder takes to open, so the pet's cost to the rest of the
desktop can be measured rather than argued about.

    tools/compositor_bench.py <label> <runs> [folder]

Prints one line per run and a mean, and appends every run to
`compositor-bench.jsonl` in the working directory. `tools/compositor_ab.sh` is
the usual way in — it drives the pet's state around this.

Two numbers per run, both timed from the launch:

    視窗出現   a new visible X window titled after the folder appears
    完全載入   the last moment the window's own pixels changed

X11 only: it needs `xdotool` and `xwd`, and reads Nautilus. The frame-rate
findings it produced are documented in `docs/desktop-compositor-cost.md`.

Four things this has to get right, each of which cost a measurement round:

- **"Last change over a fixed window", not "first stretch of stability".** The
  list stops and restarts while loading. A stability test settles on the first
  lull — measured, it reported 1.14 s for a load still repainting most of the
  frame at 3.3 s. The fixed window has no such failure, and costs OBSERVE
  seconds per run.
- **The desktop must be idle.** This cannot tell "the list is still filling"
  from "someone moved the mouse". Measured with the machine in normal use, two
  of three runs changed for the entire observation window and produced nothing.
  With the desktop untouched, every run settles to two change events and the
  spread between runs nearly vanishes. 視窗出現 is far more tolerant, since it
  only covers about a second.
- **Quit Nautilus before every run**, so each is the same cold-process shape. A
  warm D-Bus open is a different measurement.
- **`xwd -id` reads the window's own backing pixmap** under a compositor, so the
  always-on-top pet cannot leak into the frames. Never grab the root window.
"""

import hashlib
import json
import os
import subprocess
import sys
import time

APPEAR_TIMEOUT = 30.0
## Content settled at ~3.3s on the reference machine; 20s is ample headroom.
OBSERVE = 20.0
SAMPLE = 0.25
## Blocks changed before it counts as more than a status line ticking over.
SUBSTANTIAL = 3
ROWS, COLS = 16, 8
RESULTS = "compositor-bench.jsonl"


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def visible_windows():
    return set(sh(["xdotool", "search", "--onlyvisible", "--name", "."]).split())


def quit_nautilus():
    subprocess.run(["nautilus", "-q"], capture_output=True)
    time.sleep(1.5)


def blocks(wid):
    """Hash the window in a grid, so a one-block tick can be told from a repaint."""
    r = subprocess.run(["xwd", "-id", wid, "-silent"], capture_output=True)
    if r.returncode != 0 or not r.stdout:
        return None
    data = r.stdout
    step = len(data) // (ROWS * COLS)
    return [hashlib.sha1(data[i * step:(i + 1) * step]).digest()
            for i in range(ROWS * COLS)]


def nautilus_cpu():
    pid = sh(["pgrep", "-x", "nautilus"]).split()
    if not pid:
        return None
    try:
        with open("/proc/%s/stat" % pid[0]) as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, IndexError, ValueError):
        return None


def measure(label, index, folder):
    name = os.path.basename(folder.rstrip("/"))
    quit_nautilus()
    before = visible_windows()
    t0 = time.time()
    subprocess.Popen(["nautilus", folder], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)

    wid = None
    while time.time() - t0 < APPEAR_TIMEOUT:
        for w in visible_windows() - before:
            if name in sh(["xdotool", "getwindowname", w]):
                wid = w
                break
        if wid:
            break
        time.sleep(0.05)

    if wid is None:
        print("[%s%d] 視窗未出現，逾時" % (label, index), flush=True)
        row = {"label": label, "run": index, "appear": None, "note": "視窗未出現"}
        record(row)
        return row

    appear = time.time() - t0
    prev, last_change, last_substantial, events = None, appear, appear, 0
    while time.time() - t0 < appear + OBSERVE:
        cur = blocks(wid)
        now = time.time() - t0
        if cur is None:
            time.sleep(SAMPLE)
            continue
        if prev is not None and len(prev) == len(cur):
            changed = sum(1 for a, b in zip(prev, cur) if a != b)
            if changed:
                events += 1
                last_change = now
                if changed >= SUBSTANTIAL:
                    last_substantial = now
        prev = cur
        time.sleep(SAMPLE)

    row = {"label": label, "run": index, "folder": folder, "appear": appear,
           "last_change": last_change, "last_substantial": last_substantial,
           "change_events": events, "nautilus_cpu": nautilus_cpu()}
    print("[%s%d] 視窗出現 %.2fs / 完全載入 %.2fs（%d 次變動）" % (
        label, index, appear, last_substantial, events), flush=True)
    if events > 12:
        print("       ！變動 %d 次，桌面大概不是靜止的 —— 這一輪的「完全載入」不可信"
              % events, flush=True)
    record(row)
    return row


def record(row):
    with open(RESULTS, "a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main():
    if len(sys.argv) < 3:
        print("usage: compositor_bench.py <label> <runs> [folder]", file=sys.stderr)
        raise SystemExit(2)
    label, runs = sys.argv[1], int(sys.argv[2])
    folder = sys.argv[3] if len(sys.argv) > 3 else \
        (sh(["xdg-user-dir", "DOWNLOAD"]) or "").strip() or os.path.expanduser("~")
    if not os.path.isdir(folder):
        print("no such folder: %s" % folder, file=sys.stderr)
        raise SystemExit(1)
    rows = [measure(label, i, folder) for i in range(1, runs + 1)]
    quit_nautilus()
    for key, title in (("appear", "視窗出現"), ("last_substantial", "完全載入")):
        vals = [r[key] for r in rows if r.get(key) is not None]
        if vals:
            print("%s %s 平均 %.2f 秒（%s）" % (
                label, title, sum(vals) / len(vals),
                " / ".join("%.2f" % v for v in vals)), flush=True)


main()
