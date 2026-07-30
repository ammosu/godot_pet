extends Node2D
class_name FallbackBlob

## Emergency face, drawn procedurally so the app still starts if both a selected
## community pack and the bundled default pack fail to load.
##
## Named so the mini-game can use the same emergency body when no pack loaded.

@export var radius: float = 56.0
@export var body_color: Color = Color("7ec8f0")
@export var outline_color: Color = Color("2b4a5c")

const BLINK_PERIOD := 4.0
const BLINK_LENGTH := 0.12

var _t: float = 0.0
var _squash: float = 0.0


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	var breathe := sin(_t * 2.2) * 0.04 + _squash
	var rx := radius * (1.0 + breathe)
	var ry := radius * (1.0 - breathe)

	for side in [-1.0, 1.0]:
		var ear := PackedVector2Array([
			Vector2(side * rx * 0.62, -ry * 1.18),
			Vector2(side * rx * 0.16, -ry * 0.80),
			Vector2(side * rx * 0.94, -ry * 0.48),
		])
		draw_colored_polygon(ear, body_color)

	_draw_ellipse(Vector2.ZERO, rx, ry, body_color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(rx / radius, ry / radius))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, outline_color, 3.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var lid := 0.1 if fmod(_t, BLINK_PERIOD) < BLINK_LENGTH else 1.0
	for side in [-1.0, 1.0]:
		_draw_ellipse(Vector2(side * rx * 0.33, -ry * 0.10), 8.0, 8.0 * lid, outline_color)

	draw_arc(Vector2(0.0, ry * 0.18), 15.0, PI * 0.18, PI * 0.82, 16, outline_color, 3.0, true)


func _draw_ellipse(centre: Vector2, rx: float, ry: float, color: Color) -> void:
	draw_set_transform(centre, 0.0, Vector2(rx, ry))
	draw_circle(Vector2.ZERO, 1.0, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Region that should catch mouse clicks, in this node's local space.
## Generous enough to cover the ears and the breathing wobble.
func get_hit_polygon(segments: int = 20) -> PackedVector2Array:
	var points := PackedVector2Array()
	var r := radius * 1.3
	for i in segments:
		var a := TAU * float(i) / float(segments)
		points.append(Vector2(cos(a), sin(a)) * r)
	return points


## Called by the brain when the pet is grabbed/dropped, for a bit of life.
func set_squash(amount: float) -> void:
	_squash = clampf(amount, -0.2, 0.2)
