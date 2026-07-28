extends RefCounted
class_name GameArt

## The things the games draw that aren't the pet.
##
## Eight shapes, drawn procedurally, shared by every game — 接東西 drops five of
## them, 跳過去 puts two on the ground and in the air, and 翻翻看 needs all eight
## as faces to tell apart. No artwork ships with this project (see
## pets/pet_pack.gd for why), and these would not be worth shipping if it did.
##
## Every one of them is **background-independent**: no shape punches a hole
## using the colour of what it happens to be sitting on. The same donut is drawn
## on the near-black field in one game and on a paper card in another, and the
## first version — which filled the hole with the field colour — left a dark
## smudge on the card. Rings are drawn as arcs, and eyes use GAME_ITEM_INK.
##
## Static, and passed the CanvasItem to draw into: these are called from inside
## somebody else's _draw(), which is the only place the draw_* calls are legal.

enum Item { RICE, APPLE, FISH, STAR, CHILLI, DONUT, MUSHROOM, HEART, CLOUD, LEAF }

## Everything, in the order 翻翻看 takes faces from. The first five are what
## 接東西 uses, so a player meets them in the simplest game first.
##
## Ten, not eight, because 翻翻看's largest board is ten pairs — and a face that
## has to repeat produces four identical cards, which is *easier*, not harder,
## since any two of them match.
const ALL: Array[int] = [
	Item.RICE, Item.APPLE, Item.FISH, Item.STAR, Item.CHILLI,
	Item.DONUT, Item.MUSHROOM, Item.HEART, Item.CLOUD, Item.LEAF,
]


static func draw_item(on: CanvasItem, kind: int, c: Vector2, r: float) -> void:
	match kind:
		Item.RICE:
			_rice(on, c, r)
		Item.APPLE:
			_apple(on, c, r)
		Item.FISH:
			_fish(on, c, r)
		Item.STAR:
			_star(on, c, r)
		Item.CHILLI:
			_chilli(on, c, r)
		Item.DONUT:
			_donut(on, c, r)
		Item.MUSHROOM:
			_mushroom(on, c, r)
		Item.HEART:
			_heart(on, c, r)
		Item.CLOUD:
			_cloud(on, c, r)
		Item.LEAF:
			_leaf(on, c, r)


## 飯糰. The clearest silhouette of the lot at 30px — a triangle is readable at a
## glance in a way a small blob never is.
static func _rice(on: CanvasItem, c: Vector2, r: float) -> void:
	on.draw_colored_polygon(PackedVector2Array([
		c + Vector2(0.0, -r),
		c + Vector2(r * 0.92, r * 0.72),
		c + Vector2(-r * 0.92, r * 0.72),
	]), PetStyle.GAME_RICE)
	on.draw_rect(Rect2(c.x - r * 0.40, c.y + r * 0.16, r * 0.80, r * 0.56),
		PetStyle.GAME_NORI)


static func _apple(on: CanvasItem, c: Vector2, r: float) -> void:
	on.draw_circle(c + Vector2(0.0, r * 0.08), r * 0.88, PetStyle.GAME_APPLE)
	on.draw_line(c + Vector2(0.0, -r * 0.70), c + Vector2(r * 0.14, -r * 1.14),
		PetStyle.GAME_STEM, maxf(1.0, r * 0.13))
	on.draw_colored_polygon(PackedVector2Array([
		c + Vector2(r * 0.06, -r * 0.86),
		c + Vector2(r * 0.62, -r * 1.04),
		c + Vector2(r * 0.24, -r * 0.58),
	]), PetStyle.GAME_APPLE.lightened(0.20))


static func _fish(on: CanvasItem, c: Vector2, r: float) -> void:
	on.draw_colored_polygon(PackedVector2Array([
		c + Vector2(-r * 0.62, 0.0),
		c + Vector2(-r * 1.20, -r * 0.56),
		c + Vector2(-r * 1.20, r * 0.56),
	]), PetStyle.GAME_FISH)
	_ellipse(on, c, r * 0.92, r * 0.60, PetStyle.GAME_FISH)
	on.draw_circle(c + Vector2(r * 0.40, -r * 0.14), maxf(1.0, r * 0.12),
		PetStyle.GAME_ITEM_INK)


static func _star(on: CanvasItem, c: Vector2, r: float) -> void:
	var points := PackedVector2Array()
	for i in 10:
		var angle := -PI * 0.5 + TAU * float(i) / 10.0
		points.append(c + Vector2(cos(angle), sin(angle)) * (r if i % 2 == 0 else r * 0.44))
	on.draw_colored_polygon(points, PetStyle.GAME_STAR)


## 辣椒 — the only red anywhere in these games, and in both of the ones that use
## it the rule is the same: this is the thing you don't want. Bent away from its
## stem rather than symmetric, which is the whole difference between reading as a
## chilli and reading as a seed.
static func _chilli(on: CanvasItem, c: Vector2, r: float) -> void:
	var top := c + Vector2(-r * 0.22, -r * 0.72)
	var tip := c + Vector2(r * 0.40, r * 1.00)
	var steps := 12
	var points := PackedVector2Array()
	for i in steps + 1:
		points.append(_chilli_edge(top, tip, float(i) / float(steps), r, 1.0))
	# Back up the other side, skipping both ends — they are already in, and a
	# repeated vertex is the one thing polygon triangulation dislikes.
	for i in range(steps - 1, 0, -1):
		points.append(_chilli_edge(top, tip, float(i) / float(steps), r, -1.0))
	on.draw_colored_polygon(points, PetStyle.GAME_CHILLI)
	on.draw_line(top, top + Vector2(-r * 0.24, -r * 0.44),
		PetStyle.GAME_CHILLI_STEM, maxf(1.5, r * 0.18))


static func _chilli_edge(top: Vector2, tip: Vector2, t: float, r: float,
		side: float) -> Vector2:
	var spine := top.lerp(tip, t)
	var width := sin(t * PI) * r * 0.44 * (1.0 - t * 0.45)
	return spine + Vector2(width, -width * 0.30) * side


## A ring rather than a filled circle with a hole cut in it, so it carries no
## assumption about what is behind it. Also the only shape here with a hole at
## all, which is most of why it is easy to tell from the apple.
static func _donut(on: CanvasItem, c: Vector2, r: float) -> void:
	var band := r * 0.36
	on.draw_arc(c, r * 0.66, 0.0, TAU, 28, PetStyle.GAME_DONUT, band, true)


static func _mushroom(on: CanvasItem, c: Vector2, r: float) -> void:
	on.draw_rect(Rect2(c.x - r * 0.26, c.y - r * 0.10, r * 0.52, r * 0.92),
		PetStyle.GAME_MUSHROOM_STEM)
	# A half-disc: draw the dome, then take the bottom half back off by drawing
	# the cap as a polygon fan across its own diameter.
	var cap := PackedVector2Array()
	var steps := 16
	for i in steps + 1:
		var angle := PI + PI * float(i) / float(steps)
		cap.append(c + Vector2(cos(angle) * r * 0.98, sin(angle) * r * 0.80) + Vector2(0.0, -r * 0.06))
	on.draw_colored_polygon(cap, PetStyle.GAME_MUSHROOM)
	on.draw_circle(c + Vector2(-r * 0.28, -r * 0.40), maxf(1.0, r * 0.14),
		PetStyle.GAME_MUSHROOM_STEM)
	on.draw_circle(c + Vector2(r * 0.30, -r * 0.52), maxf(1.0, r * 0.11),
		PetStyle.GAME_MUSHROOM_STEM)


static func _heart(on: CanvasItem, c: Vector2, r: float) -> void:
	var lobe := r * 0.46
	var top := c.y - r * 0.28
	on.draw_circle(Vector2(c.x - lobe * 0.86, top), lobe, PetStyle.GAME_HEART)
	on.draw_circle(Vector2(c.x + lobe * 0.86, top), lobe, PetStyle.GAME_HEART)
	on.draw_colored_polygon(PackedVector2Array([
		Vector2(c.x - lobe * 1.72, top),
		Vector2(c.x + lobe * 1.72, top),
		Vector2(c.x, c.y + r * 0.94),
	]), PetStyle.GAME_HEART)


## Three overlapping discs on a flat base. The only silhouette here with a
## bumpy top, which is what makes it findable at a glance among nine others.
static func _cloud(on: CanvasItem, c: Vector2, r: float) -> void:
	on.draw_circle(c + Vector2(-r * 0.50, r * 0.10), r * 0.46, PetStyle.GAME_CLOUD)
	on.draw_circle(c + Vector2(r * 0.50, r * 0.12), r * 0.42, PetStyle.GAME_CLOUD)
	on.draw_circle(c + Vector2(0.0, -r * 0.16), r * 0.62, PetStyle.GAME_CLOUD)
	on.draw_rect(Rect2(c.x - r * 0.92, c.y + r * 0.10, r * 1.84, r * 0.42),
		PetStyle.GAME_CLOUD)


## A pointed oval with a vein down it. Deliberately a much darker green than the
## apple — the shapes are already unmistakable, but the two would otherwise be
## the only pair on the board that also share a colour.
static func _leaf(on: CanvasItem, c: Vector2, r: float) -> void:
	var tip := c + Vector2(r * 0.62, -r * 0.86)
	var base := c + Vector2(-r * 0.62, r * 0.86)
	var steps := 10
	var points := PackedVector2Array()
	for i in steps + 1:
		points.append(_leaf_edge(tip, base, float(i) / float(steps), r, 1.0))
	for i in range(steps - 1, 0, -1):
		points.append(_leaf_edge(tip, base, float(i) / float(steps), r, -1.0))
	on.draw_colored_polygon(points, PetStyle.GAME_LEAF)
	on.draw_line(tip, base, PetStyle.GAME_LEAF_VEIN, maxf(1.0, r * 0.10))


static func _leaf_edge(tip: Vector2, base: Vector2, t: float, r: float,
		side: float) -> Vector2:
	var spine := tip.lerp(base, t)
	var width := sin(t * PI) * r * 0.44
	# Perpendicular to the spine, which runs corner to corner.
	return spine + Vector2(-0.707, -0.707) * width * side


## Godot draws circles, not ellipses. Same trick as fallback_blob.gd: scale the
## canvas around the centre, draw a unit circle, put the transform back.
static func _ellipse(on: CanvasItem, centre: Vector2, rx: float, ry: float,
		color: Color) -> void:
	on.draw_set_transform(centre, 0.0, Vector2(rx, ry))
	on.draw_circle(Vector2.ZERO, 1.0, color)
	on.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
