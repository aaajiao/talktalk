# libfvad (vendored)

Voice activity detector of WebRTC as a standalone C library (ARCHITECTURE.md §2.3, §3.2). Used
only through `tt_vad` (`Sources/CAudioCore/tt_vad.c`, `include/tt_vad.h`), on the audio worker.

| | |
|---|---|
| Upstream | https://github.com/dpirch/libfvad |
| Commit | `532ab666c20d3cfda38bca63abbb0f152706c369` (2024-02-19) |
| Archive | `https://github.com/dpirch/libfvad/archive/532ab666c20d3cfda38bca63abbb0f152706c369.tar.gz` |
| Archive sha256 | `bf639e4a5bc37b1c90e047c42524e80a1d0cecadeb6e0a61a33580fca22a00ab` (940253 bytes; two downloads identical) |
| License | BSD-3-Clause (`LICENSE`: The WebRTC project authors, Daniel Pirch) plus the WebRTC patent grant (`PATENTS`) |
| Imported | 2026-11-04 |
| Local changes | none: every file below is byte-identical to the archive |

Kept (24 files): `AUTHORS`, `LICENSE`, `PATENTS`, `include/fvad.h`, `src/common.h`, `src/fvad.c`,
`src/signal_processing/*` (10 files), `src/vad/*` (8 files).

Left out: the build systems (CMake, autotools, `debian/`, `libfvad.pc.in`), `examples/`, `tests/`
(with their WAV fixtures) and `tools/` (upstream's WebRTC import scripts). SwiftPM compiles the kept
`.c` files as part of the CAudioCore target; `src/fvad.c` reaches its header by the relative path
`../include/fvad.h`, so no extra header search path is needed. The library headers are not in
CAudioCore's public `include/` and are not visible to Swift.

Known upstream quirk: UndefinedBehaviorSanitizer reports "left shift of negative value" in
`src/signal_processing/resample_by_2_internal.c` (lines 141 and 173, the WebRTC fixed-point
resampler, `((int32_t)in[i << 1] << 15)` on negative samples). Clang on arm64 and x86_64
compiles it to the arithmetic shift the code expects, SwiftPM builds do not enable UBSan, and
the file is kept byte-identical rather than patched. Local harnesses built with `-fsanitize=undefined` print
these two lines and nothing else (checked 2026-11-04).

Known upstream bug, avoided rather than patched: `WebRtcVad_CalcVad48khz`
(`src/vad/vad_core.c`, the loop at line 618) resamples `speech_frame` itself for every 10 ms
chunk instead of `speech_frame + i * kFrameLen10ms48khz`, so at 48 kHz a 20 or 30 ms frame is
judged by its first 10 ms (repeated). `tt_vad_create` refuses 48000; §3.2 runs the VAD on the
16 kHz mic stream.

To update: download the archive of the new commit twice, compare the sha256, copy the same file
set, check that nothing else changed with `cmp`, update this file and run
`scripts/check-licenses.sh` and `scripts/check.sh`.
