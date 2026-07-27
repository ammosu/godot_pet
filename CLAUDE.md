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
```

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
- `autoload/pet_state.gd` — needs; `autoload/nudger.gd` — unprompted lines.

### Coordinates and DPI

**Viewport pixels are 1:1 with window pixels, and this must stay true.**
`DisplayServer.window_set_mouse_passthrough()` takes window pixels, and
`Window.size` / `screen_get_usable_rect()` / `screen_get_position()` are all
*physical* pixels (a 2940-wide Retina screen reports 2940).

So the window is sized as `BASE_SIZE * screen_get_scale()` and the visual node
is scaled to match. Do **not** introduce `Window.content_scale_factor` or
`content_scale_mode`: they decouple viewport coordinates from window pixels and
silently misplace the click-through mask.

Anything measured in design units gets multiplied by
`WindowController.get_ui_scale()` at the point of use. That includes UI theme
constants — popups and controls are laid out in physical pixels, so on Retina
the default theme renders at half size unless its font sizes and spacings are
scaled (see `_scale_menu_theme` in `pet/pet.gd`).

### The window deliberately hangs off the screen

The window is much larger than the pet (it reserves room for the bubble above
and the input below), and is allowed to overhang the desktop edge so the pet
itself can reach the corner. Three consequences:

- Screen-edge clamping uses `set_content_bounds()` — the *visible pet* — not the
  window rect. This is kept separate from `set_hit_region()`, which grows to
  cover chat UI and would otherwise drag the pet away from the edge.
- Chat UI must be clamped to `WindowController.get_visible_area()`, the slice of
  the window actually on screen. Clamping position alone is not enough: the
  speech bubble also narrows when that slice is thinner than its natural width.
- `get_visible_area()` changes as the pet walks, so `EventBus.pet_moved` must be
  connected **before** `park_at_default_spot()` runs in `_ready()`.

### Sprite packs

Art is the Codex Pets / petdex format, loaded at runtime from
`~/.codex/pets/{id}/` (installed by `npx codex-pets add <id>`): `pet.json` plus
an 8x9 grid of 192x208 cells, one animation state per row.

**No artwork ships in this repo, ever.** The format and tooling are MIT but the
packs are not — originals default to CC BY-NC-SA and fan works of third-party
characters are personal, non-commercial use only. Reading packs from the user's
own install keeps licensing between them and the pet's author.

The manifest declares neither frame counts nor row semantics:

- Frame counts are detected by scanning each row for its first blank cell.
- Row meanings are a built-in guess in `PetVisual.DEFAULT_STATE_ROWS`, read off a
  real sheet rather than any spec, overridable per pet via a `[pet_rows]`
  section in `config.cfg`. The right-click menu has a calibration mode that
  cycles rows with their index on screen. No pack seen so far has a genuine
  sleep animation.
- Anything positioning the pet against a screen edge, or sizing its click box,
  must measure the **idle row** (`rect_for_row`), not the whole-sheet union —
  action frames fling limbs and props far outside the resting silhouette.

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

Secrets come from `Config.get_secret()`: process environment, then `.env` beside
the project or executable, then `config.cfg`. Never logged.

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

## Tuning without code changes

`prompts/persona.md` (character and reply format), `prompts/nudges.json`
(unprompted lines), and the `DECAY` / `STARTING` constants in
`autoload/pet_state.gd`. Prompt files take effect on restart.
