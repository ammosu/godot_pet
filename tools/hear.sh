#!/bin/sh
# Batch-render the試聽 lines in tools/say_samples.txt to wav files, so a change
# to prompts/pronunciation.json can be judged by ear in one sitting.
#
#   tools/hear.sh                # every group
#   tools/hear.sh 覺             # one group
#   tools/hear.sh 覺 yu          # …in a particular voice
#   tools/hear.sh "" yu          # every group, in a particular voice
#
# Where say.sh is for one line you are thinking about right now, this is the
# regression pass: rerun it after editing the table and listen for what got
# better *and* what got worse. Both go through tools/respell.py, so what you
# hear is what the pet would say.
#
# Files land in ~/聽聽看/<組名>/ and that folder is emptied for the group being
# rendered — old wavs from a previous table are the one thing guaranteed to
# confuse a listening test.
#
# Where a rule fires, two files are written: the spoken form and the original,
# named …-原句.wav. Judging a substitution needs both, and there is no way to
# know from the audio alone which one you are hearing.

set -e
GROUP="$1"
VOICE="$2"

REPO=$(cd "$(dirname "$0")/.." && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Godot Pet"
VOICES="$DATA/qwen3_tts/voices"
SAMPLES="$REPO/tools/say_samples.txt"
OUTROOT="${GODOT_PET_HEAR_DIR:-$HOME/聽聽看}"

[ -f "$SAMPLES" ] || { echo "找不到 $SAMPLES" >&2; exit 1; }

LIB="${GODOT_PET_QWEN3_LIB:-$HOME/git_project/qwen3-tts.cpp/build/libqwen3tts.so}"
MODELS="${GODOT_PET_QWEN3_MODELS:-$HOME/git_project/qwen3-tts.cpp/models}"
CLI=$(dirname "$LIB")/qwen3-tts-cli
[ -x "$CLI" ] || { echo "找不到 $CLI，本機語音引擎沒裝好。" >&2; exit 1; }

# The voice: the argument, else whatever the pet is currently set to — the same
# order say.sh uses, so the two tools never disagree about who is speaking.
if [ -z "$VOICE" ]; then
	VOICE=$(sed -n 's/^qwen3_voice="\(.*\)"$/\1/p' "$DATA/config.cfg" 2>/dev/null | head -1)
fi
# Held in the positional parameters for the reason say.sh documents: the path
# contains a space ("…/app_userdata/Godot Pet/…") and an unquoted expansion
# splits it into two arguments.
if [ -n "$VOICE" ] && [ -f "$VOICES/$VOICE.emb" ]; then
	set -- --load-embedding "$VOICES/$VOICE.emb"
	echo "聲音：$VOICE"
else
	set --
	echo "聲音：預設嗓音"
fi
[ -n "$GROUP" ] && echo "只產 [$GROUP] 這一組"
echo

CURRENT=""
INDEX=0
MADE=0
OUTDIR=""

# `printf %s` rather than echo: a line starting with "-" or containing a
# backslash is data here, and echo would eat both.
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		'#'*|'') continue ;;
		'['*']')
			CURRENT=$(printf '%s' "$line" | tr -d '[]')
			INDEX=0
			OUTDIR=""
			continue
			;;
	esac
	[ -n "$GROUP" ] && [ "$CURRENT" != "$GROUP" ] && continue

	# Created on first use so an unselected group leaves no empty folder behind.
	if [ -z "$OUTDIR" ]; then
		OUTDIR="$OUTROOT/$CURRENT"
		rm -rf "$OUTDIR"
		mkdir -p "$OUTDIR"
		echo "== $CURRENT =="
	fi

	INDEX=$((INDEX + 1))
	SPOKEN=$(printf '%s' "$line" | python3 "$REPO/tools/respell.py")

	# The filename has to say which line it is without being opened, and both
	# obvious tools get this wrong: `cut -c` counts *bytes* and `tr -d` deletes
	# *bytes*, so on a UTF-8 Chinese line they slice through the middle of a
	# character and produce names like 「欸��子在�欸你��」. Python counts
	# characters, which is what is wanted here.
	STEM=$(printf '%s' "$line" | python3 -c '
import sys
drop = set(" 　。，、！？…「」（）：；·／\\\\\"'"'"'")
line = sys.stdin.read().strip()
print("".join(c for c in line if c not in drop)[:12])
')
	NUM=$(printf '%02d' "$INDEX")

	if [ "$SPOKEN" != "$line" ]; then
		printf '  %s %s\n     唸：%s\n' "$NUM" "$line" "$SPOKEN"
		"$CLI" -m "$MODELS" -l zh -t "$SPOKEN" "$@" -o "$OUTDIR/$NUM-$STEM.wav" \
			>/dev/null 2>&1 || { echo "     ！合成失敗" >&2; continue; }
		"$CLI" -m "$MODELS" -l zh -t "$line" "$@" -o "$OUTDIR/$NUM-$STEM-原句.wav" \
			>/dev/null 2>&1 || true
		MADE=$((MADE + 2))
	else
		printf '  %s %s\n' "$NUM" "$line"
		"$CLI" -m "$MODELS" -l zh -t "$SPOKEN" "$@" -o "$OUTDIR/$NUM-$STEM.wav" \
			>/dev/null 2>&1 || { echo "     ！合成失敗" >&2; continue; }
		MADE=$((MADE + 1))
	fi
done < "$SAMPLES"

echo
if [ "$MADE" -eq 0 ]; then
	echo "沒有產出任何檔案。組名打錯了嗎？可用的組："
	grep -o '^\[.*\]' "$SAMPLES" | tr -d '[]' | sed 's/^/  /'
	exit 1
fi
echo "產了 $MADE 個檔，在 $OUTROOT/"
echo "帶「-原句」的是套用規則前的樣子，用來跟同編號的那個比。"
