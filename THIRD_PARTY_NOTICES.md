# Third-party notices

TalkTalk's own source code is available under the [MIT License](LICENSE). Third-party code,
model weights and macOS services retain their own licenses; the project's MIT license does not
replace those terms.

The source repository includes libfvad and libASPL. An app built with the provided scripts carries
the engine sources, libfvad compiled into the app, Sparkle.framework with its updater helpers,
and TalkTalkAudio.driver with libASPL compiled in. The installer downloads the other artifacts listed below from their upstreams onto the user's
machine. See [licensing notes](docs/decisions/licensing.md) and the
[license gate](scripts/check-licenses.sh).

| Component | Where it comes from | License |
|---|---|---|
| CPython 3.14 (python-build-standalone) | github.com/astral-sh/python-build-standalone | PSF-2.0 (+ notices inside the distribution) |
| mlx, mlx-metal | PyPI | MIT |
| mlx-audio (pinned commit) | github.com/Neywa-Labs/mlx-audio | MIT |
| transformers | PyPI | Apache-2.0 |
| numpy | PyPI | BSD-3-Clause |
| other locked Python packages | PyPI, see `engine/requirements-engine.lock` | per package (METADATA), checked by `check-licenses.sh` against the installed engine venv |
| Qwen3-TTS / Qwen3-ASR MLX weights | huggingface.co/mlx-community | Apache-2.0 |
| Ming-3.0-TTS 0.5B BF16 MLX weights | huggingface.co/mlx-community/Ming-3.0-tts-0.5B-bf16 | MIT (upstream LICENSE included in the downloaded model) |
| Native CAMPPlus speaker encoder used with Ming | huggingface.co/mlx-community/Step-Audio-2-token2wav | Apache-2.0 |
| libASPL 3.1.2 (compiled into TalkTalkAudio.driver, which the app bundle carries) | github.com/gavv/libASPL | MIT, full text below |
| libfvad (VAD, compiled into the app) | github.com/dpirch/libfvad, vendored in `Sources/CAudioCore/third_party/libfvad/` | BSD-3-Clause + WebRTC patent grant |
| Sparkle 2.10.1 (framework and updater helpers, embedded in the app) | github.com/sparkle-project/Sparkle, pinned Swift Package Manager binary distribution | MIT-style license and bundled external licenses |

macOS system voices (`say`, `AVSpeechSynthesizer`) are subject to the applicable macOS license,
including its voice-use restrictions. TalkTalk's MIT license grants no rights to Apple's voices or
their output. Consult the license supplied with your macOS version and
[Apple's software license agreements](https://www.apple.com/legal/sla/); see also
[the system-voice notes](docs/decisions/licensing.md#macos-system-voices).

## Sparkle

Application updates use [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1).
The app carries the upstream framework and helper tools in `Contents/Frameworks/Sparkle.framework`.
The complete upstream copyright and license notices, including bsdiff, sais-lite, Ed25519 and
SUSignatureVerifier notices, are included unchanged in `Contents/Resources/Licenses/Sparkle-LICENSE.txt`.
The source distribution retains the same [upstream license](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE).

## libASPL

TalkTalkAudio.driver (`Contents/Resources/driver/` in the app bundle, installed to
`/Library/Audio/Plug-Ins/HAL/`) is built from vendored libASPL v3.1.2
(commit 47f688ed6bb637ab8b7f4b36864734b2b1f69b6b, `Driver/third_party/libASPL`). The driver
bundle also carries this text as `Contents/Resources/libASPL-LICENSE.txt`.

The vendored source also retains [AUTHORS.md](Driver/third_party/libASPL/AUTHORS.md) and the
Apple sample-code notices [LICENSE.apple2012](Driver/third_party/libASPL/LICENSE.apple2012) and
[LICENSE.apple2020](Driver/third_party/libASPL/LICENSE.apple2020).

```
The MIT License (MIT)

Copyright (c) Victor Gaydov and contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## libfvad

Voice activity detection uses libfvad, the WebRTC VAD as a standalone C library, vendored
unmodified at commit `532ab666c20d3cfda38bca63abbb0f152706c369`
([VENDOR.md](Sources/CAudioCore/third_party/libfvad/VENDOR.md)) and compiled into the app.

The full [BSD-3-Clause license](Sources/CAudioCore/third_party/libfvad/LICENSE) and
[WebRTC patent grant](Sources/CAudioCore/third_party/libfvad/PATENTS) are reproduced below so
they accompany compiled distributions through this notice. The source retains the
[authors list](Sources/CAudioCore/third_party/libfvad/AUTHORS).

```
Copyright (c) 2011, The WebRTC project authors. All rights reserved.
Copyright (c) 2016 Daniel Pirch

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

```
Additional IP Rights Grant (Patents)

"This implementation" means the copyrightable works distributed by
Google as part of the WebRTC code package.

Google hereby grants to you a perpetual, worldwide, non-exclusive,
no-charge, irrevocable (except as stated in this section) patent
license to make, have made, use, offer to sell, sell, import,
transfer, and otherwise run, modify and propagate the contents of this
implementation of the WebRTC code package, where such license applies
only to those patent claims, both currently owned by Google and
acquired in the future, licensable by Google that are necessarily
infringed by this implementation of the WebRTC code package. This
grant does not include claims that would be infringed only as a
consequence of further modification of this implementation. If you or
your agent or exclusive licensee institute or order or agree to the
institution of patent litigation against any entity (including a
cross-claim or counterclaim in a lawsuit) alleging that this
implementation of the WebRTC code package or any code incorporated
within this implementation of the WebRTC code package constitutes
direct or contributory patent infringement, or inducement of patent
infringement, then any patent rights granted to you under this License
for this implementation of the WebRTC code package shall terminate as
of the date such litigation is filed.
```

## Engine wheels with bundled libraries

scipy (a dependency of mlx-audio) ships in its macOS wheel libgfortran and libgcc_s
(GPL-3.0-or-later WITH GCC-exception-3.1, the GCC Runtime Library Exception) and libquadmath
(LGPL-2.1-or-later) as separate dylibs under `scipy/.dylibs/`. They live only in the external engine
venv, are installed from PyPI on the user's machine and are dynamically linked. numpy's license
file lists the same bundled libraries. The license gate (`scripts/check-licenses.sh`) accepts the
GCC runtime library exception and has `numpy:libquadmath` and `scipy:libquadmath` on its LGPL
whitelist.
