# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Godot 4.7 desktop pet for macOS: a transparent, always-on-top, click-through
window holding an animated character you can chat with via an LLM.

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
  when one of those lines is worth saying.
- `autoload/file_drop_service.gd` — turns a file dropped on the pet into a turn.
- `ui/style.gd` (`PetStyle`) — every colour and edge, and the builders for the
  themes. See below.
- `ui/chat_panel.gd` — speech bubble and chat input;
  `ui/memory_panel.gd` — the window listing what the pet remembers.

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

Art is the Codex Pets / petdex format, loaded at runtime from
`~/.codex/pets/{id}/` (installed by `npx codex-pets add <id>`): `pet.json` plus
8 columns of 192x208 cells, one animation state per row.

**No artwork ships in this repo, ever.** The format and tooling are MIT but the
packs are not — originals default to CC BY-NC-SA and fan works of third-party
characters are personal, non-commercial use only. Reading packs from the user's
own install keeps licensing between them and the pet's author.

The manifest declares neither the grid, nor frame counts, nor row semantics:

- **The row count is measured, never assumed.** The format grew: original sheets
  are 9 rows, `spriteVersionNumber: 2` packs are 11, and nothing in `pet.json`
  says which. `_cell_size_for()` derives the cell from the width and the 192:208
  ratio, then divides the height by it. A hard-coded 9 made the divisibility
  check reject every v2 pack outright — with the pet silently falling back to the
  procedural blob, which reads as "the download didn't work".
- Frame counts are detected by scanning each row for its first blank cell.
- Row meanings are a built-in guess in `PetVisual.DEFAULT_STATE_ROWS`, read off a
  real sheet rather than any spec, overridable per pet via a `[pet_rows]`
  section in `config.cfg`. The right-click menu has a calibration mode that
  cycles rows with their index on screen. No pack seen so far has a genuine
  sleep animation.
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

### Every pose channel goes through `_apply_pose()`

Four separate things move the sprite now: which way it faces, the lean and perk
it does when the cursor comes near, the squash of being held or tapped, and the
lean of a body still catching up with the grab point. They used to be written
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

The fact-extraction prompt has to explicitly exclude speculation and
soon-stale details, or facts fill up with "probably still has concurrency risk"
and "had four meetings today".

### Speech

`autoload/tts_service.gd` uses `DisplayServer.tts_speak()` — the OS voices, so
no API and no cost. Sentences are spoken as they stream in rather than after the
reply completes; `tts_speak` queues rather than interrupting, so consecutive
sentences run together on their own.

Voice languages are reported as BCP 47 with a **hyphen** (`zh-TW`), while
`OS.get_locale()` uses an underscore (`zh_TW`), and
`tts_get_voices_for_language()` matches on a plain prefix. An underscore
silently matches nothing and the fallback then picks whichever voice happens to
be first in a 180-entry list — which will read Chinese in an English voice on
most machines.

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
(unprompted lines, including the `{fact}` templates in the `memory` pool), and
the `DECAY` / `STARTING` constants in `autoload/pet_state.gd`. Prompt files take
effect on restart.

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
