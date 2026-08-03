#!/bin/sh
# Say a line in the pet's current voice, without the pet.
#
# The loop for building prompts/pronunciation.json: hear the line, add an entry,
# hear it again. Reading the table here rather than making the app reload it
# keeps the "prompt files take effect on restart" rule intact — this is a
# listening tool, not a second code path.
#
#   tools/say.sh "我等一下要去銀行。"
#   tools/say.sh "我等一下要去銀行。" yu     # a specific voice
#
# Applies the same substitutions TTSService does, and prints what it actually
# sent, so a rule that fired (or didn't) is visible rather than guessed at.
#
# The voice comes from the VoxCPM service, through tools/voice_lab.py, which is
# also what the pet and the checking tools use — so what you hear here is what
# it will say. The service has to be running; without it this says so and stops
# rather than falling back to something that sounds different.

set -e
TEXT="$1"
VOICE="$2"
[ -z "$TEXT" ] && { echo "用法: tools/say.sh '要唸的句子' [聲音名字]" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)

SPOKEN=$(printf '%s' "$TEXT" | python3 "$REPO/tools/respell.py")

echo "寫的：$TEXT"
[ "$SPOKEN" != "$TEXT" ] && echo "唸的：$SPOKEN（替換過）" || echo "唸的：（沒有規則命中）"

# Built by hand rather than `mktemp -t`: on BSD/macOS `-t` takes a *prefix* and
# appends its own random suffix, so the file would not end in .wav and afplay
# would be handed something it cannot identify.
OUT="${TMPDIR:-/tmp}/godot-pet-say-$$.wav"
trap 'rm -f "$OUT"' EXIT
# Through voice_lab rather than any HTTP of its own: the pet, the proofreader
# and this all have to agree about which service, which voice and which key, and
# three places that each knew is three places to drift.
USED=$(python3 "$REPO/tools/voice_lab.py" "$SPOKEN" "$OUT" "$VOICE") || exit 1
echo "聲音：$USED"
for p in paplay aplay ffplay afplay; do
	if command -v "$p" >/dev/null 2>&1; then
		case "$p" in
			ffplay) "$p" -autoexit -nodisp -loglevel quiet "$OUT" ;;
			*) "$p" "$OUT" >/dev/null 2>&1 ;;
		esac
		exit 0
	fi
done
echo "沒有可用的播放器，檔案留在 $OUT" >&2
trap - EXIT
