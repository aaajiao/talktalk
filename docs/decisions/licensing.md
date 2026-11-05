# Licensing

TalkTalk's own source code is published under the [MIT License](../../LICENSE). Vendored code,
downloaded models, runtime dependencies and macOS services remain subject to their respective
licenses. The MIT license does not relicense those components or grant rights to voices, recordings
or other user-provided material.

[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) identifies the dependencies and retains
the libASPL and libfvad license texts. Recheck the applicable notices when changing a dependency,
model revision or distribution format.

## macOS system voices

TalkTalk can use `say` for locally generated installation samples and `AVSpeechSynthesizer` when
no custom voice profile is available. Apple supplies these voices under the applicable macOS
software license, including its voice-use restrictions. The project's MIT license does not grant
permission to record, share or use system-voice output in a particular context.

Review the license supplied with your macOS version and
[Apple's software license agreements](https://www.apple.com/legal/sla/). The license accompanying
an installed product may differ from the version currently published online. TalkTalk's settings
display a system-voice licensing reminder; that reminder is not a separate grant of rights.

System-generated installation and benchmark audio is created locally, not committed to this
repository or bundled with the app. Personal Voice is not used. A custom voice profile and its
recordings remain the user's responsibility; the project license does not grant rights to another
person's voice.

## Models

The pinned Qwen models are recorded as Apache-2.0 in
[scripts/lib/versions.sh](../../scripts/lib/versions.sh), based on their upstream model cards:
Qwen3-TTS-12Hz-1.7B-Base-8bit, Qwen3-TTS-12Hz-0.6B-Base-8bit, Qwen3-ASR-0.6B-8bit and
Qwen3-ASR-1.7B-8bit. The benchmark-only Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit pin is in
[tools/bench/bench-pins.sh](../../tools/bench/bench-pins.sh). Model weights are downloaded separately
and are not relicensed under TalkTalk's MIT license.

The license gate accepts the configured Apache-2.0 and MIT model licenses. `tencent/HY-MT*`
remains excluded by the project's model deny list.

## Python runtime and packages

- CPython from python-build-standalone: PSF-2.0 and the additional notices included in that distribution.
- mlx, mlx-metal and the pinned mlx-audio revision: MIT.
- transformers: Apache-2.0; numpy: BSD-3-Clause, with bundled-library notices.
- Other packages: see [requirements-engine.lock](../../engine/requirements-engine.lock),
  [requirements-build.lock](../../engine/requirements-build.lock) and each installed package's metadata.

The installer downloads the private interpreter and packages from their upstreams into a separate
runtime on the user's machine; they are not included in the app bundle. The
[license gate](../../scripts/check-licenses.sh) checks the installed runtime's package metadata.
It rejects unapproved GPL/AGPL dependencies, recognizes the GCC Runtime Library Exception, and
explicitly allows the libquadmath LGPL notices in the numpy and scipy wheels. These dependencies
retain their original licenses; the gate is a project policy check, not a replacement for those terms.

## Vendored code and distribution

libASPL is compiled into TalkTalkAudio.driver, and libfvad is compiled into the app. These components
are distributed with the source and with app builds, unlike the separately downloaded Python runtime
and model weights.

- libASPL: retain its [MIT license](../../Driver/third_party/libASPL/LICENSE),
  [Apple 2012 notice](../../Driver/third_party/libASPL/LICENSE.apple2012),
  [Apple 2020 notice](../../Driver/third_party/libASPL/LICENSE.apple2020),
  [authors](../../Driver/third_party/libASPL/AUTHORS.md) and upstream provenance files.
- libfvad: retain its [BSD-3-Clause license](../../Sources/CAudioCore/third_party/libfvad/LICENSE),
  [WebRTC patent grant](../../Sources/CAudioCore/third_party/libfvad/PATENTS),
  [authors](../../Sources/CAudioCore/third_party/libfvad/AUTHORS) and
  [vendor record](../../Sources/CAudioCore/third_party/libfvad/VENDOR.md).

The app packaging script copies THIRD_PARTY_NOTICES.md into the app, and the driver also carries
the libASPL MIT text. Keep these notices with redistributed builds and preserve the vendored source
notices when modifying or republishing the repository.
