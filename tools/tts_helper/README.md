# Native Qwen3 TTS helper

This directory contains the native process boundary that is intended to replace
the Python + `libqwen3tts` pairing in `tools/qwen3_tts_daemon.py`. The real
helper links the audited qwen C API directly; the upstream source stays outside
this repository and is fetched only at exact commits.

Audited pins:

```text
qwen3-tts.cpp  b3ba14077cf1b3e11b86e5f84aa9184605c89b28
ggml           3af5f5760e19a96427f5f7a93b79cbdf3d4b265b
```

`fetch_sources.sh` checks both resulting HEADs, verifies qwen's ggml gitlink,
and refuses an existing checkout at another commit or with tracked, staged, or
untracked changes. Ignored entries are also refused: a build directory,
library, dependency tree, or other ignored artifact cannot hide in an audited
source checkout. It does not run `git submodule update` and therefore cannot
silently follow a moving branch.

Every Git operation runs in an isolated environment with replacement objects,
system/global configuration, hooks, and filesystem monitors disabled.
Replacement refs are rejected explicitly. Strict Git fsck verifies the locked
commit/tree closure before validation and materialization. New and reused
checkouts share the same final pristine validator, and materialized tree input
is restricted to regular files plus qwen's one exact ggml gitlink; symbolic or
special tree entries are never materialized. After validation, tree inspection
and per-blob materialization address audited commit and blob object IDs
directly—never mutable `HEAD` or `FETCH_HEAD`. Both the validator and
materializer independently recompute each `blob <length>\0<bytes>` object ID
using the repository's declared SHA-1 or SHA-256 object format. Git attributes,
export-ignore rules, and filters do not participate in this object-level copy.

## Build

Protocol-only stub, with no engine:

```sh
./tools/tts_helper/build_stub.sh
python3 ./tools/tts_helper/test_stub.py
```

Engine adapter with a fake qwen C API, requiring no model download:

```sh
./tools/tts_helper/build_fake.sh
python3 ./tools/tts_helper/test_engine.py
```

Real pinned qwen + ggml helper:

```sh
./tools/tts_helper/build_engine.sh
```

The checkout policy has an offline test that creates disposable local Git
repositories and never contacts the audited remotes:

```sh
python3 ./tools/tts_helper/test_fetch_sources.py
python3 ./tools/tts_helper/test_build_engine.py
```

The real build requires Git, Python 3, CMake 3.14 or newer, Make, a C++17 compiler,
and the platform SDKs needed by ggml. `QWEN3_TTS_SOURCE` changes the external
checkout location, `TTS_HELPER_BUILD_DIR` changes the helper build directory,
and `TTS_HELPER_JOBS` controls build parallelism. Physical prospective paths
are resolved before fetching: source and build may not overlap through `..` or
symlink aliases, and audited source may not live inside the project tree.

Every real build requires `TTS_HELPER_BUILD_DIR` to be nonexistent. The claim
walks the canonical parent through no-follow directory descriptors, creates
the child with `mkdirat` semantics and mode 0700, then opens that child without
following a link. Its device/inode identity is checked before materialization.
Incremental reuse is refused and the script never removes a user-provided
directory. After validating the checkouts, one no-follow, exclusive
materializer opens the claimed root by its recorded device/inode, creates and
holds file descriptors for `sources/qwen/ggml` and `deps/ggml`, then copies
both allowlisted qwen and ggml trees under
`TTS_HELPER_BUILD_DIR/sources/qwen` in the same process. Those held descriptors
also apply the exactly-once pinned CMake patch through a no-follow regular-file
descriptor and create the fixed relative ggml build symlink through the held
qwen/ggml descriptor. This limits path-redirection opportunities during source
preparation; it is not a general sandbox against a process that already
controls the host. Immediately after that process exits, a private manifest
records every source entry's relative path, type, mode, device/inode, size, and
SHA-256 content hash. The manifest's own identity and hash plus the
root/dependency directory identities form a small seal token. The entire
source tree is rescanned and compared immediately before every CMake configure
and build.
Audited source is never modified. ggml builds under
`TTS_HELPER_BUILD_DIR/deps/ggml`; the upstream-required `ggml/build` symlink
exists only inside the fresh private copy. The script deterministically
removes the pinned qwen `-march=native` release flag, rejects unexpected patch
cardinality or generated native flags, and accepts exactly one regular
executable from the single-configuration root or multi-configuration
`Release` path.

Both configure passes force the known `Unix Makefiles` generator and
`GGML_NATIVE=OFF`. Immediately after each configure and before its build, a
fail-closed no-follow scan requires generated `Makefile` and `flags.make`
files, reads all Makefiles, recursive `flags.make` files, and response files,
and rejects `-march=native`, `-mcpu=native`, or `-mtune=native`.

The final executable is opened without following links, checked as a regular
executable, and SHA-256 fingerprinted before and after its metadata probes.
`--protocol-version` must print exactly `1`; `--self-test` must identify the
qwen engine with valid JSON. On macOS, available `otool` dependency entries are
inspected and may not point into the audited checkout. A successful build
prints a JSON artifact manifest containing the final identity and hash.

The pinned upstream build currently produces shared ggml backend libraries.
The helper links qwen's own pipeline and C API wrapper into its executable, but
the resulting macOS binary still has `@rpath/libggml*.dylib` dependencies.
Packaging, signing, architecture builds, and runtime download are deliberately
outside this phase; a release bundle must carry and sign that measured
dependency closure, or a later build phase must convert ggml to a verified
static link. Do not publish the executable alone.

## Metadata

```text
--version           prints `godot-pet-tts-helper 0.1.0`
--protocol-version  prints `1`
--self-test         validates JSON handling and names the compiled adapter
```

Metadata modes do not load models. The protocol stub reports
`"engine":"unavailable"`, the fake adapter reports `"fake-qwen"`, and a real
build reports `"qwen3-tts"`.

## Runtime contract

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

Requests are UTF-8 JSON objects, one per stdin line:

```json
{"op":"say","id":7,"text":"你好","lang":"zh","voice":"/x.emb"}
{"op":"clone","id":8,"wav":"/reference.wav","out":"/voice.emb"}
{"op":"cancel"}
{"op":"unload"}
{"op":"quit"}
```

Responses are appended and flushed as JSONL to `--out`:

```json
{"event":"ready","protocol":1,"engine":"qwen3-tts"}
{"event":"audio","id":7,"path":"/spool/7.wav","rate":24000,"samples":1234,"ms":410}
{"event":"cloned","id":8,"path":"/voice.emb","dims":1024}
{"event":"error","id":7,"op":"say","code":"engine_error","message":"..."}
{"event":"bye"}
```

The reader owns stdin on a separate, interruptible POSIX `poll`/`read` thread;
an RAII guard always requests shutdown and joins it, including exception paths.
Work stays serialized through one queue because concurrent qwen synthesis can abort
the process. `cancel` records
the highest accepted `say` id and queued sentences at or below that watermark
receive one `cancelled` event; it never cancels cloning. An in-progress
synthesis cannot be interrupted, matching the Python daemon. Explicit `quit`
and EOF are queued after already accepted work, so every accepted `say` and
`clone` receives exactly one terminal `audio`, `cloned`, or `error` event before
`bye`.

The engine is loaded on the first `say` or `clone`, unloaded explicitly or after
`--idle` seconds, and can load again without restarting the process. Both stdout
and stderr are redirected to `--log` before qwen loads because ggml emits
diagnostics directly and an undrained pipe can otherwise block synthesis.

Audio spool files are mono PCM16 WAV. Both WAV and embedding writers use an
exclusive, unpredictable `mkstemp` file beside the target, flush and sync it,
refuse symbolic-link targets, then use POSIX `rename` for atomic replacement
without first removing the old file. A failed write leaves the old target in
place and removes only the temporary file it created. These guarantees make
the helper POSIX-only for now.

Speaker
embeddings use the existing Q3EM v1 format: `Q3EM`, little-endian version and
dimension count, then little-endian float32 values. Clone inputs that are
readable PCM16 WAVs are rejected below peak `0.05`; unfamiliar WAV variants
fail open so the upstream decoder remains authoritative. The peak preflight
uses fixed-size buffers and validates RIFF length and bounded chunk sizes
before reading or seeking; file-provided chunk lengths never control an
allocation.

The current GDScript daemon path reads raw PCM16 from `.pcm` files. This phase
does not alter GDScript by design, so native-helper integration must explicitly
switch that reader to WAV (or intentionally change this helper back to raw PCM)
before the app can consume these `audio` events. The protocol tests treat the
WAV path as the Phase 1A contract.

Supported language ids match the pinned C API and Python daemon:
`en`, `ru`, `zh`, `ja`, `ko`, `de`, `fr`, `es`, `it`, and `pt`. Unknown values
fall back to `zh`, the existing pet default.

The JSON parser is dependency-free and validates raw UTF-8, standard escapes,
`\uXXXX` escapes, UTF-16 surrogate pairs, duplicate keys, number grammar, and a
64-level nesting limit. Malformed input receives a correlated
`malformed_request` where an id/op can safely be recovered, and processing
continues.
