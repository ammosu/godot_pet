# Native TTS protocol stub

This directory contains a dependency-free C++17 executable that exercises the
process boundary used by `tools/qwen3_tts_daemon.py`. It does not link
qwen3-tts.cpp or synthesize audio yet. Its purpose is to freeze the helper CLI,
JSONL lifecycle, error correlation, and metadata probes before the real engine
is moved behind them.

## Build and test

```sh
./tools/tts_helper/build_stub.sh
python3 ./tools/tts_helper/test_stub.py
```

`build_stub.sh` writes `build/tts_helper_stub` by default. Pass an explicit
output path as its first argument to keep the binary elsewhere. Set `CXX` to
choose another C++17 compiler.

## Metadata interface

```text
--version           prints `godot-pet-tts-helper 0.1.0`
--protocol-version  prints `1`
--self-test         validates the built-in JSON parser and reports engine state
```

The self-test succeeds when the protocol shell is healthy. It deliberately
reports `"engine":"unavailable"` because this stub contains no synthesis engine.

## Runtime interface

Normal mode requires:

```text
--models DIR
--out FILE
--spool DIR
--log FILE
--threads N
--idle SECONDS
--protocol 1
```

Requests are one JSON object per UTF-8 line on stdin. Responses are appended as
one JSON object per line to `--out`; stdout stays empty. The accepted operations
match the Python daemon:

- `say` and `clone` each receive one correlated `engine_unavailable` error.
- `cancel` and `unload` are accepted without a response, matching the current
  daemon protocol.
- `quit` writes `bye` and exits.
- EOF also writes `bye` and exits, so the helper cannot be orphaned when its
  parent disappears.
- Invalid JSON, non-object requests, missing fields, and unknown operations
  receive a `malformed_request` error and do not stop the process.

On startup the stub emits:

```json
{"event":"ready","protocol":1,"engine":"unavailable"}
```

The parser handles all JSON value kinds, standard escapes, raw UTF-8, `\uXXXX`
escapes, and UTF-16 surrogate pairs. Duplicate object keys and nesting beyond
64 levels are rejected. Raw UTF-8 is validated strictly: overlong encodings,
isolated or invalid continuation bytes, surrogate code points, values above
U+10FFFF, and truncated sequences are rejected. This keeps every response valid
UTF-8 JSON even when a request contains malformed bytes.

## Engine integration constraints

The future engine-backed helper must keep this CLI and response contract, but
engine integration is not a synchronous replacement of the
`engine_unavailable` branches. Stdin must remain responsive while inference is
running. Use a dedicated reader thread feeding a command queue, plus a
generation/cancel watermark shared with the inference worker, so `cancel`,
`quit`, and EOF can still be observed and acted on during synthesis. Shutdown
must join workers and emit exactly one `bye`. Diagnostics continue to go to
`--log`, never to the JSONL response stream or stdout.

The native build must pin its engine sources to these exact revisions:

- `qwen3-tts.cpp`: `b3ba14077cf1b3e11b86e5f84aa9184605c89b28`
- `ggml`: `3af5f5760e19a96427f5f7a93b79cbdf3d4b265b`
