extends Node

## Lets the pet look at the screen — but only when asked.
##
## Never on a timer and never from a nudge. A pet that quietly photographs your
## desktop all day is a different piece of software from one that looks when you
## tell it to, and only the second one is what this is.
##
## What it sees stays out of long-term memory: the reply is marked ephemeral, so
## it's never folded into the summary or extracted as a fact, and never written
## to disk. One glimpse of a bank balance shouldn't become something the pet
## re-sends with every future request.

## Longest edge sent to the model. Roughly 570 prompt tokens at "low" detail,
## which is several times a text-only turn — cheap to do occasionally, not
## something to do in the background.
const MAX_EDGE := 768
const JPEG_QUALITY := 0.6
const DETAIL := "low"

const DEFAULT_QUESTION := "你看一下我現在的螢幕，跟我說說你看到什麼。"

## Below this much local contrast the capture is almost certainly just the
## desktop wallpaper. Calibrated against real captures; a genuinely empty
## desktop trips it too, which is why the pet asks rather than asserts.
const FLAT_IMAGE_THRESHOLD := 0.02
const PROBE_SIZE := 64


## Questions that can't be answered without seeing the screen. Deliberately
## narrow: these fire before the model gets a word in, so a false positive costs
## a consent prompt the user didn't ask for, plus a screenshot's worth of tokens.
##
## This exists because the model can't be relied on to ask. `[look]` works on a
## mid-sized model and not at all on a nano one, which fails the wrong way —
## the pet insists it has no eyes instead of using the ones it has. Matching
## locally makes the obvious phrasings work on any backend, and `[look]` still
## covers everything this list doesn't ("這個排版對嗎", "為什麼跑不起來").
const LOOK_PATTERNS := [
	"我在幹嘛", "我在幹麻", "我在做什麼", "我在忙什麼",
	"看一下我的螢幕", "看我的螢幕", "看一下螢幕", "看看我的螢幕",
	"看一下畫面", "看我的畫面", "看看畫面", "看一下我的桌面", "看我的桌面",
	"我的螢幕", "我的畫面", "螢幕上", "畫面上",
]


func is_supported() -> bool:
	return OS.get_name() in ["macOS", "Windows", "Linux"]


## Does this question obviously need a screenshot? Checked before the question
## goes to the model at all.
func wants_a_look(question: String) -> bool:
	if not is_supported():
		return false
	var text := question.to_lower()
	for pattern in LOOK_PATTERNS:
		if text.contains(pattern):
			return true
	return false


## Capture, downscale, and hand it to the model. The reply streams into the
## bubble like any other.
func look(question := DEFAULT_QUESTION, record_question := true) -> void:
	if not is_supported():
		EventBus.reply_failed.emit("這個系統不支援截圖")
		return

	var shot := await _capture()
	if shot == null or shot.is_empty():
		EventBus.reply_failed.emit("截不到螢幕畫面")
		return

	if _looks_like_wallpaper_only(shot):
		# macOS hands back the wallpaper with no error at all when Screen
		# Recording permission is missing, so this can't be left to fail
		# silently — the model would cheerfully discuss the desktop picture.
		EventBus.pet_nudged.emit("sad",
			"我只看到桌布欸……是不是還沒給我螢幕錄製權限？系統設定 → 隱私權與安全性 → 螢幕錄製。")
		return

	LLMService.ask_about_image(question, _to_data_url(shot), record_question)


## Hide the pet for the length of one capture, so it doesn't spend the
## screenshot describing its own speech bubble — and so it's still visible in
## screenshots the user takes themselves. Leaving the flag on permanently makes
## the pet impossible to photograph at all, which is a worse trade.
func _capture() -> Image:
	var window := get_window()
	window.set_flag(Window.FLAG_EXCLUDE_FROM_CAPTURE, true)
	# The window server needs a beat to apply the new sharing type; capturing in
	# the same frame still catches the pet.
	await get_tree().process_frame
	await get_tree().process_frame
	var shot := DisplayServer.screen_get_image(DisplayServer.window_get_current_screen())
	window.set_flag(Window.FLAG_EXCLUDE_FROM_CAPTURE, false)
	return shot


func _to_data_url(shot: Image) -> String:
	var longest := maxi(shot.get_width(), shot.get_height())
	if longest > MAX_EDGE:
		var scale := float(MAX_EDGE) / float(longest)
		shot.resize(int(shot.get_width() * scale), int(shot.get_height() * scale),
			Image.INTERPOLATE_LANCZOS)
	return "data:image/jpeg;base64," + Marshalls.raw_to_base64(shot.save_jpg_to_buffer(JPEG_QUALITY))


## Mean local contrast of a thumbnail. Interface chrome — text, window edges,
## icons — is full of hard transitions; wallpapers are smooth.
func _looks_like_wallpaper_only(shot: Image) -> bool:
	var probe := shot.duplicate() as Image
	probe.resize(PROBE_SIZE, PROBE_SIZE, Image.INTERPOLATE_BILINEAR)
	probe.convert(Image.FORMAT_L8)

	var total := 0.0
	var samples := 0
	for y in PROBE_SIZE:
		for x in PROBE_SIZE - 1:
			total += absf(probe.get_pixel(x, y).r - probe.get_pixel(x + 1, y).r)
			samples += 1
	return samples > 0 and total / float(samples) < FLAT_IMAGE_THRESHOLD
