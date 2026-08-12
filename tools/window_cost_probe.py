#!/usr/bin/env python3
"""A non-Godot stand-in for the pet's window, for telling "this kind of window is
expensive" apart from "our engine's frames are expensive".

    tools/window_cost_probe.py [--opaque] [--no-top] [--fps N] [--seconds N]
                               [--size WxH] [--at X,Y] [--count]

Stop the pet, run this instead, and measure with tools/compositor_bench.py. It
makes the same window the pet does — ARGB, undecorated, always-on-top,
click-through, parked in the same corner — and repaints a pet-sized patch at the
same rate, with no game engine anywhere near it. --opaque and --no-top drop one
property each, which separates which one carries any cost found.

This is what settled the question once: three variants all cost nothing
measurable, while the Godot pet at the same 12 fps cost +3.4 s on the same
folder. Whatever the penalty is, it is not "a transparent always-on-top window
exists". See docs/desktop-compositor-cost.md.

**Check --count before trusting a null result.** A probe that silently is not
repainting also costs nothing, and looks exactly like a win. `--count` prints how
many times it actually painted, so the rate can be confirmed rather than assumed
— the reference run was 243 paints in 20 s against a requested 12.

X11 only, and needs python3-gi with GTK 3. GTK 4 dropped set_keep_above.
"""

import argparse
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402
import cairo  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--opaque", action="store_true", help="drop the RGBA visual")
ap.add_argument("--no-top", action="store_true", help="drop always-on-top")
ap.add_argument("--fps", type=float, default=12.0)
ap.add_argument("--seconds", type=float, default=300.0)
## WindowController.BASE_SIZE, and where mutter parks it on a 1920x1080 desktop.
ap.add_argument("--size", default="440x760")
ap.add_argument("--at", default="1480,320")
ap.add_argument("--count", action="store_true", help="report paints on exit")
args = ap.parse_args()

W, H = (int(v) for v in args.size.split("x"))
X, Y = (int(v) for v in args.at.split(","))
## Where the pet stands in its window: WindowController.ANCHOR_RATIO.
CX, CY, R = int(W * 0.5), int(H * 0.80), 75


class Probe(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("Window Cost Probe")
        self.frame = 0
        self.paints = 0
        self.set_app_paintable(True)
        if not args.opaque:
            visual = self.get_screen().get_rgba_visual()
            if visual is None:
                raise SystemExit("no RGBA visual — cannot mimic the pet")
            self.set_visual(visual)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        # Never steal focus: this stands in for a click-through desk pet.
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        if not args.no_top:
            self.set_keep_above(True)
        self.set_default_size(W, H)
        self.connect("draw", self.on_draw)
        self.connect("realize", self.on_realize)

    def on_realize(self, _w):
        # An empty input region: the same promise the pet's passthrough mask makes.
        self.get_window().input_shape_combine_region(cairo.Region(), 0, 0)

    def on_draw(self, _w, cr):
        self.paints += 1
        if args.opaque:
            cr.set_source_rgb(0.10, 0.10, 0.12)
        else:
            cr.set_operator(cairo.OPERATOR_SOURCE)
            cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        # A pet-sized patch whose pixels genuinely differ from frame to frame.
        phase = self.frame % 6
        cr.set_source_rgba(0.95, 0.55, 0.30, 0.95)
        cr.arc(CX, CY - phase * 2, R - phase * 3, 0, 6.2832)
        cr.fill()
        cr.set_source_rgba(1, 1, 1, 0.9)
        cr.arc(CX - 20, CY - 20 - phase * 2, 8, 0, 6.2832)
        cr.arc(CX + 20, CY - 20 - phase * 2, 8, 0, 6.2832)
        cr.fill()
        return False

    def tick(self):
        self.frame += 1
        self.queue_draw_area(CX - R - 10, CY - R - 20, 2 * R + 20, 2 * R + 40)
        return True


win = Probe()
win.show_all()
win.move(X, Y)
GLib.timeout_add(int(1000.0 / args.fps), win.tick)
GLib.timeout_add_seconds(int(args.seconds), Gtk.main_quit)
Gtk.main()
if args.count:
    print("painted %d times in %gs (requested %g fps)"
          % (win.paints, args.seconds, args.fps))
