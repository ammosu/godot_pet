extends Node

var _failures := 0
var _checks := 0
## Which tests reached their last line. **Counting checks is not enough:** a
## runtime error inside a test aborts that function, `_ready()` carries straight
## on to the next one, and the tally then reports only the checks that happened
## to run. Measured in the sibling suite — a call to a method deleted an hour
## earlier printed 「13 checks passed」 and exited 0, with seven checks never
## reached. GDScript gives no way to catch that from inside, so each test says it
## finished and this notices when one did not.
var _finished: Array[String] = []


func _ready() -> void:
	var tests := {
		"hit region": _test_cursor_hit_region,
		"reaction gate": _test_hover_reaction_gate,
		"pack actions": _test_default_pack_actions,
	}
	for name: String in tests:
		(tests[name] as Callable).call()

	for name: String in tests:
		if not _finished.has(name):
			_failures += 1
			push_error("PetVisual: the '%s' test did not run to the end — look for "
				% name + "a SCRIPT ERROR above; its later checks never happened")

	if _failures == 0:
		print("PetVisual cursor interactions: %d checks passed, all %d tests ran to the end"
			% [_checks, tests.size()])
	else:
		push_error("PetVisual cursor interactions: %d failed, %d checks ran, %d/%d tests completed"
			% [_failures, _checks, _finished.size(), tests.size()])
	get_tree().quit(1 if _failures > 0 else 0)


## Last line of every test. Anything that stops the function short of this —
## including an engine-level error GDScript will not let us catch — is reported.
func _done(name: String) -> void:
	_finished.append(name)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	push_error(message)


func _test_cursor_hit_region() -> void:
	var body := PackedVector2Array([
		Vector2(-40, -80), Vector2(40, -80),
		Vector2(40, 80), Vector2(-40, 80),
	])
	_expect(PetVisual.cursor_over_polygon(Vector2(0, -50), body),
		"cursor over the upper body was not recognised as friendly contact")
	_expect(PetVisual.cursor_over_polygon(Vector2(30, 20), body),
		"cursor over the side of the body was not recognised")
	_expect(not PetVisual.cursor_over_polygon(Vector2(0, -100), body),
		"cursor outside the body suppressed directional look art")
	_done("hit region")

func _test_hover_reaction_gate() -> void:
	_expect(not PetVisual.hover_reaction_ready(
		PetVisual.HOVER_REACTION_TRAVEL - 1.0, 0.0, false),
		"short cursor movement triggered a full animation")
	_expect(not PetVisual.hover_reaction_ready(
		PetVisual.HOVER_REACTION_TRAVEL, 0.1, false),
		"hover cooldown was ignored")
	_expect(not PetVisual.hover_reaction_ready(
		PetVisual.HOVER_REACTION_TRAVEL, 0.0, true),
		"an active reaction was interrupted by another")
	_expect(PetVisual.hover_reaction_ready(
		PetVisual.HOVER_REACTION_TRAVEL, 0.0, false),
		"enough cursor movement did not trigger an available reaction")
	_done("reaction gate")

func _test_default_pack_actions() -> void:
	var pack := PetPack.load_builtin()
	_expect(pack != null and pack.id == PetVisual.FRIENDLY_HOVER_PET_ID,
		"friendly hover is not scoped to the bundled default pet")
	_expect(pack != null and pack.has_row(PetVisual.V2_STATE_ROWS[&"wave"]),
		"bundled pet has no wave row for hover reactions")
	if pack == null:
		return

	var visual := PetVisual.new()
	var sprite := AnimatedSprite2D.new()
	sprite.name = "Sprite"
	visual.add_child(sprite)
	var fallback := FallbackBlob.new()
	fallback.name = "Fallback"
	visual.add_child(fallback)
	var label := Label.new()
	label.name = "CalibrationLabel"
	visual.add_child(label)
	add_child(visual)
	visual.load_pack(pack)

	visual._update_hover_interaction(Vector2.ZERO, true, 0.0)
	visual._update_hover_interaction(Vector2(PetVisual.HOVER_REACTION_TRAVEL, 0), true, 0.0)
	_expect(sprite.animation == PetPack.row_anim(PetVisual.V2_STATE_ROWS[&"wave"]),
		"first friendly hover reaction did not play the wave row")
	visual._hover_reaction_timer = 0.0
	visual._hover_cooldown = 0.0
	visual._update_hover_interaction(
		Vector2(PetVisual.HOVER_REACTION_TRAVEL * 2.0, 0), true, 0.0)
	_expect(sprite.animation == PetPack.row_anim(PetVisual.V2_STATE_ROWS[&"idle"]),
		"position-only hop did not keep the full-size idle artwork")
	visual._update_hover_interaction(
		Vector2(PetVisual.HOVER_REACTION_TRAVEL * 2.0, 0), true,
		PetVisual.HOVER_REACTION_SECONDS[PetVisual.HOVER_HOP_REACTION] * 0.5)
	visual._apply_pose()
	_expect(visual._hover_hop < 0.0, "position-only hop did not lift the pet")
	_expect(sprite.scale.is_equal_approx(Vector2.ONE),
		"position-only hop changed the pet's rendered size")
	visual.queue_free()
	_done("pack actions")

