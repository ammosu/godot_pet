extends Node
## Global signal bus. Systems talk through here instead of holding references to
## each other, so the brain / LLM / visuals / window can each be replaced alone.
##
## Rule: emit from the system that owns the fact, connect from whoever cares.
## Never call across systems directly.

# --- Interaction (Phase 1) ---
## The pet was grabbed / released by the user.
signal pet_grabbed
signal pet_released
## The pet was clicked without being dragged.
signal pet_tapped

# --- Window (Phase 1) ---
## Pet centre moved to a new absolute screen position.
signal pet_moved(screen_position: Vector2i)

# --- Conversation (Phase 3+, declared early so listeners can be wired) ---
signal user_said(text: String)
signal reply_chunk(text: String)
signal reply_finished(full_text: String)
signal reply_failed(message: String)

# --- Expression (Phase 5+) ---
signal emotion_changed(emotion: String)
signal action_requested(action: String)

# --- Needs (Phase 6+) ---
signal state_tick(state: Dictionary)
## What the brain is currently doing: idle / walk / sleep / drag / talk.
signal pet_activity_changed(activity: StringName)
## The pet started a conversation on its own. Not an LLM reply — see nudger.gd.
signal pet_nudged(emotion: String, text: String)

# --- Screen ---
## The pet wants to look at the screen. Nothing is captured until the user says
## yes; pet.gd owns that decision.
signal screen_look_requested(question: String, record_question: bool)

# --- Files ---
## A file was dropped somewhere on the window; `at` is in window-local
## (viewport) pixels. Window.files_dropped ignores the mouse-passthrough
## mask entirely — it rides on the OS's native drag-and-drop target
## registration, a separate mechanism from the click hit-testing that mask
## shapes — so this can fire from anywhere in the window's mostly
## transparent, overhanging rect. Whoever connects has to hit-test against
## the part that's actually the pet.
signal files_dropped_on_window(files: PackedStringArray, at: Vector2)

## A dropped file's content, already read/classified/truncated by
## FileDropService, phrased as if the user had typed it. A dedicated signal
## rather than reusing `user_said`: LLMService's listener on that one also
## runs the local screen-look phrase match, which a dropped file's own
## content — or even just its name, e.g. a screen recording literally named
## "我的螢幕錄影.mp4" — can trip by accident (this project's own PLAN.md and
## CLAUDE.md contain "我在幹嘛" and "螢幕上" verbatim). TTSService and
## PetState still want the ordinary user_said reaction (stop speaking, count
## as an interaction), so they connect their existing handlers to this too.
signal file_content_said(text: String)

# --- Presence (rhythm-based nudging) ---
## The foreground app was resampled. `app_name` is an opaque per-platform
## identifier — WM_CLASS's class field on Linux, the process name on macOS —
## never a window title, and empty when this poll (or the platform) couldn't
## answer. `seconds_in_app` is how long the current one has held focus.
## Nothing carried here may be logged or written to disk; see
## PresenceService for the consent gate.
signal presence_sampled(app_name: String, seconds_in_app: float)

# --- Machine load ---
## A resource scan completed. The dictionary is MonitorService's whole sample —
## machine CPU and memory plus the two top-N process rankings — and exists so
## MonitorPanel can redraw without polling. Local only: nothing carried here is
## written to disk or sent anywhere.
signal resources_sampled(sample: Dictionary)

## A scan crossed one of MonitorService's thresholds. `kind` is one of its
## ALERT_* constants and `detail` carries the numbers behind it. Deliberately not
## a finished sentence: pet.gd owns how the pet reacts to anything, the same
## split the mini-game scores and the work results already use.
signal resource_alert(kind: String, detail: Dictionary)

# --- Work ---
## The model decided the user is asking for something to be *done* in one of the
## pet's workspaces rather than answered in the bubble. `space_name` is whatever
## the model named, empty when it didn't (which is fine when there is only one).
## pet.gd owns what happens next — nothing launches from here.
signal work_requested(space_name: String, request: String)

## A recording the user wants the pet to speak in. Carries a real filesystem
## path; `pet.gd` asks what to call it before anything is cloned.
signal voice_offered(wav_path: String)
