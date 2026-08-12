extends Node

## Who needs the frame rate up, and how much of it.
##
## `Engine.max_fps` is one number for the whole process, but this app is many
## windows sharing one main loop — the pet, the panels, the mini-games and every
## settings dialog. One low cap makes the pet cheap and the games unplayable; one
## high cap is what this costs the rest of the desktop. So callers state a
## requirement, and the highest one in force wins.
##
## Why the pet's idle number is 6 and not 12: every frame this window presents
## makes the compositor recomposite the screen under it, and the penalty falls off
## a cliff between the two. Measured on Ubuntu 24.04 / X11 / GNOME, opening a
## 238-item folder against 3.50 s with no pet running at all — 60 fps costs
## +4.77 s, 30 fps +4.33 s, 12 fps still +3.38 s, and 6 fps +0.39 s. Going from 60
## down to 12 buys back 29% of it; the last step, 12 to 6, buys the other 88%.
##
## It is not free: the idle row is six frames over 1.10 s and two of them last
## 0.110 s, which does not fit a 0.167 s interval, so those two are dropped. That
## trade is the reason this is a table rather than a constant — nothing else pays
## it. See `docs/desktop-compositor-cost.md` for the measurements and for the
## three things that turned out **not** to matter (window area, walking, and
## `low_processor_mode`).

## What the pet itself needs, by the logical state `PetBrain` emits.
const STATE_FPS := {
	&"idle": 6,
	&"sleep": 3,
	## Walking is the expensive one, and unlike the three below it is the pet's
	## own decision — so it happens while you are opening that folder, at +4.33 s
	## a time. Lowering it needs the walk to advance in sprite-frame steps rather
	## than every frame; until then this buys smoothness at a known price.
	&"walk": 30,
	## DRAG, SETTLE and TALK are entered because the user is handling the pet, and
	## someone dragging the pet is not simultaneously waiting for a folder to
	## open. They spend a cost nobody is there to pay.
	&"drag": 60,
	&"settle": 60,
	&"talk": 30,
}

## `Mode.AMBIENT` emits whatever StringName the skin's `companion.json` chose, so
## this fallback is that path's ordinary route rather than a guard against typos.
## It is deliberately conservative: those are sprite loops running at 9 fps at most.
const DEFAULT_STATE_FPS := 30

## Any auxiliary window that is open. Scrolling a transcript at 6 fps reads as a
## broken app, and these are only on screen while somebody is looking at them.
const PANEL_FPS := 30

## The mini-games are played with the arrow keys and have to feel like games.
const GAME_FPS := 60

var _wants := {}


func _ready() -> void:
	EventBus.pet_activity_changed.connect(_on_pet_activity)


## State a requirement under `key`. Calling again with the same key replaces that
## requirement rather than stacking a second one, so a caller whose needs change
## (a panel that starts a game) does not have to release first.
func request(key: StringName, fps: int) -> void:
	if _wants.get(key, -1) == fps:
		return
	_wants[key] = fps
	_apply()


func release(key: StringName) -> void:
	if not _wants.erase(key):
		return
	_apply()


## The requirement in force, or 0 when nobody has asked for anything yet.
func current() -> int:
	var top := 0
	for fps: int in _wants.values():
		top = maxi(top, fps)
	return top


func _apply() -> void:
	var top := current()
	# With an empty table, leave whatever `project.godot` set. Inventing a number
	# here would mean this file quietly owned the startup frame rate too, and the
	# pet's first state arrives within a second of launch anyway.
	if top > 0:
		Engine.max_fps = top


func _on_pet_activity(activity: StringName) -> void:
	request(&"pet", int(STATE_FPS.get(activity, DEFAULT_STATE_FPS)))
