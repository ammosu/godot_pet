#!/bin/sh
set -eu

if [ "${1:-}" = "--test-local-repositories" ]; then
	if [ "$#" -ne 6 ]; then
		printf '%s\n' \
			'usage: fetch_sources.sh --test-local-repositories QWEN_REPO QWEN_SHA GGML_REPO GGML_SHA DEST' \
			>&2
		exit 2
	fi
	QWEN_REPOSITORY=$2
	QWEN_COMMIT=$3
	GGML_REPOSITORY=$4
	GGML_COMMIT=$5
	destination=$6
else
	QWEN_REPOSITORY=https://github.com/predict-woo/qwen3-tts.cpp.git
	QWEN_COMMIT=b3ba14077cf1b3e11b86e5f84aa9184605c89b28
	GGML_REPOSITORY=https://github.com/ggml-org/ggml.git
	GGML_COMMIT=3af5f5760e19a96427f5f7a93b79cbdf3d4b265b
	destination=${1:-/tmp/godot-pet-qwen3-tts}
fi

safe_git() {
	env -i \
		PATH="$PATH" \
		HOME="${TMPDIR:-/tmp}" \
		GIT_NO_REPLACE_OBJECTS=1 \
		GIT_CONFIG_NOSYSTEM=1 \
		GIT_CONFIG_GLOBAL=/dev/null \
		git \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		"$@"
}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

validate_pristine() {
	target=$1
	commit=$2
	safe_git -C "$target" fsck --strict --no-dangling "$commit"
	actual=$(safe_git -C "$target" rev-parse HEAD)
	if [ "$actual" != "$commit" ]; then
		printf 'refusing checkout at unexpected commit: %s has %s, need %s\n' \
			"$target" "$actual" "$commit" >&2
		return 1
	fi
	replace_refs=$(safe_git -C "$target" for-each-ref \
			--format='%(refname)' refs/replace)
	if [ -n "$replace_refs" ]; then
		printf 'refusing source checkout with replacement refs: %s\n%s\n' \
			"$target" "$replace_refs" >&2
		return 1
	fi
	if [ "$target" = "$destination" ]; then
		python3 "$script_dir/validate_git_checkout.py" \
			"$target" "$commit" --qwen-gitlink "$GGML_COMMIT"
	else
		python3 "$script_dir/validate_git_checkout.py" "$target" "$commit"
	fi
}

checkout_exact() {
	repository=$1
	commit=$2
	target=$3

	if [ -d "$target/.git" ]; then
		validate_pristine "$target" "$commit"
		return
	fi
	if [ -e "$target" ]; then
		if [ ! -d "$target" ] || [ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
			printf 'refusing non-empty source destination: %s\n' "$target" >&2
			return 1
		fi
	fi

	mkdir -p "$target"
	safe_git -C "$target" init -q --template=
	safe_git -C "$target" remote add origin "$repository"
	safe_git -C "$target" fetch --depth=1 origin "$commit"
	safe_git -C "$target" checkout -q --detach FETCH_HEAD
	validate_pristine "$target" "$commit"
}

checkout_exact "$QWEN_REPOSITORY" "$QWEN_COMMIT" "$destination"

gitlink=$(safe_git -C "$destination" ls-tree "$QWEN_COMMIT" ggml |
	awk '{print $3}')
if [ "$gitlink" != "$GGML_COMMIT" ]; then
	printf 'qwen gitlink mismatch: got %s, audited %s\n' "$gitlink" "$GGML_COMMIT" >&2
	exit 1
fi
checkout_exact "$GGML_REPOSITORY" "$GGML_COMMIT" "$destination/ggml"

printf 'qwen3-tts.cpp %s\n' "$QWEN_COMMIT"
printf 'ggml             %s\n' "$GGML_COMMIT"
printf '%s\n' "$destination"
