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

set -e
TEXT="$1"
VOICE="$2"
[ -z "$TEXT" ] && { echo "用法: tools/say.sh '要唸的句子' [聲音名字]" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Godot Pet"
VOICES="$DATA/qwen3_tts/voices"

LIB="${GODOT_PET_QWEN3_LIB:-$HOME/git_project/qwen3-tts.cpp/build/libqwen3tts.so}"
MODELS="${GODOT_PET_QWEN3_MODELS:-$HOME/git_project/qwen3-tts.cpp/models}"
CLI=$(dirname "$LIB")/qwen3-tts-cli
[ -x "$CLI" ] || { echo "找不到 $CLI" >&2; exit 1; }

# The voice: the argument, else whatever the pet is currently set to.
if [ -z "$VOICE" ]; then
	VOICE=$(sed -n 's/^qwen3_voice="\(.*\)"$/\1/p' "$DATA/config.cfg" 2>/dev/null | head -1)
fi
# Held in the positional parameters rather than a variable: the path contains a
# space ("…/app_userdata/Godot Pet/…"), and an unquoted $EMB splits it into two
# arguments — which the CLI then rejects with the wav deleted by the exit trap,
# so the only symptom was an exit code.
if [ -n "$VOICE" ] && [ -f "$VOICES/$VOICE.emb" ]; then
	set -- --load-embedding "$VOICES/$VOICE.emb"
else
	set --
fi

# The same table the app applies, through the same code hear.sh uses. Not a
# copy of the substitution inline here: two listening tools that respell
# differently from each other, or from the pet, would send you looking for a
# rule that is already right.
SPOKEN=$(printf '%s' "$TEXT" | python3 "$REPO/tools/respell.py")

echo "寫的：$TEXT"
[ "$SPOKEN" != "$TEXT" ] && echo "唸的：$SPOKEN（替換過）" || echo "唸的：（沒有規則命中）"
[ $# -gt 0 ] && echo "聲音：$VOICE" || echo "聲音：預設嗓音"

# Built by hand rather than `mktemp -t`: on BSD/macOS `-t` takes a *prefix* and
# appends its own random suffix, so the file would not end in .wav and afplay
# would be handed something it cannot identify.
OUT="${TMPDIR:-/tmp}/godot-pet-say-$$.wav"
trap 'rm -f "$OUT"' EXIT
if ! "$CLI" -m "$MODELS" -l zh -t "$SPOKEN" "$@" -o "$OUT" 2>"$OUT.err" >/dev/null; then
	echo "合成失敗：" >&2; tail -3 "$OUT.err" >&2; rm -f "$OUT.err"; exit 1
fi
rm -f "$OUT.err"
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
