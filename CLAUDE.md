# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Godot 4.7 desktop pet for macOS: a transparent, always-on-top, click-through
window holding an animated character you can chat with via an LLM.

It is also a small assistant — not by being an agent itself, but by being the
face of one. You tell it what you want done, it hands the job to `claude` or
`codex` in a folder you have explicitly given it, and it reports back. The
character is the point: something you look at while thinking, that can also go
and do a thing.

`PLAN.md` is the living design document — phased milestones, decisions made and
why, plus the platform quirks discovered while building. Read it before starting
substantial work, and update it when a phase lands or a new quirk is found.

Code, comments and commit messages are English. User-facing strings, `PLAN.md`
and the prompt files are Traditional Chinese.

## Commands

```sh
godot --path .                       # run the app
godot --headless --import --path .   # import assets + parse all scripts
pkill -f "godot --path"              # stop a running instance

godot --headless --path . --export-release "macOS"   "build/Godot Pet.app"
godot --headless --path . --export-release "Windows" "build/windows/Godot Pet.exe"
godot --headless --path . --export-release "Linux"   "build/linux/GodotPet.x86_64"
```

Exporting needs the templates in
`~/Library/Application Support/Godot/export_templates/4.7.1.stable/` (see
PLAN.md Phase 10), and `rendering/textures/vram_compression/import_etc2_astc`
must stay enabled or arm64/universal builds are refused outright.
`export_presets.cfg` is committed — it carries the transparency and privacy
settings; Godot keeps signing secrets in `export_credentials.cfg`, which is not.

All three presets cross-export from any host, so the Windows and Linux builds are
produced on macOS and **have never been run**. Treat a clean export as evidence
of nothing beyond the packaging step. What actually needs a real machine is in
PLAN.md under "跨平台".

An exported build cannot see `res://.env`, so a machine that works from source
drops to the mock provider once packaged. The key has to be set through the
menu, which puts it in the credential store where both can reach it.

Always `--import` after editing scripts and grep the output for
`SCRIPT ERROR|Parse Error|Failed to load`. It is the only static check
available — but it does **not** catch everything. Some parse errors (for
example, a `while true:` whose every exit is a `return`, which GDScript's flow
analysis rejects) only surface when the script is first loaded at runtime, so
also check the run log.

**Two scripts declaring the same `class_name` produce no output at all** —
measured: a byte-copy of `tts/qwen3_voice.gd` left beside it, both saying
`class_name Qwen3Voice`, imported completely silently. Which one the global class
resolves to is then not something the import step will ever tell you, so a stray
copy in the tree can quietly become the one that runs. `git status` is the check
that catches this, not `--import`.

There is no test suite. Verification is empirical:

```sh
(godot --path . > /tmp/run.log 2>&1 &) ; sleep 4; grep -v TSM /tmp/run.log
screencapture -x -t png -R <x>,<y>,<w>,<h> shot.png   # then Read the png
```

`-R` coordinates are **logical points** (half of physical pixels on Retina); the
resulting PNG is at physical resolution. The pet parks in the bottom-right of
the primary screen.

Runtime data lives outside the repo, at
`~/Library/Application Support/Godot/app_userdata/Godot Pet/`:
`config.cfg` (settings, provider choice, per-pet row overrides) and
`state.json` (needs). Deleting either resets that half of the app. When testing
time-dependent behaviour, edit `state.json`'s `saved_at` to backdate it rather
than waiting.

## Architecture

Systems talk through `EventBus` signals (`autoload/event_bus.gd`) rather than
holding references to each other, so the brain, the visuals, the window and the
LLM can each be replaced alone. `pet/pet.gd` is the composition root: it turns
raw input into EventBus signals and wires the pieces together, and deliberately
holds no behaviour itself.

- `pet/window_controller.gd` — the only thing that touches `get_window()`.
- `pet/pet_brain.gd` — movement/activity FSM. Emits logical state names
  (`idle`, `walk`, `sleep`, …), never animation indices.
- `pet/pet_visual.gd` — plays logical states, hiding whether a sprite pack is
  loaded or the procedural fallback (`pet/fallback_blob.gd`) is in use.
- `pets/pet_pack.gd` — spritesheet loader (see below).
- `autoload/llm_service.gd` — conversation orchestration and the emotion-tag
  parser; `llm/llm_provider.gd` is the backend interface.
- `autoload/pet_state.gd` — needs; `autoload/nudger.gd` — unprompted lines;
  `autoload/presence_service.gd` — which app you're in, which is what decides
  when one of those lines is worth saying;
  `autoload/monitor_service.gd` — what the *machine* is doing, on the same
  twenty-minute rhythm.
- `autoload/file_drop_service.gd` — turns a file dropped on the pet into a turn;
  a dropped *folder* is a workspace offer instead, handled in `pet.gd`.
- `autoload/outbox_service.gd` — the one folder the pet may write to, which now
  only the transcript export fills.
- `autoload/workspace_service.gd` — the folders the pet may work in, and the git
  questions about them; `autoload/work_service.gd` — the coding-agent CLI run;
  `autoload/codex_cli.gd` — where that CLI is and whether it has an account.
- `ui/style.gd` (`PetStyle`) — every colour and edge, and the builders for the
  themes. See below.
- `ui/chat_panel.gd` — speech bubble and chat input;
  `ui/memory_panel.gd` — the window listing what the pet remembers;
  `ui/chat_log_panel.gd` — the window listing what was actually said;
  `ui/outbox_panel.gd` — the window listing what the pet has made;
  `ui/work_panel.gd` — the workspaces, and what the pet is doing in one now;
  `ui/monitor_panel.gd` — what is running on this machine and what it costs;
  `ui/game_panel.gd` + `ui/games/` — the mini-game window and the games in it.

### The right-click menu is grouped by kind, and one group is allowed to grow

Five setting submenus, then the verbs (餵食 / 遊戲 / 看螢幕 / 幫我做事 / 錄音 /
回到角落), then one 查看 submenu holding every window, then 結束.

**說話 is the fifth.** It sits next to 語言模型 because they are the same question
asked twice — which model thinks, and which one speaks — and it took the 說話出聲
row *out* of 行為, where the one row naming a resource never fitted among rows
describing what the pet does. Speech stopped being one switch: there is now a
backend, a voice and an on/off, and three questions is what a submenu is for.

It does grow the root menu by one row, and the cost is measured like every other
entry here: **15 rows, 426px** on the 1080p desktop, against 392px at 14 and the
476px at 17 that forced Godot to shove the flat menu upward. The row it removed
came out of 行為, not out of the root — that is a claim this file made before
anyone measured it, and it was wrong.

The second fold happened because the first one stopped being enough. Measured
flat at seventeen rows: **476px on a 1080p desktop, which Godot had to shove
upward to fit on screen at all**, and about 595px at 125%. Five of those rows
were the same shape as each other — a window listing something the pet holds —
so they went behind one door, taking the menu to 13 rows and 364px.

Which group moves is not arbitrary. **The panels are the group that grows**:
every feature since the transcript has added one. The verbs don't — there are
only so many things to ask a pet to do — so they stay one click away, which is
what the menu is for. A sixth panel now costs nothing; a sixth verb would be the
signal to think again.

Two judgements worth not re-litigating:

- **`工作…` and `電腦狀況…` went in with the rest**, even though they are the two
  that show something happening *now* and burying them costs a click at exactly
  the wrong moment. The pet already says 還在弄 on its own while a job runs, so
  the menu is not how you learn it is still alive — and a group with an exception
  in it has no honest name.
- **Submenus carry no `…`.** In this menu the ellipsis means "opens something
  further", which a submenu's arrow already says; `查看` is the door, and the
  five rows behind it keep their ellipses because they open real windows.

### PetStyle

Two surfaces, deliberately opposed: what the *pet* says is paper (warm, light,
soft-cornered, with a tail), and what the *app* asks is ink (a dark slab that
reads as system chrome, so a menu never looks like the character talking). One
persimmon accent is the only saturated colour in either.

The dark chrome is not only a taste call. `PopupMenu`'s check and radio marks
come from the engine's default theme and are near-white; on a light panel they
disappear, and there is no per-item icon modulate to fix that with.

Two Godot specifics worth knowing before editing it:

- A `StyleBoxFlat`'s shadow is a **solid expanded copy of its own shape drawn
  behind it**, including behind the part the box covers — there is no blur. A
  box with a see-through fill therefore doesn't glow, it takes on the shadow's
  colour. The input's focus style repeats the fill opaquely for this reason.
- Missing theme items fall through to the engine default, so a theme built by
  duplicating `ui/theme.tres` keeps the CJK font and inherits the stock icons.

### Coordinates and DPI

**Viewport pixels are 1:1 with window pixels, and this must stay true.**
`DisplayServer.window_set_mouse_passthrough()` takes window pixels, and
`Window.size` / `screen_get_usable_rect()` / `screen_get_position()` are all
*physical* pixels (a 2940-wide Retina screen reports 2940).

So the window is sized as `BASE_SIZE * WindowController.display_scale()` and the
visual node is scaled to match. Do **not** introduce `Window.content_scale_factor`
or `content_scale_mode`: they decouple viewport coordinates from window pixels
and silently misplace the click-through mask.

`display_scale()` cannot just call `screen_get_scale()` — **that one is
implemented on macOS only**, and returns 1.0 everywhere else no matter what the
desktop is set to. On a 125% Windows display it left the pet and the right-click
menu drawn at design size: correct in pixels, visibly too small. Windows and
Linux report a DPI instead, so the fallback is `screen_get_dpi() / 96`. The
result is not rounded to an integer — 125% means 125%.

Anything measured in design units gets multiplied by
`WindowController.get_ui_scale()` at the point of use. That includes UI theme
constants — popups and controls are laid out in physical pixels, so the default
theme renders undersized unless its font sizes and spacings are scaled too (see
`PetStyle`, below).

Two traps this keeps springing:

- A stylebox's **content margins set the control's minimum size**, so padding a
  field evenly overrides the height its layout code asked for. The chat input's
  vertical padding is deliberately a third of its horizontal one.
- Anything built in a node's `_ready()` is built before the scale is known.
  `MemoryPanel` therefore constructs itself on first open, not on load.

### The window deliberately hangs off the screen

The window is far larger than the pet and is allowed to overhang the desktop
edge so the pet itself can reach the corner.

Its size is what limits the speech bubble, not the screen: the bubble grows
upward from the pet's head and is clipped by the window, so a window sized close
to the pet makes long replies scroll away while most of the display sits empty.
The extra area is transparent and click-through, costing only fill rate.

Note "allowed to" — see the next section, because GNOME isn't.

Three consequences of overhanging:

- Screen-edge clamping uses `set_content_bounds()` — the *visible pet* — not the
  window rect. This is kept separate from `set_hit_region()`, which grows to
  cover chat UI and would otherwise drag the pet away from the edge.
- Chat UI must be clamped to `WindowController.get_visible_area()`, the slice of
  the window actually on screen. Clamping position alone is not enough: the
  speech bubble also narrows when that slice is thinner than its natural width.
- `get_visible_area()` changes as the pet walks, so `EventBus.pet_moved` must be
  connected **before** `park_at_default_spot()` runs in `_ready()`.
- Because that slice moves the bubble and the input *within* the window,
  `_on_pet_moved` has to re-push the mask as well as re-clamp the layout. It
  didn't, and the symptom was a bubble or input with one side sliced off,
  seemingly at random — the mask still described where the UI used to be. The
  reliable repro is dragging the pet with the input open: a drag also knocks the
  brain out of `TALK`, so the pet then walks off with the field still up.

### GNOME won't let it hang off, so the pet moves inside the window

Mutter, on X11, forces the whole window inside `_NET_WORKAREA`. Measured on a
1920x1080 desktop whose work area is `66, 32, 1854, 1048`: a 440x760 window asked
to sit at `(1700, 600)` lands at `(1480, 320)`, and one asked for `(-300, -400)`
lands at `(66, 32)` — both work-area corners exactly. Godot reports the requested
value for a frame or two before the WM's `ConfigureNotify` overwrites it, so a
readback taken immediately looks like it worked.

That defeats the overhang outright. With the pet anchored 220px inside a 440-wide
window, it stopped 220px short of the screen edge and no clamping on our side
could move it further — the symptom being a pet that can be dragged, but not into
the corner. Neither obvious escape works: `FLAG_POPUP` (override-redirect, which
would leave the WM out of it) is refused by Godot for the main window — *"Main
window can't be popup"* — and making the window **larger** than the work area is
worse, not better: mutter then pins it at `(66, 32)`, completely immovable.

So `ANCHOR_RATIO` is only a default now, and `_anchor` is a variable: the window
goes as far as it is allowed, and the pet covers the rest of the distance by
moving *within* the window. Points worth keeping in mind:

- Whether the WM does this is **measured, not assumed** — macOS and the lighter
  X11 window managers place the window where they are told, and hard-coding the
  restriction by platform would needlessly forfeit the overhang on those.
  `park_at_default_spot()` already asks for an overhanging position, so
  `_probe_wm()` reads the answer off that and costs no extra movement. A request
  that was inside the work area anyway proves nothing and is ignored.
- Where the window *is* free to move, `_clamp_anchor()` provably returns the
  default: the window stops travelling exactly when the pet reaches the desktop
  edge. macOS behaviour is unchanged by any of this.
- `set_content_bounds()` takes the silhouette **relative to the pet**, not in
  viewport pixels. An absolute rect goes stale the moment the anchor moves.
- `_on_pet_moved` has to re-run `_layout_visual()` and re-place the silhouette,
  since the pet can now move without the window moving. It compares the anchor
  first, so an ordinary walk step still costs what it did.

### The passthrough mask clips rendering on Windows

`window_set_mouse_passthrough()` shapes input alone on macOS and Linux, but
Windows implements it with `SetWindowRgn()`, which sets the window region
outright — **anything outside the mask is not drawn**. A mask tight to the pet
therefore erases the speech bubble, with no error and nothing in the log: the
pet simply talks in silence.

So `_refresh_mask()` in `pet/pet.gd` widens the mask to
`ChatPanel.get_chrome_rect()` — everything the panel draws, tail and drop shadow
included — but only where `WindowController.passthrough_clips_rendering()` is
true. Elsewhere it keeps using `get_input_rect()`, because there the bubble is
display-only and a wider mask would needlessly eat clicks meant for the desktop.

The two consequences:

- The mask has to track the bubble as it grows and moves, so `_refresh_mask()`
  is split from `_refresh_hit_region()` and driven from `_process`. The rest of
  that function restyles the bubble and relays out the input, and must **not**
  run every frame.
- `set_hit_region()` drops a region identical to the current one. `SetWindowRgn`
  forces a redraw on every call, and the brain enters `TALK` while a bubble is
  up, so the pet stands still and the region is usually unchanged.

### Sprite packs

Art is the Codex Pets / petdex format: `pet.json` plus 8 columns of 192x208
cells, one animation state per row. The project-owned default pack is loaded
from `res://pets/default`; community packs are loaded at runtime from
`~/.codex/pets/{id}/` (installed by `npx codex-pets add <id>`).

Only the original built-in default artwork ships in this repo. Community packs
do not — originals default to CC BY-NC-SA and fan works of third-party
characters are personal, non-commercial use only. Reading those packs from the
user's own install keeps licensing between them and the pet's author.

The manifest declares neither the grid, nor frame counts, nor row semantics:

- **The row count is measured, never assumed.** The format grew: original sheets
  are 9 rows, `spriteVersionNumber: 2` packs are 11, and nothing in `pet.json`
  says which. `_cell_size_for()` derives the cell from the width and the 192:208
  ratio, then divides the height by it. A hard-coded 9 made the divisibility
  check reject every v2 pack outright — with the pet silently falling back to the
  procedural blob, which reads as "the download didn't work".
- Frame counts are detected by scanning each row for its first blank cell.
- V2 rows use the current Codex contract in `PetVisual.V2_STATE_ROWS`, including
  distinct right/left locomotion and the task/review rows. Legacy row meanings
  remain a built-in guess in `DEFAULT_STATE_ROWS`, overridable per pet via a
  `[pet_rows]` section in `config.cfg`. The right-click menu has a calibration
  mode that cycles rows with their index on screen.
- V2 rows 9-10 are the 16 clockwise look directions. At idle, `PetVisual`
  quantises the cursor angle to 22.5-degree steps, shows the matching frame
  without mirroring it, and returns to the idle loop inside the pointer
  deadzone or outside the notice radius.
- Anything positioning the pet against a screen edge, or sizing its click box,
  must measure the **idle row** (`rect_for_row`), not the whole-sheet union —
  action frames fling limbs and props far outside the resting silhouette.
- **How much of the cell the character fills is not a constant**, so drawing
  every pack at one shared scale makes some pets visibly bigger than others. Of
  four packs to hand the idle silhouette ran 76% of the cell height (`cute-rem`,
  118x159) to 95% (`yoshi`, 136x198). `PetVisual.get_pack_scale()` corrects each
  pack to `NOMINAL_HEIGHT_RATIO` of its cell and the user's size choice
  multiplies that. Height, not width or area — these characters stand on the
  ground, so height is what reads as size, and a genuinely wide one
  (`pikachu-local`, 182x180) should look wide rather than be shrunk to fit. The
  correction is clamped, since a mis-detected idle row would otherwise scale the
  pet by whatever a blank or prop-only row happens to measure.

### The app icon is cut from the selected pack

`pet/app_icon.gd` makes the app's icon out of whoever is on the desktop, driven
from the one place that already knows a pack changed — `pet.gd::_apply_pack()`.
It takes the **resolved** idle row from `PetVisual.state_rows()`, for the same
reason the mini-game does: an icon cut from a raw row guess is a pet mid-pounce
or a bare prop. Frame 0's own bounding box, not `rect_for_row`'s union over the
row — that union has to cover a whole walk cycle, and this only ever shows one
pose. `smooth_filter` decides the resample, so the icon can never disagree with
the sprite about whether it is pixel art.

It writes two things, because no single mechanism covers all three platforms:
`DisplayServer.set_icon()` for the live window property, and a PNG at
`user://app_icon.png` for anything that reads an icon off disk. Derived art goes
to `user://`, never into the repo — the licensing note in `make_app_icon.sh`
applies unchanged. That script is **not** redundant: a macOS Dock icon is read
from the `.app` bundle and no running process can change it, so it stays
post-export surgery.

#### Setting the window icon is not enough on GNOME

**Mutter no longer reads `_NET_WM_ICON`.** Measured on GNOME Shell 46 / mutter 46
(Ubuntu 24.04): `set_icon()` puts the property on the window, `xprop` reads it
back correctly, and the dash still draws Yaru's `application-x-executable` cog —
a window matching no desktop entry becomes a *window-backed app*, and GNOME has
nothing to show for it. The property is still worth setting, since Windows and
the lighter X11 window managers do use it, but on GNOME it is inert.

What works there is being matched to a desktop entry, by `StartupWMClass`.
`tools/install_linux_desktop_entry.sh` writes one, pointing `Icon=` at the PNG
above — so the entry is installed once and the icon then follows the selected pet
by itself. Three things it has to get right:

- **`StartupWMClass` is read out of `project.godot`, not written down.** The
  window's WM_CLASS class comes from `application/config/name`, and a copy here
  would stop matching the day that setting is edited. The failure is silent: the
  cog simply comes back.
- GNOME matches a window to an entry **once**, so a pet that was already running
  has to be restarted before the icon appears.
- The entry goes in `~/.local/share/applications`. The app writes neither it nor
  the autostart entry in `~/.config/autostart` — those are the user's, not
  something a pet edits, which is why this is a script you run rather than
  something startup does.

This was originally documented here as "the icon is a live window property, so
Linux is covered". It was not: what had been verified was that the property was
set, never that anything drew it. Worth remembering as the shape of the mistake —
measuring the mechanism instead of the observable.

**`DisplayServer.set_icon()` silently does nothing above a certain size on X11**,
and it is the icon that is too big, not the image. No error, nothing in the log;
`_NET_WM_ICON` just stays empty, which reads as the call having been forgotten
rather than refused. Measured on Xvfb with Godot 4.7.1: 64, 96, 128, 192 and 224
square all set the property, while 254, 255 and 256 all leave it empty. The cliff
is somewhere in between and **its cause was not established** — the obvious
candidate, the X protocol's 65535-unit request length, puts the limit at
`2 + 254*254 = 64518` elements, which is under it and still fails. So `WM_SIZE`
is 128, which is what a taskbar or alt-tab switcher actually draws anyway.

Two traps for anyone verifying this:

- **`xprop` renders a large icon as `Icon (N x N): (not shown)`** instead of
  dumping the numbers, so a byte count of its output is not a measure of whether
  the property is set — 64x64 dumps ~86k of text and 128x128 prints 58 bytes,
  and both worked. Grep for `Icon (`, and treat a bare `_NET_WM_ICON(CARDINAL) =`
  as the only genuine failure.
- The PNG is a **file**, subject to none of this, so it is written at 256 —
  which is just as well, since on GNOME it is the one of the two that gets drawn.

### Every pose channel goes through `_apply_pose()`

Five separate things move or select the sprite now: which way it faces, the v2
look direction, the lean and perk it does when the cursor comes near, the squash
of being held or tapped, and the lean of a body still catching up with the grab
point. They used to be written
straight to `_sprite.flip_h` / `offset` / `scale` by whichever setter ran last,
which meant the last caller silently erased the others — `set_facing()` rewrote
the offset the cursor lean had just put there.

`PetVisual._apply_pose()` is the single write point and it *adds* the channels.
A new one is a new variable plus a term in that function, never another
`_sprite.offset = …` somewhere else.

- It writes scale and offset only, **never rotation**, on either the sprite or
  this node. `pet.gd::_refresh_hit_region()` measures the hit polygon as
  `p * _visual.scale`, which cannot see a rotation — and it only re-runs on
  discrete triggers (pack switch, size change, anchor change), never per frame,
  so a continuously-varying rotation would go unmeasured even if that formula
  learned to read one.
- `play_state()` calls it on the transition frame rather than leaving it to the
  next `_process()`, closing a callback-order race: `PetBrain` can emit
  `facing_changed` one line before `state_changed`.
- The cursor reaction is gated on `_state == &"idle"` **and a zero squash**. The
  state alone is not enough: no pack has a drag animation, so `_resolve_row()`
  sends `drag` and `settle` back to the idle row, and the squash channel —
  nonzero right through grab, drag and release — is the only thing that tells a
  held pet from a resting one.
- Which is why the squash channel has exactly one owner. Both the tap bounce and
  the release landing are tweens on it, and `_stop_squash_tween()` kills the live
  one first. The landing runs a third of a second, and re-grabbing inside that
  window left the old tween easing the squash back to zero underneath the new
  grab — un-squashing a pet that was being held, and re-arming the cursor
  reaction mid-drag.

### A dragged pet lags, and the settle has to end even when it can't arrive

Dragging no longer teleports the window onto the cursor. `pet.gd` feeds
`PetBrain.set_drag_target()`, and `_step_drag()` — run every frame in `Mode.DRAG`
— moves the window towards it exponentially, so the body trails the grab point.
The gap it hasn't closed doubles as the lean signal (`drag_lean_changed`), so
there is no separate velocity to track and the lean decays to nothing by itself.

Release enters `Mode.SETTLE`, which shares `_step_drag()`: the body keeps falling
towards the last grab point after the mouse has gone. It has no animation row of
its own and doesn't need one — `_resolve_row()` already falls back to idle, the
same way `drag` always has.

The trap is how SETTLE ends. **It cannot test distance alone.** The drop point is
a raw cursor-derived position and the pet is frequently not allowed to occupy it:
let go in the bottom-right corner — where the pet lives by default — with the
cursor past the screen edge, and `set_pet_screen_position()` clamps every step,
so the gap never closes. The brain then stayed out of `IDLE` for the rest of the
run (no walking, no sleeping, no waking), the lean froze part-way, and
`pet_moved` fired every single frame, each one re-laying-out the chat UI and
re-pushing the mask. So `_step_drag()` returns where the pet *actually* ended up,
and SETTLE finishes on arrival **or** on that having stopped changing.

Three more things that look optional and are not:

- `_step_drag()` skips the window write when the rounded position is unchanged.
  Unlike a walk step this runs every frame, and every move emits `pet_moved`; a
  pet held still must not cost a mask rebuild per frame.
- `_enter(Mode.TALK)` emits `drag_lean_changed(0.0)`. `on_talk_started()` only
  refuses to interrupt an active `DRAG`, so TALK can be entered straight out of
  SETTLE — and then nothing is left ticking the lean down, so a chat opened as
  the pet lands freezes it mid-fall.
- `_finish_settle()` takes the new home from the window, not from `_drag_target`:
  a `_home_x` off the walkable strip makes `_wander_bounds()` give up and hand
  back the whole screen. `on_released()` still sets a provisional one from the
  raw target, which only has to cover a chat opening before the settle ends.

### LLM layer

Providers extend `LLMProvider` and are swapped through `LLMService`. `mock`
streams canned replies for building UI offline; `openai` streams for real.

Streaming uses `HTTPClient` polled from `_process`, not `HTTPRequest` (which
only yields the whole body at once) and not a thread (polling never blocks). SSE
events are split on **raw bytes**, because a chunk boundary can land mid-UTF-8
character.

Replies open with a mood tag like `[happy]` which selects the animation played
while talking. It is an inline tag rather than tool use: no extra round-trip,
and the mood is known from the first few tokens. The parser holds text back
until the tag resolves, since `[happy]` can arrive split across chunks and half
a tag must never flash up in the bubble. Tags are stripped before the text
reaches the bubble and before it enters the history.

**Startup defaults must never be written back to config.** `set_provider()`
does not persist; only `select_provider()` does. Persisting a default pins
whichever one applied on first run and permanently defeats later auto-detection.

The 語言模型 submenu picks the model as well as the backend.
`OpenAIProvider.MODELS` is the list; ids were read off `/v1/models` rather than
written from memory, because the family is not guessable. A model carries a note
in the menu only where the caveat is *measured*, which is why `gpt-5.4-nano` says
「看不懂螢幕」 and the rest say nothing — see the `[look]` measurements below.
Listing nano at all is deliberate: it is the cheapest way to chat, and someone
who never asks about the screen should be able to choose it knowingly.
`select_model()` persists (it is a choice, not a default), and the provider
re-reads the config on every request, so there is nothing to restart.

### Secrets

`Config.get_secret()` looks in the process environment, then the OS credential
store (`secrets/secret_store.gd`), then `.env` beside the project or executable,
then `config.cfg`. Anything the user types in goes to the credential store —
`security` on macOS, `secret-tool` on Linux, DPAPI through `powershell` on
Windows, and plaintext config elsewhere, with `set_secret()` returning false so
the UI can say so.

Secrets are passed over stdin via `OS.execute_with_pipe()` where possible, since
`ps` exposes argv to anything running as the same user — and
`Win32_Process.CommandLine` does the same on Windows. On macOS that means
`security add-generic-password -U -w` with the value piped twice, because `-w`
with no argument prompts and asks for confirmation.

`read()` is cached per process. It runs on **every** LLM request
(`OpenAIProvider.send()`), and where `security` costs milliseconds a PowerShell
start costs most of a second on the main thread, which would stall the pet
before every reply. The cache is dropped by `write()` and `erase()`, so the only
thing it can go stale against is an edit made outside the app.

The catch, and the reason `_read_uncached()` exists: `write()` verifies itself by
reading back, and a cached answer there would turn that check into a no-op —
silently disarming the truncation guard below.

### Windows has no usable credential-store CLI

`cmdkey` writes to Credential Manager but **cannot read a password back**, and
reaching `CredRead` from PowerShell means `Add-Type`-compiling C# at runtime:
seconds on first call, and blocked outright under constrained language mode.

So Windows uses **DPAPI** instead — `ConvertFrom-SecureString`, built in since
PowerShell 2.0 — with the ciphertext in `user://secrets/<KEY>.dpapi`. Protection
is equivalent to Credential Manager either way: both are scoped to the Windows
account, and both are readable by anything already running as that user. A blob
copied to another machine or account simply fails to decrypt, which `read()`
reports as "no key".

Two shapes this forces:

- The write hands the key to PowerShell on **stdin** and has PowerShell write the
  ciphertext file itself; the read passes only a **path** in argv and takes the
  plaintext off stdout. Both use the APIs the other two backends already rely on
  — no bidirectional pipe, and the plaintext is never in argv or on disk.
- PowerShell reads **one line** rather than to EOF, because closing the pipe is
  what would end the process, and the ciphertext still has to be written after
  that.

Scripts are built with PowerShell **single quotes** (`_ps_literal` doubles any
quote inside), so a Windows path's backslashes stay literal, and the script goes
across as a single argv entry that never reaches a shell.

**Every write is read back before being reported as successful.** macOS
`security` truncates a prompt-read password at 128 characters, exits 0 and says
nothing — and an OpenAI project key is 164. When the readback doesn't match, the
write is redone through argv, which has no such limit. A key briefly visible to
`ps` is a far smaller problem than one silently cut in half, which surfaces
later as an authentication failure with no clue as to why.

Stored values must be ASCII. `security find-generic-password -w` prints a
non-ASCII password as an unmarked hex dump, and a literal `deadbeef` comes back
as `deadbeef`, so hex output can't be distinguished from a real value on read.
`SecretStore.write()` refuses non-ASCII rather than guessing.

There is no OAuth path. OpenAI's "Sign in with ChatGPT" for third-party apps was
announced in 2025 but still ships only inside Codex tooling; the workarounds in
circulation impersonate the Codex CLI's OAuth client to spend ChatGPT
subscription entitlement, which this project does not do.

### Memory

`autoload/memory_store.gd` owns the conversation history outright — LLMService
asks it for the messages to send rather than keeping a copy, because a second
copy alongside the persisted one is how the two drift apart. Three layers, all
in `user://memory.json`: recent turns verbatim, older turns folded into a
summary, and durable facts about the user.

Folding costs an API call, so it runs in batches once enough messages have aged
out of the verbatim window, and goes through
`LLMService.request_background()` — a **second provider instance** whose signals
are not wired to EventBus, so a summary chunk has no path to the speech bubble
or the TTS queue. It returns false when the active backend can't do the work
(mock, or no key), and the store then only discards history once it is genuinely
unwieldy.

What it holds is shown in `ui/memory_panel.gd`, reached from one menu entry, and
each line can be dropped on its own. It used to be a menu item that emptied the
whole list into the speech bubble, which was the wrong shape twice over: the
bubble fades on a timer, so the answer timed out while being read, and a list you
can only read is a list you can only wipe.

`ui/chat_log_panel.gd` shows the verbatim layer the same way, for the same
reason: the bubble is the pet *talking*, so it holds one line at a time and is
gone in at most twenty-two seconds. Both windows read the store rather than
keeping a copy, and both are real OS windows — subwindow embedding is off
project-wide. A useful side effect: neither touches the pet window's passthrough
mask, so the Windows "the mask clips rendering" rule below doesn't reach them.

The transcript's bubbles are `RichTextLabel`, not `Label`, for one reason:
**Godot's `Label` has no text selection at all**, and a transcript you cannot copy
a line out of is only half a transcript. Four things that swap forces, none of
which announce themselves when wrong:

- **BBCode stays off.** These strings are whatever the user typed and whatever the
  model wrote, and a dropped file's contents arrive here too. With parsing on a
  stray `[b]` silently restyles the rest of the message and an unclosed one can
  eat it. Verified with a real 「[ERROR] Traceback…」 turn, which renders literally.
- **The theme item names differ from `Label`'s** — `default_color` not
  `font_color`, `normal_font_size` not `font_size`, `line_separation` not
  `line_spacing` — and a wrong override name is *silent*: it simply never
  applies. These match `ChatPanel`'s bubble exactly, which is the working
  reference.
- `_measure()` looks up `"normal_font"`, not `"font"`. A `RichTextLabel` has no
  theme font by the latter name, so the old lookup would return null, take the
  early return, and hand back the full limit — making every bubble as wide as the
  panel allows and losing the only thing that says who spoke.
- `fit_content = true` with `scroll_active = false`, because it lives inside a
  `ScrollContainer`; left alone, every bubble becomes its own little scrolling
  box.

Copying works two ways. `context_menu_enabled` gives the right-click 複製, which
needs no focus at all. Ctrl+C needs focus, which `RichTextLabel` already takes —
but its default is `FOCUS_ALL`, making every bubble a tab stop so Tab walks the
transcript one message at a time; `FOCUS_CLICK` keeps the shortcut and drops the
navigation. Selection cannot cross bubbles, since each is its own control, so
whole-transcript copying stays 存成檔案's job.

Measured on the isolated display: dragging selects across wrapped lines, the
highlight is legible on **both** bubble styles (light paper and the dark
persimmon one), and Ctrl+C followed by Ctrl+V into the pet's own chat input
returns exactly the highlighted span.

Clearing the transcript drops the verbatim turns and **keeps the summary and the
facts** — forget what we were just talking about, not who you are. Wiping both is
still 全部忘掉, one window along. Two things this forces:

- `_epoch` is bumped by every clear and checked in `_on_condensed()`. A fold can
  be in flight when the user clears, and letting it land would write the turns
  they just dropped into the one layer that persists — the single outcome
  clearing has to rule out.
- The pet's line acknowledging a clear must **not** be recorded
  (`pet.gd::_on_pet_nudged()` takes `record`). Otherwise the freshly emptied
  history contains exactly one message, saying it was emptied, and the count
  sits at 1 as if the clear half worked.

The fact-extraction prompt has to explicitly exclude speculation and
soon-stale details, or facts fill up with "probably still has concurrency risk"
and "had four meetings today".

### The mini-games

One window, three games. `ui/game_panel.gd` is the window — score, record,
difficulty, banner — and `ui/games/mini_game.gd` is what every game is, so the
panel never knows which one it has. Another real OS window, for the same three
reasons the memory and transcript panels are, including the useful one: nothing
in it touches the passthrough mask.

- `catch_game.gd` (接東西) — where, continuously. Steer the pet into what falls.
- `jump_game.gd` (跳過去) — when, once. One button, no double jump.
- `memory_game.gd` (翻翻看) — what you remember. The only one that ends by being
  *finished* rather than by running out of lives, so `uses_lives()` is false and
  its score is a count of how few mistakes you made.

Three verbs on purpose. Three reflex games would be one game with three coats of
paint, and a desk pet is something you look at while thinking.

`GamePanel.GAMES` is the whole registry — id, label, script. Ids key the saved
record and difficulty (`[game] best_<id>_<level>`), so they must not change once
anyone has a score. `pet.gd` builds the 遊戲 submenu straight off it with ids at
`GAME_BASE`, so a fourth game touches no code there. Note that every base test in
`_on_menu_pressed` is "at or above", so `GAME_BASE` (400) must be checked before
`PROVIDER_BASE` (300).

Shared parts worth knowing before adding a fourth game:

- `ui/games/game_pet.gd` draws the pet, and it takes `PetVisual.state_rows()` —
  the **resolved** state→row map, not the pack. The per-pet `[pet_rows]`
  corrections and the fallback for a state a pack has no art for are exactly the
  two things a game would otherwise get wrong, and getting them wrong means the
  pet grinning as it drops something. Sizing follows PetVisual's rule too:
  measure the idle row's character height, never the cell.
- `ui/games/game_art.gd` draws everything that isn't the pet. Every shape is
  **background-independent** — the donut is a `draw_arc` ring rather than a
  filled circle with a hole punched in the field colour, because the same shape
  is drawn on the dark field in one game and on a paper card in another.
- Games are built once and kept (`GamePanel._swap_field`), so reopening one does
  not rebuild its sprite from the pack.

Four things that look like taste and are not:

- **Every button in that window must be `FOCUS_NONE`.** A focused `Button` eats
  the arrows as focus navigation, and the arrows are how two of the three games
  are played — clicking a difficulty once and then being unable to move is the
  symptom. Held keys are polled (`MiniGame._held_axis`) rather than event-driven,
  and gated on `Window.has_focus()`: a key held as focus leaves never sends its
  release, and without the guard the arrow keys in whatever app you switched to
  would still be steering a game you can't see.
- **The only red anywhere in these games is the thing you must not touch.** Food
  needs several saturated colours at once, which contradicts PetStyle's
  one-accent rule, so this surface swaps in a different rule rather than
  abandoning the idea. Mistaking the good thing for the bad thing is the one
  failure a catch game cannot have.
- Catching food raises `fullness`, capped hard (`PetState.PLAY_FULLNESS_CAP`) at
  well under one feed. Uncapped, "play until it isn't hungry" quietly replaces
  餵食 with a worse loop than either. The other two games pass `treats = 0`, so
  only 接東西 feeds at all.
- The line the pet says afterwards comes from `pet.gd`, not the panel. The
  window knows the score and the record; only the composition root knows how the
  pet reacts to anything.

Two Godot specifics:

- A `CenterContainer` and an autowrapping `Label` collapse into each other — the
  container takes its width from the content, and an autowrapping label insists
  on none. Every banner hint line is broken by hand for this reason.
- A `class_name` is **not a constant expression**, so the registry preloads
  scripts by path. Putting `CatchGame` in that const array is a parse error that
  takes `pet.gd` down with it.

### Speech

`autoload/tts_service.gd` owns the sentence splitting and the EventBus wiring;
*which* voice does the speaking is a backend in `tts/`, swapped the way
`LLMService` swaps providers. `tts/os_voice.gd` is the OS voices
(`DisplayServer.tts_speak()` — no API, no cost, nothing to install), and
`tts/qwen3_voice.gd` is a local neural model. Sentences are spoken as they stream
in rather than after the reply completes.

That split is also what makes the neural backend possible at all: the engine has
no streaming, so an utterance is only as fast as it is short, and a sentence is
exactly the unit that keeps the wait under half a second.

`TTSBackend` asks for one thing `LLMProvider` does not — a backend that cannot
run here has to say **why**, in a finished sentence. A voice depends on things
outside the repository (an engine, a model, a language pack) and every one of
them is missing on some machine; 說話出聲（不能用）is a dead end, while naming the
file that isn't there is something the user can act on. The 說話 submenu puts that
sentence in the row's tooltip.

Voice languages are reported as BCP 47 with a **hyphen** (`zh-TW`), while
`OS.get_locale()` uses an underscore (`zh_TW`), and
`tts_get_voices_for_language()` matches on a plain prefix. An underscore
silently matches nothing.

**And on Linux the hyphenated form matches nothing either.** speech-dispatcher
exposes espeak-ng, which names its languages with **ISO 639-3** codes: Mandarin
is `cmn`, Cantonese is `yue`, and there is no `zh` anything. Godot also reports
the field as `<language>_<variant>` (`cmn_none`, `af_none`), so it is not BCP 47
on this platform at all. Measured on Ubuntu 24.04 / Godot 4.7.1: of 13362 voices,
`zh-TW`, `zh-HK`, `yue-HK`, `zh-CN` and `zh` matched **zero** and `cmn` matched
204. `cmn`/`yue` are therefore in `LANGUAGES` alongside the macOS spellings.

The failure that hid behind it is the more useful lesson. `_pick_voice()` used to
end in "any voice beats silence" and take `tts_get_voices()[0]` — which on that
list is **Afrikaans**, first alphabetically. So the pet read Traditional Chinese
in an Afrikaans voice: an intermittent, continuous run of gibberish syllables
every time `Nudger` fired, with nothing in the log, and the menu row cheerfully
reading 說話出聲（Afrikaans）the whole time. A voice that cannot pronounce the
language is not a degraded feature, it is a malfunctioning one, so there is no
last-resort pick any more — no match means speech is off and the menu says so.

Note what "verified" had meant here: that speech-dispatcher was installed. That
is the mechanism, not the observable — the same shape of mistake as the GNOME
icon note above.

Only three things actually reach TTS: `reply_chunk`/`reply_finished`, and
`pet_nudged` — which just `Nudger` and the vision refusal emit. Every other line
the pet says (餵食, game scores, 還在弄, work results, monitor alerts) goes
through `pet.gd::_on_pet_nudged()` as a **direct call**, never onto EventBus, so
it is shown and never spoken. Deliberate or not, that is the current contract.

`TTSService.remarked` follows that rule for a sharper reason than the rest: half
of what it carries exists *because* speech just stopped working, and routing a
"your voice broke" notice through the thing that broke turns it into silence.

#### The local neural voice, and why it is written as if it will be absent

`tts/qwen3_voice.gd` drives qwen3-tts.cpp — still entirely on this machine, no
network, no cost, but depending on three things this repository cannot carry: a
built shared library, 2.1 GB of model, and a Python to drive them. **The class is
written around the assumption that none of it is there**, because on almost every
machine that is true. Nothing is bundled, nothing is inferred, and a fresh clone
behaves exactly as it did before this existed.

The trade it buys is a voice that can be *the user's own*: `RecorderService`
already produces a WAV, and `我做的東西`'s row for one grows a 當我的聲音 button.
Measured, that works — the same sentence came out at a median F0 of **116 Hz in
the model's own voice and 238 Hz** in a cloned one.

**Voices are a named library, not one slot.** `user://qwen3_tts/voices/<name>.emb`,
any number, listed as a radio group in the 說話 submenu next to 預設嗓音 — which is
always there, is not a file, and is what every other row is measured against.
Three things follow from the name being the *filename*:

- Renaming the file renames the voice, and deleting it removes it. That is why
  管理聲音… opens the folder instead of being a sixth panel: a voice is one 4 KB
  file whose name is its whole identity, and the file manager already does both
  better than anything worth writing here.
- The name is typed by the user into a field one keystroke from the chat input,
  so it goes through `sanitise_voice_name()` — `validate_filename()`, leading dots
  stripped, length capped. The same discipline `OutboxService` applies, for a
  sharper reason.
- `active_voice()` re-checks the file exists on every read, so a voice deleted
  outside the app falls back to the default rather than leaving the pet mute with
  a tick on a row that is gone.

Cloning asks for that name **before** it clones (`ChatPanel.InputMode.VOICE`,
`voice_named`), because the only name this end could invent is the recording's
filename — 「錄音 2026-07-31 012304」, which is a timestamp, not a voice. Like
`SECRET` and `WORK` the mode reverts to chat on submit or dismissal; here the cost
of not reverting would be the next thing you said to the pet becoming a voice
name. Cloning also *selects* the voice: nobody records a take, names it, and then
wants to go on hearing the old one.

`res://voices/*.emb` is seeded into `user://` on first run, the same copy-out
`daemon.py` gets and for the same reason — and only when absent, so a shipped name
the user re-cloned stays theirs. It is named in `include_filter` alongside the
helper. Two voices ship, `anna` and `yu`, taken from reference clips the project's
author supplied and chose to distribute; the folder's README states the test every
addition has to pass, because an embedding is derived from a real voice and this
repository is public — the same line already drawn for community pet packs.

Measured on the shipped pair, same sentence in one session: **178 Hz** in the
model's own voice, **293 Hz** for `anna`, **154 Hz** for `yu`. Compare *within* a
run — synthesis is stochastic at the default temperature 0.9, and the same voice
measured 116 Hz and 178 Hz on two different days, a swing wider than the gap
between some voices.

**A helper process, not a GDExtension, and not the CLI.** Linking the library
into Godot means shipping a per-platform binary and taking any crash inside the
engine's own process — and this library has one: two overlapping `synthesize`
calls **abort the process** (SIGABRT) rather than returning an error. A desk pet's
optional voice must not be able to take the character down, so it goes in a child.
And not `qwen3-tts-cli` per sentence, because loading the model costs 754 ms
before a single character is synthesized, against 413 ms to say an eight-character
line warm.

Communication is `WorkService`'s shape exactly: requests over stdin (the direction
`SecretStore` already proves safe), responses to a **regular file tailed by byte
offset**, because `FileAccess` reads on a pipe block. The helper redirects its own
stdout and stderr into a log, and this is not tidiness — every synthesis writes
~22 lines to stderr that **cannot be turned off** (`print_timing` defaults true
and `Qwen3TtsParams` has no field for it), which would fill an undrained pipe and
wedge the helper mid-sentence.

Measured on this machine, an RTX 4090: model load 754 ms once, then 383-1278 ms
per sentence at RTF 0.24-0.49. Upstream reports ~1.7 CPU-only, i.e. slower than
speech — so `_watch_speed()` averages the real RTF over three utterances and, past
1.0, says so **once** and carries on. It emits `warned`, not `broke`: a machine
that lags still speaks, and silently switching the user's chosen voice out from
under them would be the more surprising outcome.

Things that look like implementation detail and are not:

- **`exec` in the launch command**, for the reason WorkService documents: without
  it the pid we keep is the shell's. Verified here — the helper's parent is the
  Godot process itself.
- **The helper cannot be orphaned.** Killing Godot with `SIGKILL`, which
  `_exit_tree()` cannot survive, still ends it: stdin is the pipe, the reader
  thread hits EOF, and it quits. The `OS.kill` in `shutdown()` is the tidy path,
  not the guarantee.
- **The engine is unloaded after idle, and the process is not.** Dropping it
  returns **2.6 GB of VRAM** on a machine the user is also working on. Exiting
  instead would be simpler and is deliberately not done: a helper that comes and
  goes is a pipe that breaks under us. (Godot survives writing to a dead pipe —
  measured, 40 writes returned error 13 and nothing worse — but the write goes
  nowhere and the pet waits for a reply that cannot come.)
- **A crash is forgiven exactly once** (`MAX_RESTARTS`), the same shape as
  WorkService's stale-session retry, and for a sharper reason: the SIGABRT above
  is a thing that genuinely happens, and losing the chosen voice for the rest of
  the session over one of them is too harsh. `_restarts` resets on `ready`, so
  only a helper that comes back is forgiven twice.
- **`GGML_NO_BACKTRACE=1`.** On an abort, ggml forks **gdb** and lets it print to
  stdout. Nothing here parses stdout, so that alone is survivable — but a voice
  that stops to run a debugger takes seconds to die, and the pet is waiting on the
  process to disappear.
- Errors are tagged with the **op** that produced them, and a coded `silent`, so
  the caller never matches on the wording of a C++ exception nobody controls.
- **Every request must be counted in `_outstanding`, and every request must be
  answered.** `_process` switches itself off when that reaches zero and nothing is
  playing, so a request that forgets to count itself is one whose reply is never
  read. Cloning did exactly that: `clone_from()` turned polling on without
  registering anything, polling stopped on the next frame, and the symptom was a
  voice file appearing on disk while the pet said nothing at all — the feature
  half-working in the way least likely to be noticed. The helper's side of the
  same rule is that a `say` with empty text, and one dropped by a cancel, both
  answer with a coded error instead of being binned.
- **The cancel watermark applies to `say` only.** Sentences and clones share one
  id space (`_next_id`), so a watermark over both let an ordinary "stop talking"
  throw away a voice-clone requested a moment earlier — and the pet then blamed
  the user's recording for it.
- **A clone is the one request carried across a helper restart.** A lost sentence
  is a gap in a reply; a lost clone is a button that did nothing, since
  `voice_cloned` is the only thing the panel and the pet are waiting for. If the
  restart itself fails, `_fail()` answers it before giving up.
- **`_on_backend_broke` says the reason even when there is nothing to fall back
  from.** `clone_voice_from()` starts the helper whichever backend is active, and
  the OS voice is the shipped default — so the likeliest time this fires is a
  當我的聲音 on a machine where the engine cannot load. Guarding the whole handler
  on "am I on it" made exactly that case fail in complete silence.
- **`_find_python()` requires the candidate to *run*, not merely exist.** macOS
  ships `/usr/bin/python3` as a Command Line Tools stub that opens an install
  dialog and exits, which `file_exists()` cannot tell from an interpreter — the
  voice would report available, offer the row, and fail at the first thing the pet
  tried to say. One process per candidate, at most once per session.
- **The helper opens the ggml libraries itself** (`--lib-path`, `RTLD_GLOBAL`)
  rather than relying on `LD_LIBRARY_PATH` reaching it. On macOS dyld strips
  `DYLD_*` when exec'ing a restricted binary, and a system Python is exactly that,
  so the environment variable never reaches the loader that would use it. The
  export is still done — it is correct on Linux — but it is the belt, not the
  braces.
- **The helper decodes stdin as UTF-8 explicitly.** Left to the locale, a
  `LANG=…ISO-8859-1` or Big5 desktop decodes 「你好」 as mojibake and raises
  *nothing* — the surrounding JSON is ASCII, so it parses, and the pet then
  articulates the mojibake. Silent corruption of the words it says is worse than a
  crash, and every user-facing string in this project is Traditional Chinese.
- **`reader()`'s `quit` is in a `finally`.** It is the only path by which the main
  loop can ever be told to stop, so a reader thread that died for any reason would
  leave a process alive with nobody able to end it.
- The daemon is copied from `res://tools/` to `user://` before running: `res://`
  is inside the pack in an exported build and has no path a Python interpreter
  can open — the same thing that makes `res://.env` invisible there. It is also
  named in `include_filter` on all three presets, since a `.py` is not a resource
  Godot imports. **That last part is reasoned, not measured** — there are no
  export templates on the machine this was built on. It is also why `_check()`
  reports a missing `res://tools/qwen3_tts_daemon.py` as its own sentence: if the
  filter turns out to be wrong, the failure is a message naming the file rather
  than a voice that silently never starts.

**A silent reference produces a voice, not an error.** Fed a 13-second recording
of an idle room (peak 0.028), the extractor returned 1024 perfectly well-formed
numbers and the pet then spoke in an arbitrary voice nobody chose. There is no way
to ask the library about this, so the helper measures the reference's peak itself
and refuses below 0.05 — real speech measured 0.26. It fails *open* on a WAV it
cannot parse, since the check must never be the cause of the failure it prevents.
Note this is the *clone* side only; a recording of silence still saves happily,
which is the gap `RecorderService.stop()` still has.

#### 破音字, and why the correction is a lookup table

The engine is end-to-end — text tokens in, audio tokens out — so there is no
grapheme-to-phoneme stage to hang a pronunciation dictionary on. Two things were
measured before settling on substitution, both at `--temperature 0` so the only
variable is the input:

- **Inline annotation is read aloud, not parsed.** 「我要去銀行。」 is 1.82 s;
  adding `(háng)` makes it 2.22 s and `(háng háng háng háng)` makes it 2.46 s.
  The duration tracks the length of the annotation, so the model is saying it.
  SSML produced no audio at all.
- **A model in the speaking path is both slow and dangerous.** Asked to respell
  four sentences: `gpt-5.4-nano` median **1245 ms**, `gpt-5.4-mini` median
  **915 ms** — a second per sentence on top of the 0.4-1.3 s the vocoder already
  costs. Worse, in four sentences nano turned the text **Simplified** and
  produced 「睡覺」→「歲覺」 (歲 is suì, not jiào), and mini produced 「睡覚」 (覚
  is the Japanese form). Roughly one line in four came back *worse*, silently,
  because nothing downstream can tell a good respelling from a bad one. It would
  also cost an API call per sentence for a voice that otherwise works with the
  LLM switched off entirely.

So `prompts/pronunciation.json` is a table of whole words, applied in
`TTSService._respell()` — **the single point where text enters a backend, and the
only place the substituted string exists.** The bubble, the transcript, the memory
store and the exported Markdown all keep what was actually written; a pet whose
saved conversation read 「崇新」 because that is what it had to say out loud would
be corrupting the record to fix the speaker.

Three things about the table:

- **Keys are words, never single characters.** 行 is xíng nearly everywhere and
  háng only inside particular words, so a character-level rule is wrong far more
  often than it is right.
- Rules are applied **longest key first**, so 「重新」 beats any rule mentioning
  「重」 — otherwise the specific correction never fires.
- It ships **empty**, and that is a statement about what could be verified rather
  than about what is needed. Nothing here can hear; the entries have to come from
  someone who can. `tools/say.sh` is the loop (it applies the same table and
  prints what it actually sent), and `tools/build_pronunciation.py` runs a model
  over the pet's own lines **offline** to propose candidates — the same model that
  is unsafe per-sentence is useful when every mistake it makes is caught while it
  is still a diff. It screens its own output for Simplified and Japanese
  characters, which is exactly what the two measured failures were.

One measured non-entry, worth keeping as the shape of the trap: 「銀行」 and
「銀航」 synthesize to 1.82 s and 1.90 s, i.e. the engine already reads it háng.
Adding a rule for it would have been a fix for nothing, and every unnecessary rule
is another chance to be wrong.

#### What another machine actually needs

Two paths and a package. `[tts] qwen3_lib` and `qwen3_models` in `config.cfg`
(or `GODOT_PET_QWEN3_LIB` / `_MODELS`), plus a python3. Everything else is
discovery, and it is ordered so a person says each machine-specific thing at most
once:

- The library is looked for in `user://qwen3_tts/`, beside the executable, then
  `~/{git_project,src,Projects,code}/qwen3-tts.cpp/build/`, then `/usr/local/lib`.
- **The models are then found from the library**: `<library>/../models` is the
  rule carrying the most weight, because in the upstream layout finding one finds
  the other no matter where the clone lives. Verified — with nothing written in
  config at all, a clone at `~/git_project/qwen3-tts.cpp` was found end to end.
- Either weight filename is accepted. `load_models()` prefers
  `qwen3-tts-0.6b-q8_0.gguf` over the f16 one where both exist, which neither the
  header nor the integration guide mentions, so a directory holding only quantised
  weights is valid and a check that knew about f16 alone would reject it.

**A path the user wrote down is the answer, not a first guess.** An override that
doesn't exist reports *that*, rather than falling through to the search — which on
the machine this was built on hid a broken override completely, because the search
found the real library and everything appeared to work. That was a real bug, found
by a test that was trying to simulate a machine without the engine and quietly
failed to.

`LD_LIBRARY_PATH` has an escape hatch (`[tts] qwen3_lib_path`) because the built
`.so` carries an **absolute RUNPATH into the tree it was built in**, so a library
copied anywhere else cannot resolve ggml.

#### The pet can fetch the models, and deliberately cannot fetch the engine

`tts/model_fetcher.gd` downloads the two GGUF files, offered as one row in the
說話 submenu directly under the backend it repairs. That row appears only when
`Qwen3Voice.needs_models()` is true — **the models are the last gap** — which is
why `_check()` orders its tests library-first and why `_gap` exists as something
other code can branch on. `_reason` stays a sentence for a person; matching on
its wording is how a reworded message silently turns a feature off.

**The library is not downloadable and this is not an oversight.**
`predict-woo/qwen3-tts.cpp` has published no release and no tag — the GitHub API
returns `[]` for both — so there is no binary anywhere to fetch. The only route
is cloning and building it, which needs a C++ toolchain, the ggml submodule and
a CUDA or Metal SDK, and on macOS then meets library validation refusing an
unsigned `.dylib` under a hardened Python. Closing two gaps of three would spend
1.7 GB before revealing the voice is still mute.

**Which conversion is fetched was measured, and the obvious choice was wrong.**
GGUF names its tensors, independent conversions do not agree, and nothing in a
filename says which contract a file follows. Measured against a known-working
local file:

| | `general.architecture` | talker | tokenizer |
|---|---|---|---|
| what `src/gguf_loader.cpp` wants | `qwen3-tts` | `spk_enc.conv0.weight` | `tok_dec.dec.0.conv.bias` |
| `khimaros/*` (fetched) | `qwen3-tts` | identical, all 478 | identical, all 448 |
| `cstr/*` (most downloaded) | `qwen3tts` | **109 of 478 differ** | **all 448 differ** |

`cstr` is the most-downloaded conversion and was the first choice; it is built
for CrispASR, a different engine, and would download perfectly and fail to load.
`tools/check_model_source.py` is that check — architecture, every tensor name,
every shape, over HTTP Range so a candidate costs 16 MB rather than 1.3 GB — and
it exits non-zero, so it can gate a URL change rather than merely inform one.
**Re-run it before editing any URL in `FILES`.**

Three things that are load-bearing:

- **The filenames are the loader's, not upstream's.** `src/qwen3_tts.cpp:119`
  hardcodes both, and the tokenizer is spelled `-f16` with no alternative
  accepted, so a downloaded file is renamed into that regardless of what it was
  called. The talker is looked for as q8_0 *first*, which is why the quantised
  one is fetched: half a gigabyte smaller and the one the loader prefers anyway.
- **Nothing lands under its real name until its hash matches.** Downloads go to
  `.part` and are renamed only after SHA-256, hashed in 8 MB slices across frames
  because the pet is a live animation and hashing 1.7 GB in one call freezes it.
  Verified by serving deliberately corrupted bytes: the write is refused, the
  `.part` is deleted, and the models stay absent rather than half-present.
- **The download lands in `_work_path("models")`, the first place `_find_models()`
  looks**, so `TTSService.rediscover()` is the whole of the wiring. Verified end
  to end on a machine with the engine and no weights: the row appeared, 1.68 GB
  arrived, both hashes matched, the row vanished, 本機模型（Qwen3） stopped being
  disabled and the voice list appeared — **with no restart** — and the fetched
  files then synthesised 3.18 s of real audio (peak 0.500, not silence).

One trap this cost: `AcceptDialog` sizes itself to its content and a path has no
spaces, so `AUTOWRAP_WORD_SMART` cannot break one. The models path pushed the
dialog wider than a 1920px screen with both buttons off the edge; `_short_path()`
shortening `$HOME` to `~` is the fix, since widening the wrap mode would only
move the break to an arbitrary character mid-path.

**macOS is the engine's better platform, and ours is where it bites.** Upstream
ships a macOS quickstart, Metal is on by default for Apple, and there is a CoreML
code predictor — so an Apple Silicon Mac takes the accelerated path, not the
~1.7-RTF CPU one. Nothing here has been run there; what is known to need care:

- **Use a Homebrew python3, not `/usr/bin/python3`.** The system one is a Command
  Line Tools stub on a Mac without Xcode CLT (exists, opens an install dialog,
  exits), which is why `_find_python()` requires a candidate to *run* rather than
  merely be there, and why the macOS candidate order puts `/opt/homebrew` first.
  It is also hardened, which means both that `DYLD_*` is stripped before it and
  that library validation can refuse an unsigned `.dylib`. Two more reasons for
  the same answer.
- `<exe>/qwen3-tts/` resolves inside `Godot Pet.app/Contents/MacOS` in an exported
  build — a signed bundle nobody should be writing into. Harmless as a candidate
  that never matches; `user://` is first in the list and is the place to drop
  things.
- The OS fallback is *better* there than on Linux: macOS has real `zh-TW` voices,
  so a Mac without the engine still speaks properly. The whole Afrikaans episode
  was Linux-specific.

**Windows reports unsupported, and is closer than that sounds.** The only
structural blocker is `/bin/sh`, and the shell is there for two things: the
redirections and `exec`. Have the helper open its own log and set
`GGML_NO_BACKTRACE` in `os.environ` before `ctypes.CDLL`, and Godot could launch
python directly — which also removes the orphan problem `exec` exists to solve,
since there would be no shell to be the parent. What would remain is a `.dll`
build and somebody to test it.

Startup picks a backend and **never writes one back**, the same rule
`LLMService.set_provider()` follows. Verified: with `backend="qwen3"` and the
library missing, the pet speaks in the OS voice, the menu row is disabled carrying
the reason, and `config.cfg` still says `qwen3` — so plugging the machine back in
restores the choice with nothing to re-select.

### Needs and unprompted speech

All four needs are modelled as "higher is better" (`fullness`, not hunger) so a
single decay rule covers them. `mood` is not independent — it drifts toward a
target derived from fullness and energy, so a hungry, tired pet is grumpy
without special-casing. Time with the app closed counts as sleep, capped at a
day. State reaches the model as qualitative phrases, not numbers.

Unprompted lines come from `prompts/nudges.json`, **not the LLM**: an idle pet
calling the API every few minutes costs real money for no visible benefit, since
what makes a nudge feel alive is its timing rather than its wording. The model
is only involved once the user replies. Anything the pet says unprompted goes
through `LLMService.note_pet_said()` so its next real reply doesn't contradict
it.

Two of the pools are more than a list of lines:

- `focus` fires off `PresenceService` after 45 unbroken minutes in one app, and
  sits *above* the quiet-since-last-chat gate, in the same tier as hungry and
  tired — whether the pet talked to you ten minutes ago has nothing to do with
  whether you need to stand up. It shares the ordinary 35-minute per-reason
  cooldown, so a long session earns a break line roughly every 35 minutes. Nobody
  has yet sat through a run of those to say whether that reads as caring or as
  nagging.
- `memory` entries are `{fact}` templates, filled from `MemoryStore.facts()` at
  pick time — still no API call, so the pool stays as cheap as the rest. Facts
  are free text some model wrote, so `_usable_facts()` drops anything over 30
  characters or carrying sentence-ending punctuation before it goes near a
  template: splicing a complete clause into 你記得你{fact}耶 glues two sentences
  together with no connector. It is taken only 40% of the times it is available,
  and the last three facts used are steered away from — in memory only, not
  persisted, the same judgement already made for `_last_nudge_at`.

### The chat input grows with what you type

Two fields live under the pet, one visible at a time. The masked one has to stay
a `LineEdit` — `secret` is a LineEdit property with no `TextEdit` equivalent, and
an API key is one line by definition — so `_input` keeps the keys and `_area`
(a `TextEdit`) takes everything the user *says*. `ChatPanel._field()` is the
single point that branches; `_close` is reparented onto whichever field is up, so
it still inherits that field's visibility and no path can show a field without
its way out.

- **Enter sends, Shift+Enter breaks a line**, done by connecting the `gui_input`
  *signal* rather than overriding `_gui_input()`. `Control::_call_gui_input`
  emits the signal before calling the virtual — its own source comment says this
  is so a listener can override the event — and that is the only way to stop
  Enter inserting a newline.
- The height is **one row at `INPUT_HEIGHT`, plus one line height per row after
  it**, not derived from the padding. Derived, the step from one row to two comes
  out smaller than every later step, which reads as the field having lost its
  padding rather than gained a line.
- `PetStyle.input_style()` is always passed the **single-line** height. That
  argument only feeds the corner radius, so a grown field keeps the pill's corner
  and becomes a rounded rectangle instead of a giant lozenge. Its `pad_y`
  argument exists for the opposite reason: a `LineEdit` centres its one line
  itself and a `TextEdit` draws from the top, so without it the text rides
  visibly high.
- The close button is measured from the field's **bottom**, not centred. Where
  the pet lives the field is pinned to the desktop edge and grows *upward*, so a
  bottom anchor is what leaves the button still while you type.
- **`ChatPanel.input_resized` is not optional.** The passthrough mask is built
  from `get_input_rect()`, and where the mask doesn't clip rendering it is only
  pushed on discrete events — so without that signal a field that grew to two
  rows draws fine and the upper half takes no clicks.
- Past `INPUT_MAX_ROWS` the field scrolls. The engine's default scrollbar inside
  a paper pill reads as a rendering fault, so its styleboxes are emptied rather
  than the bar hidden — `TextEdit` re-shows it itself whenever it decides one is
  needed.

### Watching what the machine is doing

`autoload/monitor_service.gd` samples the process table every twenty minutes
during working hours. Sibling of `PresenceService` and deliberately the other
half of the same question: that one watches *you*, this one watches the machine.
Nothing is written to disk or sent anywhere.

**Scanning every twenty minutes and reporting every twenty minutes are different
decisions.** The scan is cheap and its value is the record it builds; a line
spoken aloud that often is noise. So the pet opens its mouth only on a crossed
threshold, and everything else waits in `ui/monitor_panel.gd`.

Two silent failures this cost:

- **`FileAccess.get_as_text()` returns an empty string on `/proc/meminfo`.**
  procfs reports a length of 0 for these files, so the read succeeds at nothing
  with no error and every number downstream becomes zero. Use `get_line()`.
- **`OS.get_memory_info()`'s `available` is unusable on Linux.** Measured at the
  same instant: `/proc/meminfo` MemAvailable 29.1 GB, `get_memory_info()`
  13.4 GB — less than half, which trips the "memory is tight" threshold on a
  machine with 44% of its RAM free.

**Linux does not go through `ps`, and the reason is resolution.** `ps -o time`
prints whole seconds there, so across a two-second window every process resolves
to 0%, 50% or 100% — measured, and it put three unrelated processes at exactly
50%. `/proc/<pid>/stat` counts in USER_HZ ticks, which the kernel fixes at 100
for the procfs ABI, so 10 ms. It is also faster: 741 processes in 12.5 ms against
`ps`'s 18 ms, and with no subprocess there is no blocking wait to bound. macOS
keeps `ps`, where the same field carries hundredths (`0:00.42`).

- Split `/proc/<pid>/stat` on the **last** `)`, never on whitespace: field two is
  the executable name in parentheses and the kernel neither escapes nor quotes
  it, so a process named `foo) bar` is a legal way to defeat a naive parser.
- **The page size is derived, not assumed** — `stat` counts pages and Godot
  exposes no page size, so `status`'s `VmRSS` in kB divides back to it. 4096
  everywhere x86 Linux has run, but an ARM kernel can be built at 16k or 64k,
  where a constant misreports every process by a factor of four.
- **Linux truncates a process name at 15 characters** wherever that lands, so
  `next-server (v15.2.1)` arrives as `next-server (v1`. Untidy in the panel; in
  the line the pet said aloud it came out as 「跑最兇的是 next-server (v1。」, an
  unclosed bracket against a full stop, which reads as the app breaking mid-word.
  The orphaned fragment is dropped.

One scan is **two samples two seconds apart**, and every CPU figure is the
average over that gap. Diffing against the previous scan twenty minutes ago
sounds more thorough and reads worse: a build that pegged every core for four
minutes and finished would still top the list sixteen minutes later. The long
view is the panel's history strip, built out of these. The gap is an `await`,
never a busy wait — two seconds of that is a frozen pet.

There is no consent dialog, unlike the screen look and the presence poll, and the
difference is what is being looked at: a process list is what the computer is
doing, read locally, and the switch being off by default is the opt-in. The one
non-obvious consequence is on the menu row's tooltip instead — the scan never
leaves the machine, but **the line the pet says names a process and goes into the
conversation like any other**, so the model sees it next turn. That is
deliberate: unrecorded, a reply of 「哪個程式在吃？」 would find the pet with no
idea what it just said. `_on_resource_alert` is gated on 主動說話 as well as its
own switch, since this is the pet speaking unbidden.

At most one line per scan, most consequential first: no memory left beats one
program holding a lot of it, which beats a busy CPU. Three at once would be the
pet reading out a dashboard, which is what the panel is for.

### Watching which app you're in

`autoload/presence_service.gd` samples the foreground app every 30 seconds so
`Nudger` can decide *when* to speak instead of guessing off a plain timer. Two
values, both content-free: an opaque per-platform app identifier — WM_CLASS's
class half on Linux, the process name on macOS — and how long it has held focus.
**Never a window title**, which is where documents, messages and URLs actually
live, and never logged, never written to disk.

Consent is modelled on `VisionService`'s and deliberately isn't the same shape.
Vision asks per event, because each capture is its own decision; a background
poll has no "just this once", so the only way to say yes here already *is*
standing consent — which is why the accept button gets the quiet treatment the
vision dialog reserves for 以後都不用問我. It stores **two** config keys:
`consented` is sticky once granted, `enabled` is the live switch, so re-checking
the menu item after turning it off doesn't re-ask something already agreed to.

- **Windows reports unsupported on purpose.** `GetForegroundWindow()` from
  PowerShell means `Add-Type`-compiling a P/Invoke declaration on every fresh
  `powershell.exe` — the same most-of-a-second cost documented above for
  `CredRead`, except this one would run on an unattended timer for as long as the
  app is open, where `SecretStore` pays it once per key thanks to its cache. The
  menu item is disabled rather than the pet stalling every 30 seconds.
- macOS goes through `osascript`, and **the first call is the one that raises the
  Automation permission prompt**. Hence `grant_consent()` samples immediately
  instead of waiting for the timer — that prompt should land while the user is
  still looking at the dialog they just accepted — and hence `_run()` has a
  timeout at all, since an unanswered prompt otherwise sits there forever.
- Linux shells out to `xprop` (`x11-utils`), and only ever reads
  `_NET_ACTIVE_WINDOW` and `WM_CLASS`. Wayland has neither, so it reports
  unsupported there — the same X11-only promise the window positioning already
  makes.
- `_run()` closes stdio explicitly. `SecretStore` can leave it to refcounting
  because its writes are one-shot; this is a repeating timer that lives as long
  as the process, where a leaked pipe handle is a slow fd leak.
- An empty sample means "couldn't answer this tick", never "switched to
  nothing". One flaky read must not reset a real streak.
- `seconds_in_current_app()` returns -1.0 when there is nothing to say — not
  consented, not supported, no sample yet — which every threshold test above
  treats as "not long enough" without special-casing it.

## Tuning without code changes

`prompts/persona.md` (character and reply format), `prompts/nudges.json`
(unprompted lines, including the `{fact}` templates in the `memory` pool),
`prompts/pronunciation.json` (破音字 the voice reads wrongly — see below), and
the `DECAY` / `STARTING` constants in `autoload/pet_state.gd`. Prompt files take
effect on restart.

`config.cfg`'s `[tts]` section carries the voice: `backend` (`os` / `qwen3`),
`voice` to pin an OS voice id, and — for the local model — `qwen3_lib`,
`qwen3_models`, `qwen3_lib_path`, `qwen3_language`, `qwen3_idle_seconds` and
`python`. Every one of the last six is a machine-specific path or a knob whose
right value is a property of the machine, which is exactly why none of them is in
code. All are optional; discovery covers the conventional layouts.

`config.cfg`'s `[monitor]` section carries the load monitor's working hours
(`start_hour`, `end_hour`, `weekdays_only`) and its three alert thresholds
(`mem_tight`, `proc_mem_share`, `cpu_busy`). The thresholds live there rather
than in code because what counts as "too much" is a property of the machine:
12% of 8 GB and 12% of 64 GB are not the same amount of trouble.

### Screen vision

`autoload/vision_service.gd` captures the screen with
`DisplayServer.screen_get_image()` and sends it as an `image_url` content part.
Nothing is captured until the user agrees. A request — from the menu, or from
the model itself — goes out as `EventBus.screen_look_requested`, and `pet.gd`
puts a confirmation dialog up; the standing-consent button stores it in config.
It never runs on a timer or from a nudge.

That dialog has to answer the three questions a screenshot prompt actually
raises — how much is captured, who receives it, and how long it is kept — and
name the action in the buttons, since "好 / 不要" is unreadable to anyone who
skipped the paragraph, which is most people. The standing-consent button is
styled as the quietest thing in the window: it is the one answer here that can't
be taken back by simply not clicking it again.

Typing "看一下我在幹嘛" is the obvious way to ask, so there are two triggers, and
both are needed:

- `VisionService.wants_a_look()` matches the question locally, in `_on_user_said`,
  before the model is called at all. Deterministic and free.
- The model can emit `[look]` in the mood-tag slot, at which point the same
  question is re-sent with a screenshot attached. This covers what the phrase
  list can't — "這個錯誤是什麼意思" typed with the error still on screen.

Leaving it to `[look]` alone was a mistake: **`gpt-5.4-nano` never emits it** —
0/12 on questions that plainly need a screenshot, where `gpt-5.4-mini` scores
9/9 and still declines correctly on ones that don't. Nano reads an attached
screenshot perfectly well, it just never asks for one, so the whole feature was
dead on the model that was configured. Hence both the local trigger and
`DEFAULT_MODEL` being mini.

`_in_vision_pass` stops a second `[look]` looping. `_look_declined` stops the
model re-asking after a refusal — and suppressing the tag is *not* enough on its
own: the persona tells the model to answer a screen question with nothing but
`[look]`, a small model follows the character sheet over any appended footnote,
and the swallowed tag left the pet saying nothing at all. So
`build_system_prompt(false)` cuts the `## 看螢幕` section out of the persona for
that one turn.

Related: `_on_finished` must take `_clean_reply` whenever the tag parser
resolved, never the raw text — the old `if not _clean_reply.is_empty()` fallback
put a bare `[look]` in the bubble and in history.

The `[look]` handler must defer before cancelling the provider: it runs inside
the provider's own chunk signal, and tearing down the HTTP client mid-poll
leaves `_poll_body` reading from a client that's gone.

Turning a look down still has to produce an answer. A refusal from the menu is
just a nudge, but a refusal to a *typed* question leaves that question sitting in
history unanswered, so `LLMService.answer_without_looking()` answers it blind.

macOS needs Screen Recording permission, and **the failure is silent**: without
it the capture contains just the wallpaper and the app's own windows, with no
error, so the model happily discusses the desktop picture. The service checks
mean local contrast and asks about permission rather than asserting, since a
genuinely bare desktop trips the same test. Each exported build is a separate
binary and needs its own grant.

`FLAG_EXCLUDE_FROM_CAPTURE` is toggled on for the duration of one capture, not
left on: permanently excluded, the pet can't be photographed at all — not by the
user, and not by the screenshot-based verification this project relies on. The
window server needs a frame or two to apply it before the capture.

Replies about the screen are appended to history as **ephemeral**: they stay in
the recent window so follow-up questions work, but are skipped when condensing,
never extracted as facts, and never written to `memory.json`. Otherwise one
glimpse of something private becomes a permanent fact re-sent with every request.

The persona has to grant an explicit exception for this — it tells the pet it
can't see the screen, and the model will refuse to describe a screenshot it is
plainly being shown unless the exception is spelled out.

### Files dropped on the pet

**`Window.files_dropped` is not shaped by the mouse-passthrough mask.** It rides
on the OS's native drag-and-drop target registration, which is a different
mechanism from the click hit-testing that mask shapes, so with a window this size
a drop fires from anywhere in the mostly-transparent, overhanging rect —
including over whatever desktop icons the bottom-right corner is sitting on top
of. `WindowController` therefore only reports it, in window-local pixels, and
`pet.gd::_on_files_dropped_on_window()` hit-tests `_pet_box` before doing
anything; otherwise dragging a file *past* the pet to the desktop gets hijacked.

That first sentence is reasoned from the two mechanisms being separate, not
measured on all three platforms — but the hit test is needed either way, since
on Windows the mask is widened to the whole chat chrome regardless.

The content goes out on `EventBus.file_content_said`, not `user_said`. The two
are the same thing to `TTSService` and `PetState`, which connect their existing
`user_said` handler to it as well — but `LLMService`'s `user_said` listener also
runs the local screen-look phrase match, and that is a blind substring test
written for a short typed question. A file's own text, or just its name
(`我的螢幕錄影.mp4`), trips it; this repo's own `PLAN.md` contains 我在幹嘛
verbatim.

An image takes the `image_url` path `VisionService` already built —
`image_to_data_url()` stopped being private for exactly this, so both pay the
same bounded prompt-token cost — but with `ephemeral = false`. A screen look is
an incidental glimpse of whatever was open and must not harden into a permanent
fact; a file the user dragged over is something they deliberately handed across,
and belongs in history like any other turn.

- `handle_drop()` normalises backslashes to `/` on entry. Windows hands back
  native paths, and `String.get_file()` / `get_extension()` only recognise `/`,
  so an un-normalised Windows path looks like it has no directory and no
  extension. `FileAccess` and `DirAccess` take forward slashes there anyway, so
  one replace at the top beats special-casing every string op below it.
- Everything unreadable — a folder, a vanished path, an empty file, one over the
  size cap, an extension not on the list — still produces a line *phrased as the
  user*, so the pet answers instead of going quiet. That is why the service
  always ends in exactly one emission or one `ask_about_image()`, and the caller
  never branches on the outcome.
- Known gap: the image branch calls `LLMService.ask_about_image()` directly, so
  it never emits `file_content_said`. A dropped image therefore doesn't stop the
  pet mid-sentence and doesn't count as an interaction for `PetState`, where
  dropped text does both.

`persona.md` needs the same kind of explicit exception the screen look does — it
states flatly that the pet cannot see files, and the model will refuse to discuss
one it is plainly being handed unless told otherwise.

### Files the pet makes

`autoload/outbox_service.gd` owns one folder — under the user's documents
directory, so `~/文件/GodotPet` on a localised Linux desktop — and everything the
pet produces lands there. Deliberately not `user://`: buried under
`~/.local/share`, it defeats the whole point, which is that the thing the pet
made is something you can find and open.

The pet **no longer makes files of its own**. `MakerService` is gone: asking a
model to invent a note and drop it in a folder turned out to be the least
interesting thing an agent CLI can do, and it competed with the thing that is
interesting — see "The pet as an assistant" below. What still writes here is the
transcript export, which involves no model at all.

**Names arriving there are still not trusted**, because the sanitiser is what
makes that guarantee cheap to keep rather than something to re-derive if
anything ever writes here again. So:

- `sanitise_name()` reduces anything to a leaf. Verified against the obvious
  attempts: `../../../etc/passwd` → `passwd.md`, `/etc/shadow` → `shadow.md`,
  `a/b/c.txt` → `c.txt`, and a leading dot is stripped so `.bashrc` → `bashrc.md`
  rather than a hidden file the panel would never list.
- The extension is a **whitelist** with nothing runnable on it. An extension not
  on it is folded into the stem instead of being dropped, so `run.sh` becomes
  `run.sh.md` — inert, but still recognisably what was asked for.
- `_free_name()` never overwrites: `note.md` twice gives `note.md` and
  `note-2.md`. A model reaching for the same obvious name twice must not eat the
  first thing it wrote.

There is no per-file consent dialog, and that is the point rather than an
omission. Unlike a screen look, a write into a folder that exists for it sends
nothing anywhere and destroys nothing — what it risks is clutter, and the answer
to clutter is being able to see it: `ui/outbox_panel.gd` is the third window of
the same shape as the memory and transcript panels, where every line can be
deleted on its own.

**The transcript export** (`ChatLogPanel._on_export`) was for a long time the only
producer, and is still the only *text* one. It involves no model at all, which
makes it one of two things in this app that can produce a file with the LLM
switched off entirely — and it is what made the folder testable before any agent
existed. Ephemeral turns keep their 「這則關掉就忘了」 footnote in the Markdown,
because a transcript that quietly promoted a screen-look reply to a permanent
record would break the one promise ephemeral turns exist to make.

`OutboxService.reserve()` exists because `write()` cannot serve the other one.
That takes a `String` and refuses past a megabyte, which is right for a note and
wrong for audio — a minute of 16-bit stereo is ten times the cap — and
`AudioStreamWAV.save_to_wav()` wants a path rather than handing back bytes, so
there is nothing for `write()` to receive. `reserve()` still runs the same
sanitiser and the same never-overwrite rule, so the folder's guarantees hold for
every path into it rather than for most.

### The pet records, and that is all it does with a microphone

`autoload/recorder_service.gd` captures the microphone to a `.wav` in the outbox
folder. Deliberately **not** the voice input PLAN.md's Phase 8 designed: nothing
is transcribed, no provider is involved, and nothing reaches the network — which
is why it is the second thing here that works with the LLM switched off, and why
it needs none of `VisionService`'s consent machinery.

Two things about the audio graph, both of which fail silently if wrong:

- **Muting the record bus does not mute the recording.** The microphone has to be
  *played* to reach an effect chain at all, and a live microphone routed to the
  speakers is feedback — so the bus is muted. A bus's mute is its output fader,
  applied after its effects, so `AudioEffectRecord` is unaffected. Measured
  rather than assumed, because the failure mode is a silent WAV with no error:
  fed a 440 Hz tone through a virtual source, muted and unmuted both captured
  peak amplitude **0.088379**, identical to what `parecord` measured off the same
  source.
- **The capture device is opened on demand, not at startup.** `enable_input` in
  `project.godot` only *permits* capture; `AudioStreamPlayback` opens the device
  when it starts. Measured with `pactl list short source-outputs`: one client
  with the pet idle, two while recording, back to one after. A desk pet that sat
  holding the microphone open would light the system's in-use indicator all day.

Verifying this needs a controllable input, and **Godot filters monitor sources
out of `get_input_device_list()`** — a null sink's `.monitor` is invisible to it,
so `module-null-sink` alone is not enough. `module-remap-source` over that
monitor presents a real source, which Godot does list. `AudioServer.input_device`
also only sticks *after* capture is open; set before `play()` it silently does
nothing and reads back empty.

There is no consent dialog, and the reasoning is worth keeping because a
microphone looks like it should have one. Every consent dialog in this app guards
something that happens without a fresh human action right now: a background poll
(`PresenceService`), or something the model asked for (`VisionService`, `[work]`).
This is neither — it happens because the user just clicked 錄一段話, it announces
itself for as long as the device is open, and stopping is one click where
starting was. What was genuinely missing is *where it went*, and that is answered
once, at the moment the file exists, in the line the pet says.

#### The indicator is the speech bubble, held open

A recording with no persistent sign of itself is the one thing this feature must
not be, and the bubble already solves the hard parts — it clamps to the visible
area, follows the pet, and on Windows is already inside the passthrough mask.
`ChatPanel.show_holding()` reuses `_streaming`, which is *already* "more is
coming, don't start the fade countdown", rather than racing it with a second
timer. Repeat calls only rewrite the text: replaying the appear animation would
make a bubble that jumps once a second.

**The clock cannot tick from `pet.gd::_process`.** That is switched off except
where the passthrough mask clips rendering — `_ready()` ends with
`set_process(WindowController.passthrough_clips_rendering())` — so on Linux and
macOS it would simply never run. `RecorderService` emits `tick` on whole-second
boundaries instead, and only has `_process` enabled while the microphone is open.

#### The sixth verb, and the row that lied

CLAUDE.md names a sixth verb as the point to stop and think, so: 錄音 is something
you ask the pet to do *for* you and the result is something it then holds — the
shape of 幫我做事, not of a window. It could have been a button in 我做的東西's
footer, in the group that is allowed to grow and free of charge, but then you
would be talking to a window rather than handing something to the pet, which is
the premise of the app. It is one row, not two, because the row carries its own
stop. Measured at 14 rows: 392px on a 1080p desktop, still short of the 476px
that forced Godot to shove the flat menu upward.

That stateful label then found a real bug. **`_build_menu()` does not run on every
open** — `_open_menu()` rebuilds only when the installed pack list changed — so
the row still read 錄一段話 while the pet was visibly recording, and following the
indicator's own instruction did nothing. `_set_item_text()` refreshes just that
row on open, which is also why the clock in it is a snapshot rather than live: the
menu covers the bubble that has the running one.

macOS needs both halves or the failure is silent, as PLAN.md warned: the export
preset carries `codesign/entitlements/audio_input=true` **and** a microphone usage
description, and the description is shown to the user, so it says what actually
happens rather than something vaguer.

One trap for anyone writing a probe for this: a `SceneTree` script cannot call
`play()` from `_initialize()` — the node is not inside the tree yet and the engine
refuses with *"Playback can only happen when a node is inside the scene tree"*.
Two measurement rounds were spent reading that as "the microphone produced
silence". `RecorderService` never hits it, being an autoload whose `_ready()` runs
in the tree.

### The pet as an assistant: it drives a coding-agent CLI

The pet's job is not to be an agent. It is to be the *face* of one: you tell it
what you want, it hands the work to `claude` or `codex`, and it tells you how it
went. Everything in this feature follows from that split — a speech bubble
filling up with tool calls has stopped being a pet, so the bubble gets one line
and `ui/work_panel.gd` gets everything else.

Three parts:

- `autoload/workspace_service.gd` — the folders the pet may touch, and the whole
  trust boundary. **It starts empty and nothing is ever inferred into it.** Also
  owns the git questions, since "what changed" and "is there unsaved work here"
  are the two things the rest of the feature has to ask.
- `autoload/work_service.gd` — launches the CLI and tails its progress.
- `ui/work_panel.gd` — the fourth window of the same shape as the memory,
  transcript and outbox panels, with the same useful side effect: nothing in it
  touches the pet window's passthrough mask.

#### Why a real allowlist, and why the level lives per folder

`OutboxService` needed no allowlist because it owns one folder that exists for
the pet; this points at the user's own projects, where the risk is not clutter
but their work. The machine this was built on has 85 directories under
`git_project/`, which is also why the 幫我做事 menu is a **submenu of
workspaces** rather than an item: "做事" always has a *where*, and picking it up
front is what stops the pet guessing.

`rejection_reason()` refuses the filesystem root, the home directory itself, and
**any path with a hidden component** — one rule that covers `~/.ssh`, `~/.gnupg`,
`~/.config`, `~/.codex` and `~/.claude` at once, and every future one, instead of
a list of names that rots. It returns a sentence rather than a bool because every
caller has a person waiting, and a refusal without a reason reads as a broken
feature.

Two levels, `read` and `edit`, per folder rather than global — a repo can be
demoted without being removed. There is deliberately no level above `edit`;
"and may also reach outside the folder" is not on offer.

#### claude vs codex: measured, and not equivalent

| | `codex exec` | `claude -p` |
|---|---|---|
| token-level streaming | **none** (one `item.completed`) | **yes** (`content_block_delta`) |
| redirected to a file | — | **flushes progressively** |
| sandbox | **OS-level** (`-s workspace-write`) | none; the agent's own discipline |
| session resume | — | `--session-id` / `--resume` |
| spend ceiling | — | `--max-budget-usd` |

The second row is what made this design possible at all. The no-pipes rule
`MakerService` established still holds — `FileAccess` reads on a pipe *block*,
and an undrained pipe stops the child ever exiting — but a regular file that
grows line by line can be **tailed by byte offset from `_process`**, which never
blocks. Measured: a 16-second job's stream file grew 21k → 45k in eight visible
steps. That is `CodexCli`'s device-code trick paying off much harder.

Split lines on the newline **byte**, never on a decoded string: a read can end
mid-character, and `0x0A` cannot occur inside a UTF-8 sequence, so a byte split
is the safe one. `_pending` holds the partial last line between polls.

The third row is the one to keep in mind before trusting either. Codex genuinely
confines writes to its `-C` root; Claude Code does not, and a shell command it
runs can reach anywhere the user can. The consent dialog says exactly that rather
than promising a containment that isn't there.

#### Four things that look like implementation detail and are not

- **`exec` in the launch command is load-bearing.** Without it the pid we keep is
  the shell's and the agent is its child, so 停下來 killed the shell and left the
  agent running — orphaned, still spending tokens, still able to write to the
  repository, its output going to a file nobody was reading. Measured exactly
  that way, then fixed by `cd … && exec claude …`, which is also verifiable:
  the agent's parent is now the Godot process itself.
- **`acceptEdits` does not cover Bash.** The first real run fixed the bug and was
  then refused when it tried to run the file to check itself —
  *"This command requires approval"*, to a terminal with nobody at it. An
  assistant that cannot verify its own work is worth far less than one that can,
  so `--allowed-tools` is passed explicitly rather than left to the mode to
  imply. Read-only workspaces instead restrict `--tools` to `Read,Grep,Glob`:
  enforcement by *capability*, since a job nobody is watching must never be
  sitting on a question.
- **The pet's jobs run on the project's configuration, never the user's.**
  Without `--strict-mcp-config --setting-sources project,local`, a one-line fix
  loaded whatever the user has installed globally — the measured run called
  `Skill(superpowers:systematic-debugging)` on a two-line file and cost $0.21;
  with them it used Read/Edit/Glob/Bash and cost $0.11. Personal hooks and MCP
  servers are the user's; a pet running errands must not be a way to fire them.
  The repo's own `CLAUDE.md` still applies, which is what makes the agent useful
  *in* a project rather than a stranger to it.
- **What changed comes from git, not from the agent's account of itself** — the
  same call `MakerService` made when it diffed the outbox rather than trusting
  `file_change` events. `changes()` drops `--stat`'s trailing summary line, which
  is a sentence *about* the list rather than a member of it and made a
  single-file change report as 「改了 2 項」, and adds untracked files by name,
  which `diff` alone never shows — an agent asked to add a file would otherwise
  report having changed nothing at all.

#### Two triggers, because the menu alone left it unreachable

The menu is a three-level walk (幫我做事 → a workspace → type). That is the right
shape when you know what you want, and it is useless when you just say the thing.
Asked 「這個專案在做什麼？stats.py 裡有沒有寫錯的地方？」 in ordinary chat, the pet
had **no path to the workspace at all**: `persona.md` told it flatly
「你看不到使用者電腦上的檔案」, so it reached for `[look]` instead, screenshotted
the desktop, and reported it couldn't see the file. Measured, on the user's own
first attempt.

So `[work]` joins `[look]` in the mood-tag slot, the same two-trigger shape the
screen look already proves. Three things this forces:

- **The workspace list is built per request** (`LLMService._work_block()`), never
  written into `prompts/persona.md`. Folders are added and removed while the app
  runs, and a persona loaded once at startup goes stale the moment they are. The
  block is empty when there is nothing to work in, so the persona's flat denial
  stands unmodified on a fresh install — it only became *untrue* once a workspace
  existed.
- **The tag carries the folder**, as `[work:名字]`, because an unnamed tag is only
  unambiguous when there is exactly one. `_resolve_space()` falls back to
  containment matching, since a model paraphrases a name it half-remembers.
- **Nothing launches from the tag.** Unlike a screenshot, this spends money and
  can edit files, so `pet.gd` puts it to the user first — quoting what they said
  and naming the folder and its level, because that dialog is the only place they
  can see what the model concluded before it acts. Accepting goes through
  `_begin_work`, so consent, the busy check, the login prompt and the
  uncommitted-work warning all still apply: a second way in, not a way around.

Measured after the change, `gpt-5.4-mini`, 6/6: all three workspace questions
produced `[work:pet-playground]`, a screen question still produced `[look]`, and
ordinary chat still produced a mood tag. The two triggers do not fight.

Backing out of a job has to answer the question anyway — the same repair
`answer_without_looking()` makes, and for the same reason. `_work_declined` and
cutting the 做事 section for that one turn are both needed: the persona tells the
model to answer such a request with nothing but the tag, and a small model
follows the character sheet over an appended footnote. That is exactly how the
`[look]` refusal path once ended up saying nothing at all.

`_abandon_pending_work()` is the single exit for every refusal. Besides speaking,
it clears `_pending_space` — or a later menu-driven job inherits it — and
`_queued_request`, or the next folder the user picks silently runs the sentence
they just abandoned.

#### Follow-ups carry on, per folder

Each job used to be a fresh `claude -p` with no memory, so 「不對，再改一下」 paid
to read the whole project again. The session id is in the `result` event this
already parses, so `WorkspaceService` keeps it **inside the workspace entry** and
the next job passes `--resume`.

Per workspace, not global: a session carries what the agent read and concluded,
and resuming it somewhere else answers questions about the wrong project. Living
in the entry also means removing the folder takes the session with it, with no
second table to keep in step. `set_session()` deliberately writes config without
going through `_store()` — a session id changing is not a change to the *list*,
and emitting `changed` would rebuild the menu and every panel row after each job.

Measured end to end: first round $0.06, follow-up 「那個要怎麼改？」 answered
「把第19行改成 `sorted(numbers)[-n:][::-1]`」 for **$0.0068 with no tool calls at
all** — it knew what 那個 referred to and did not re-read the file.

**A stale session has to be survivable.** Resuming one the CLI no longer has
fails instantly — exit 1, `is_error`, and **zero turns**, with
`No conversation found` only on stderr. That combination is what distinguishes
"the context is gone" from "the job failed", and without catching it a
cleaned-up session file would break that workspace permanently. `_launch()` is
split from `start()` so the retry can run with `allow_resume = false`, which is
also what stops it looping. Verified by pointing a workspace at a fabricated
uuid: the run failed, the session was dropped, the job re-ran and answered, and a
fresh id was stored — with only a line in the panel's log to show it happened.

The resume state is surfaced in the **input placeholder**
(「接著上次，要我在 X 做什麼？」) rather than as its own control: it is the one
moment the answer changes what is worth typing, and it costs no extra UI. Starting
over is a 重來 button on the workspace row, shown only when there is a session, so
the ordinary row stays two buttons wide.

Only claude resumes. `codex exec` has no equivalent on this path, which
`would_resume()` and `_launch()` both check rather than assume.

#### The guard that protects the level the user chose

Editing in place is the default because it was chosen deliberately, having been
shown what it means. The one thing standing between that and losing work git
cannot recover is `_setup_dirty_warning_dialog()`: asked **per job**, not per
folder, because the answer changes every time, and only where it means something
— an editable workspace, in a git repo, with something uncommitted in it. It is a
question with two named outcomes (我先去存 / 就這樣開始) rather than a notice,
because a warning you cannot act on is noise.

`dirty_count()` counts staged, unstaged and untracked alike: the question being
asked is "is there work here git cannot get back for you", and an untracked file
answers yes just as loudly as a modified one.

#### Things the pet has to say, and when

- `_on_work_submitted` speaks *before* the job starts. The result lands minutes
  later, and without a line up front the pet just walks off mid-job.
- `_on_work_progress` carries the occasional 還在弄 line, driven off the progress
  signal rather than a timer of its own — steps arrive continuously, so it needs
  no new process loop. It is left `unprompted`, unlike everything else in this
  flow: a "still working" line has nothing worth talking over a reply or an open
  input, which is exactly the case that guard exists for.
- **`_on_pet_nudged` takes `unprompted`, and it is a different question from
  `record`.** A line answering something the user just asked for has to appear
  even while the input is open — and this flow *opens the input itself*, so
  everything in it passes `false, false`. Other direct responses still routed
  through the default (餵食, the API-key confirmation, the game score,
  好啦那我不看) have the same latent hole.

Cancelling reports the damage. Stopping half way is not the same as nothing
having happened, and an agent cancelled after rewriting three files that said
only 「好，我停下來了」 would be the most misleading thing this service could say.

Windows reports unsupported, like `PresenceService` does and for the same kind of
reason: the launcher is `/bin/sh`, and neither CLI is realistically installed
there for this purpose. Disabled in the menu rather than hidden.

There is still no OAuth anywhere in this. `codex login` and `claude` each handle
their own, and `~/.codex/auth.json` is the CLI's own file which nothing in this
repo reads — the same shape as `SecretStore` shelling out to `security` /
`secret-tool` / `powershell`. Forging a vendor client id to spend subscription
entitlement remains out of bounds, as it was before.

**Never inherit `~/.codex/config.toml`.** It pins whatever model the user last
chose for their own work, and a stale one is rejected outright with an error that
reads as an account problem — *"not supported when using Codex with a ChatGPT
account"* — with no visible connection to the pet. `WorkService.CODEX_MODEL` is
passed with `-m` every time, and the id is not guessable: there is no plain
`gpt-5.6`; that generation is `-sol` / `-luna` / `-terra`. Claude's is the
opposite case — `CLAUDE_MODEL` is the alias `sonnet`, because the CLI resolves it
to the current model and a pinned id silently rots.

Because both go through a shell, the request is quoted with `_sh_quote()` —
single quotes with any embedded quote closed and reopened, the same discipline
`SecretStore._ps_literal()` applies to PowerShell. Note the redirection targets
have to be quoted **whole**: `2>%s.err % _sh_quote(path)` produces
`2>'/…/stream.jsonl'.err`, which is a different filename the moment the path
contains anything worth quoting.

### Logging Codex in, from inside the pet

`autoload/codex_cli.gd` owns the account: where the binary is, whether it has
one, and how to give it one. **No OAuth is implemented here and no token is ever
read** — both routes launch the vendor's own `codex login`, and
`~/.codex/auth.json` is the CLI's file that nothing in this repo opens. That is
the same line drawn above; forging the Codex client id remains out of bounds and
none of this comes near it.

Two routes, because they answer different questions, and the menu entry stays
*enabled* without an account — having the CLI and having an account are separate
failures and only the second one is recoverable by asking.

- **`--with-api-key`, over stdin.** Uses the key this app may already be holding.
  No browser, no interaction. The key goes over stdin and never argv, for the
  reason `SecretStore` pipes secrets: `ps` shows another process's arguments to
  anything running as the same user. Bills the API rather than the subscription.
- **`--device-auth`, not the default localhost flow.** The default binds
  `localhost:1455` and opens a browser *on this machine* — exactly the assumption
  that fails on the remote and headless desktops a pet like this sits on, and the
  CLI says so in its own output. Device auth produces a short URL and nine
  characters, which is something a speech bubble can carry where a 400-character
  OAuth URL is not. The one thing the default did for free was open the browser,
  so `_look_for_code()` does that itself once the URL is known, and puts the code
  on the clipboard as well as saying it.

Four things worth knowing before editing it:

- **The device code is parsed out of a regular file, never a pipe** — the same
  rule the work path follows, and here it is what makes the code reachable at
  all.
- **The CLI colourises even when stdout is a file**, so the escapes have to be
  stripped before matching. Write that pattern as `\x1b`: Godot's RegEx is
  **PCRE2, which rejects `\u`**, and an invalid pattern is not loud — `sub()`
  returns an empty string, so the code is simply never found and the pet says
  nothing while the login sits there. Compile it once; this runs on a timer.
- `is_logged_in()` is cached. `codex login status` costs 60-90ms, which is a
  visible hitch every time the menu is built. Every login attempt drops the
  cache; the only thing it can go stale against is a login made outside the app.
- Both this and `WorkService` kill their child in `_exit_tree()`.
  `OS.create_process` children outlive the app, and an abandoned `codex login`
  keeps holding its port, so the next attempt would fail to bind with nothing on
  screen explaining why. `WorkService`'s case is worse — see the `exec` note
  above, without which the pid being killed isn't even the right process.

The login dialog's primary button gets `primary_button_styles`, not the ghost
treatment. Ghosting it made both routes read as equally optional and the main one
look disabled — the same mistake `ChatLogPanel`'s 關閉 button already records.

### The Codex sandbox needs help on Ubuntu 24.04

`codex exec -s workspace-write` builds its sandbox with bubblewrap, and Ubuntu
24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1` while shipping a
`/usr/bin/bwrap` that is **not** setuid. Every write therefore failed with
`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`, which the agent
reported as a vague 「工作區沙箱發生權限錯誤」 after retrying four times — 50
seconds and ~150k input tokens for nothing.

The fix is an AppArmor profile at `/etc/apparmor.d/bwrap`: a *named* profile with
`flags=(unconfined)` and `userns,`, copied from Ubuntu's own
`/etc/apparmor.d/flatpak`. It is much narrower than the other common answer
(`sysctl kernel.apparmor_restrict_unprivileged_userns=0`, which is machine-wide),
though it does restore the capability for anything that invokes bwrap.

Confirmed afterwards that the sandbox still *confines*, which is the part worth
re-checking after any change here: asked to write outside its `-C` root, the
agent refuses and no file appears. Note `/tmp` is writable in `workspace-write`
mode as well as the root — that is the CLI's default, not something granted here.
