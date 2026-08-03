extends Node

var _failures := 0
var _checks := 0


func _ready() -> void:
	_test_cursor_hit_region()
	_test_hover_reaction_gate()
	_test_default_pack_actions()
	if _failures == 0:
		print("PetVisual cursor interactions: %d checks passed" % _checks)
	else:
		push_error("PetVisual cursor interactions: %d of %d checks failed" % [_failures, _checks])
	get_tree().quit(_failures)


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
