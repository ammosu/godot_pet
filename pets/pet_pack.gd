extends RefCounted
class_name PetPack

## Loads a pet in the Codex Pets / petdex sprite format:
##
##   {pet-id}/pet.json          metadata
##   {pet-id}/spritesheet.webp  8 x 9 grid of equally sized cells, 72 frames
##
## Row = animation state, column = frame within that state.
##
## The manifest declares *nothing* about the animation — no frame counts, no
## state names. So both are inferred: frames are packed left to right, and a row
## ends at its first blank cell. State names come from a caller-supplied row map,
## because the two ecosystems using this format disagree on the row order.
##
## No artwork ships with this project. Packs are read from wherever
## `npx codex-pets add <id>` installed them, which keeps asset licensing between
## the user and the pet's author.

const COLS := 8
const ROWS := 9
const DEFAULT_FPS := 8.0

## A cell whose drawn content is smaller than this in either axis counts as blank.
## Guards against stray semi-transparent pixels reading as a real frame.
const MIN_CONTENT_PX := 4

var id := ""
var display_name := ""
var description := ""
var frames: SpriteFrames
var cell_size := Vector2i.ZERO
## Tight bounding box of the drawn character inside a cell, unioned over every
## frame, in cell-local pixels.
var content_rect := Rect2i()
## Same, but per row. A pet's action poses (a staff thrust, arms flung out) are
## much wider than its resting pose, so anything that positions the pet against
## a screen edge should measure the row it actually idles in.
var row_rects: Array[Rect2i] = []
## How many frames each row actually uses.
var row_frame_counts := PackedInt32Array()


static func row_anim(row: int) -> StringName:
	return StringName("row%d" % row)


## Where `npx codex-pets add` installs packs.
static func pets_root() -> String:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	if home.is_empty():
		return ""
	return home.path_join(".codex").path_join("pets")


static func list_installed() -> PackedStringArray:
	var found := PackedStringArray()
	var root := pets_root()
	if root.is_empty():
		return found
	var dir := DirAccess.open(root)
	if dir == null:
		return found
	for name in dir.get_directories():
		if FileAccess.file_exists(root.path_join(name).path_join("pet.json")):
			found.append(name)
	found.sort()
	return found


static func load_installed(pet_id: String) -> PetPack:
	var root := pets_root()
	if root.is_empty():
		return null
	return load_from_dir(root.path_join(pet_id))


static func load_from_dir(dir: String) -> PetPack:
	var manifest_path := dir.path_join("pet.json")
	var raw := FileAccess.get_file_as_string(manifest_path)
	if raw.is_empty():
		push_warning("PetPack: cannot read %s" % manifest_path)
		return null
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("PetPack: malformed manifest %s" % manifest_path)
		return null

	var sheet_path := dir.path_join(data.get("spritesheetPath", "spritesheet.webp"))
	var image := Image.load_from_file(sheet_path)
	if image == null:
		push_warning("PetPack: cannot load spritesheet %s" % sheet_path)
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	if image.get_width() % COLS != 0 or image.get_height() % ROWS != 0:
		push_warning("PetPack: %s is %dx%d, not divisible into a %dx%d grid"
			% [sheet_path, image.get_width(), image.get_height(), COLS, ROWS])
		return null

	var pack := PetPack.new()
	pack.id = data.get("id", dir.get_file())
	pack.display_name = data.get("displayName", pack.id)
	pack.description = data.get("description", "")
	pack.cell_size = Vector2i(image.get_width() / COLS, image.get_height() / ROWS)
	pack._slice(image)

	if pack.frame_total() == 0:
		push_warning("PetPack: %s has no usable frames" % sheet_path)
		return null
	return pack


func frame_total() -> int:
	var total := 0
	for count in row_frame_counts:
		total += count
	return total


func has_row(row: int) -> bool:
	return row >= 0 and row < row_frame_counts.size() and row_frame_counts[row] > 0


## Bounding box of one row's frames, falling back to the whole-sheet union.
func rect_for_row(row: int) -> Rect2i:
	if has_row(row) and row < row_rects.size() and row_rects[row].size != Vector2i.ZERO:
		return row_rects[row]
	return content_rect


func _slice(image: Image) -> void:
	var sheet := ImageTexture.create_from_image(image)
	frames = SpriteFrames.new()
	frames.remove_animation(&"default")
	row_frame_counts.resize(ROWS)
	row_rects.resize(ROWS)

	var content := Rect2i()
	for row in ROWS:
		var anim := row_anim(row)
		frames.add_animation(anim)
		frames.set_animation_loop(anim, true)
		frames.set_animation_speed(anim, DEFAULT_FPS)

		var used_frames := 0
		var row_box := Rect2i()
		for col in COLS:
			var region := Rect2i(Vector2i(col, row) * cell_size, cell_size)
			var drawn := image.get_region(region).get_used_rect()
			# Frames are packed left to right, so the first blank cell ends the row.
			if drawn.size.x < MIN_CONTENT_PX or drawn.size.y < MIN_CONTENT_PX:
				break
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(region)
			frames.add_frame(anim, atlas)
			used_frames += 1
			row_box = drawn if row_box.size == Vector2i.ZERO else row_box.merge(drawn)
		row_frame_counts[row] = used_frames
		row_rects[row] = row_box
		if row_box.size != Vector2i.ZERO:
			content = row_box if content.size == Vector2i.ZERO else content.merge(row_box)

	content_rect = content
