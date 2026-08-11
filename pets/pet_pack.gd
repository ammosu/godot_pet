extends RefCounted
class_name PetPack

## Loads a pet in the Codex Pets / petdex sprite format:
##
##   {pet-id}/pet.json          metadata
##   {pet-id}/spritesheet.webp  8 columns of 192x208 cells, one row per state
##
## Row = animation state, column = frame within that state.
##
## The manifest declares *nothing* about the animation — no frame counts, no
## state names, and no grid size. So all of it is inferred: frames are packed
## left to right and a row ends at its first blank cell, while the row count
## comes from the sheet's own height. State names come from a caller-supplied row
## map, because the two ecosystems using this format disagree on the row order.
##
## The row count is measured rather than assumed because the format grew: the
## original sheets were 9 rows and `spriteVersionNumber: 2` packs are 11.
## Measuring the actual sheet keeps malformed or older manifests from making a
## hard-coded row count reject otherwise usable art.
##
## The project-owned default pack ships at res://pets/default. Community packs
## are still read from wherever `npx codex-pets add <id>` installed them, which
## keeps their licensing between the user and the pet's author.

const COLS := 8
const BUILTIN_DIR := "res://pets/default"
## Shape of one cell. Only the ratio is used — a pack drawn at 2x keeps it — and
## it's what lets the row count be derived from the sheet's height.
const CELL_ASPECT := Vector2i(192, 208)
const DEFAULT_FPS := 8.0
## Codex Pets v2's state-specific frame timing. SpriteFrames durations are in
## seconds when animation speed is 1.0; look rows are selected directly and do
## not need playback timing.
const V2_FRAME_DURATIONS := {
	0: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320],
	1: [0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.220],
	2: [0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.220],
	3: [0.140, 0.140, 0.140, 0.280],
	4: [0.140, 0.140, 0.140, 0.140, 0.280],
	5: [0.140, 0.140, 0.140, 0.140, 0.140, 0.140, 0.140, 0.240],
	6: [0.150, 0.150, 0.150, 0.150, 0.150, 0.260],
	7: [0.120, 0.120, 0.120, 0.120, 0.120, 0.220],
	8: [0.150, 0.150, 0.150, 0.150, 0.150, 0.280],
}

## A cell whose drawn content is smaller than this in either axis counts as blank.
## Guards against stray semi-transparent pixels reading as a real frame.
const MIN_CONTENT_PX := 4
const DEFAULT_SPRITESHEET := "spritesheet.webp"
const MAX_ID_CHARS := 120
const MAX_DISPLAY_NAME_CHARS := 120
const MAX_DESCRIPTION_CHARS := 500

var id := ""
var display_name := ""
var description := ""
## Directory the manifest came from. CompanionProfile uses the optional
## `companion.json` beside it without adding project-specific fields to the
## Codex Pets manifest format.
var base_dir := ""
var sprite_version_number := 1
var smooth_filter := false
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
## Tight drawn-content boxes for the individual frames in every row. Gameplay
## collisions need the frame that is on screen, not the row-wide union: the
## latter includes the furthest reach of every pose and can be noticeably wider
## than any one frame.
var row_frame_rects: Array[Array] = []


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


static func load_builtin() -> PetPack:
	var pack := load_from_dir(BUILTIN_DIR)
	if pack != null:
		# The bundled original is hand-drawn rather than pixel art. Keep the
		# standard pet.json schema and make this renderer-only choice here.
		pack.smooth_filter = true
	return pack


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

	var sheet_path := _safe_sheet_path(dir, data.get("spritesheetPath", DEFAULT_SPRITESHEET))
	if sheet_path.is_empty():
		push_warning("PetPack: refusing unsafe spritesheetPath in %s" % manifest_path)
		return null
	var image := _load_sheet_image(sheet_path)
	if image == null:
		push_warning("PetPack: cannot load spritesheet %s" % sheet_path)
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var cell := _cell_size_for(image)
	if cell == Vector2i.ZERO:
		push_warning("PetPack: %s is %dx%d, which is not %d columns of %d:%d cells"
			% [sheet_path, image.get_width(), image.get_height(),
				COLS, CELL_ASPECT.x, CELL_ASPECT.y])
		return null

	var pack := PetPack.new()
	pack.base_dir = dir
	pack.id = _manifest_text(data.get("id"), dir.get_file(), MAX_ID_CHARS)
	pack.display_name = _manifest_text(
		data.get("displayName"), pack.id, MAX_DISPLAY_NAME_CHARS)
	pack.description = _manifest_text(data.get("description"), "", MAX_DESCRIPTION_CHARS)
	pack.sprite_version_number = _manifest_version(data.get("spriteVersionNumber", 1))
	pack.cell_size = cell
	pack._slice(image)

	if pack.frame_total() == 0:
		push_warning("PetPack: %s has no usable frames" % sheet_path)
		return null
	return pack


## A community manifest may select a file inside its own pack, never turn the
## sprite loader into an arbitrary local-file reader. Nested relative folders
## are allowed; absolute paths, resource schemes and parent traversal are not.
static func _safe_sheet_path(dir: String, raw: Variant) -> String:
	if typeof(raw) != TYPE_STRING:
		return ""
	var relative := str(raw).replace("\\", "/").strip_edges()
	if relative.is_empty():
		relative = DEFAULT_SPRITESHEET
	if relative.is_absolute_path() or relative.contains("://"):
		return ""
	for component in relative.split("/", false):
		if component == "..":
			return ""
	var simplified := relative.simplify_path()
	if simplified.is_empty() or simplified == "." or simplified.begins_with("../"):
		return ""
	return dir.path_join(simplified)


## Optional display metadata is untrusted too. Wrong JSON types fall back
## instead of reaching typed properties and aborting the load at runtime.
static func _manifest_text(raw: Variant, fallback: String, limit: int) -> String:
	if typeof(raw) != TYPE_STRING:
		return fallback
	var value := str(raw).strip_edges()
	return fallback if value.is_empty() else value.left(limit)


static func _manifest_version(raw: Variant) -> int:
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		return 1
	return maxi(1, int(raw))


static func _load_sheet_image(sheet_path: String) -> Image:
	# Project-owned images must use Godot's imported resource path so they remain
	# available after export. Community packs live outside res:// and continue
	# to use direct file loading.
	if sheet_path.begins_with("res://"):
		var texture := load(sheet_path) as Texture2D
		return texture.get_image() if texture != null else null
	return Image.load_from_file(sheet_path)


## Cell size implied by the sheet's width, or zero if the sheet isn't a whole
## number of rows of them. The columns are fixed at COLS; everything else is
## measured, since nothing in the manifest declares the grid.
static func _cell_size_for(image: Image) -> Vector2i:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or width % COLS != 0:
		return Vector2i.ZERO
	var cell_width := width / COLS
	# Integer maths throughout: a sheet whose cells aren't a whole number of
	# pixels tall is malformed, not something to round into shape.
	if cell_width * CELL_ASPECT.y % CELL_ASPECT.x != 0:
		return Vector2i.ZERO
	var cell_height := cell_width * CELL_ASPECT.y / CELL_ASPECT.x
	if cell_height <= 0 or height % cell_height != 0:
		return Vector2i.ZERO
	return Vector2i(cell_width, cell_height)


func row_count() -> int:
	return row_frame_counts.size()


func frame_total() -> int:
	var total := 0
	for count in row_frame_counts:
		total += count
	return total


func has_row(row: int) -> bool:
	return row >= 0 and row < row_frame_counts.size() and row_frame_counts[row] > 0


func has_look_directions() -> bool:
	return sprite_version_number >= 2 and has_row(9) and has_row(10) \
		and row_frame_counts[9] >= COLS and row_frame_counts[10] >= COLS


## Bounding box of one row's frames, falling back to the whole-sheet union.
func rect_for_row(row: int) -> Rect2i:
	if has_row(row) and row < row_rects.size() and row_rects[row].size != Vector2i.ZERO:
		return row_rects[row]
	return content_rect


## Bounding box of one animation frame, falling back through the row union to
## the whole-sheet union for malformed or incomplete external packs.
func rect_for_frame(row: int, frame: int) -> Rect2i:
	if row >= 0 and row < row_frame_rects.size():
		var rects: Array = row_frame_rects[row]
		if frame >= 0 and frame < rects.size():
			var rect: Rect2i = rects[frame]
			if rect.size != Vector2i.ZERO:
				return rect
	return rect_for_row(row)


func _slice(image: Image) -> void:
	var sheet := ImageTexture.create_from_image(image)
	frames = SpriteFrames.new()
	frames.remove_animation(&"default")
	var rows := image.get_height() / cell_size.y
	row_frame_counts.resize(rows)
	row_rects.resize(rows)
	row_frame_rects.resize(rows)

	var content := Rect2i()
	for row in rows:
		var anim := row_anim(row)
		frames.add_animation(anim)
		frames.set_animation_loop(anim, true)
		var durations: Array = V2_FRAME_DURATIONS.get(row, []) \
			if sprite_version_number >= 2 else []
		frames.set_animation_speed(anim, 1.0 if not durations.is_empty() else DEFAULT_FPS)

		var used_frames := 0
		var row_box := Rect2i()
		var frame_boxes: Array[Rect2i] = []
		for col in COLS:
			var region := Rect2i(Vector2i(col, row) * cell_size, cell_size)
			var drawn := image.get_region(region).get_used_rect()
			# Frames are packed left to right, so the first blank cell ends the row.
			if drawn.size.x < MIN_CONTENT_PX or drawn.size.y < MIN_CONTENT_PX:
				break
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(region)
			var duration := float(durations[used_frames]) \
				if used_frames < durations.size() else 1.0
			frames.add_frame(anim, atlas, duration)
			used_frames += 1
			frame_boxes.append(drawn)
			row_box = drawn if row_box.size == Vector2i.ZERO else row_box.merge(drawn)
		row_frame_counts[row] = used_frames
		row_rects[row] = row_box
		row_frame_rects[row] = frame_boxes
		if row_box.size != Vector2i.ZERO:
			content = row_box if content.size == Vector2i.ZERO else content.merge(row_box)

	content_rect = content
