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
