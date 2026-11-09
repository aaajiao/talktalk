# shellcheck shell=bash
# shellcheck disable=SC2034  # sourced: every variable here is read by install-engine.sh / gen-pins.sh
# talktalk pins: the single source of truth (ARCHITECTURE.md §7.2). Sourced, never executed.
# Regenerate model blocks with scripts/pin-model.sh, lock hashes with scripts/lock-deps.sh,
# then run scripts/gen-pins.sh (check.sh fails when EnginePins.swift is out of sync).

# Application identity; independent of engine API/recipe and model revisions.
TT_APP_VERSION="1.0.16"
TT_APP_BUILD="77"

# Standalone CPython (astral-sh/python-build-standalone). Size and sha256 checked against the
# GitHub release asset digest on 2026-11-07; dedicated, ordinary (GIL) CPython build.
TT_PY_VERSION="3.14.10"; TT_PY_RELEASE="20261026"
TT_PY_ASSET="cpython-${TT_PY_VERSION}+${TT_PY_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
TT_PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TT_PY_RELEASE}/cpython-${TT_PY_VERSION}%2B${TT_PY_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
TT_PY_SIZE=26891793; TT_PY_SHA256="30a18bcb9ab75e485b4bf4e5d783dde165571e7e42c56dff47a2d2c5345183a4"

TT_ENGINE_RECIPE=1        # bump when the way python/ or venv/ is built changes (invalidates them)
TT_ENGINE_API=2           # engine wire protocol (§4.4); v2 removed /v1/mt*
# mlx-audio: commit f65753b (merge of #1117) on top of v0.6.4 (which already has #1096). See m0-results.md.
TT_MLX_AUDIO_COMMIT="f65753b55f011f4cc8b1dbc7622ae8110b7b7fbb"
TT_LOCK_SHA256="349c6c6ca785f6e2717caba43f4bdf336c42264c9a442468205bcc62e925cdd7"
TT_BUILD_LOCK_SHA256="b1361fb1b329fa4c6973a983539168c102ef2397cd207ec03b5bfcbf5b1bb8a8"   # setuptools + wheel for the mlx-audio sdist (--no-build-isolation)
TT_LOCK_COMPAT="349c6c6ca785f6e2717caba43f4bdf336c42264c9a442468205bcc62e925cdd7"   # lock sha256s the bundled engine code can run on (current, previous)
TT_RUNTIME_FLAVOURS="main"   # reserved: "alt-tts" (§7.6), not installed in v1

TT_MODELS="tts-qwen3-1.7b-base-8bit tts-qwen3-0.6b-base-8bit tts-ming3-0.5b-bf16 asr-qwen3-0.6b-8bit asr-qwen3-1.7b-8bit"   # no MT (§16 decision 12)
TT_PROFILE_MAX="tts-qwen3-1.7b-base-8bit asr-qwen3-1.7b-8bit"
TT_PROFILE_STANDARD="tts-qwen3-1.7b-base-8bit asr-qwen3-0.6b-8bit"
TT_PROFILE_COMPACT24="tts-qwen3-0.6b-base-8bit asr-qwen3-0.6b-8bit"
TT_PROFILE_COMPACT16="tts-qwen3-0.6b-base-8bit"                     # no ASR: SPEAK final via Apple
TT_LICENSE_ALLOW="Apache-2.0 MIT"; TT_MODEL_DENY="tencent/HY-MT"

# tts-qwen3-1.7b-base-8bit  (3104157269 bytes, pinned 2026-11-04)
TT_M_TTS_QWEN3_1_7B_BASE_8BIT_REPO="mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
TT_M_TTS_QWEN3_1_7B_BASE_8BIT_REVISION="e7dd0585652209fa0d7783659aad4e8a324de11c"
TT_M_TTS_QWEN3_1_7B_BASE_8BIT_ROLE="tts"; TT_M_TTS_QWEN3_1_7B_BASE_8BIT_LICENSE="Apache-2.0"
TT_M_TTS_QWEN3_1_7B_BASE_8BIT_FILES="
README.md 1026 7e03a5e92d1cd6208630c228e0b2fbf9b5de2035ebe189a7fc812a3453422c8c
config.json 5522 b14fba6bfd391968876248b843b095696b0188187a3d774a3bddc32544d15627
generation_config.json 245 f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa
merges.txt 1671839 599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3
model.safetensors 2417320525 b965c581ccf6aa852a4124feeb7a8a111542ee7b213139368b4cc7ba7fd4728b
model.safetensors.index.json 78070 9592a7c0ac3261a6211978416ef1796d3841225ac0ff0f9d6bfb5d1a6b49e5e9
preprocessor_config.json 127 efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119
speech_tokenizer/config.json 2336 ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167
speech_tokenizer/configuration.json 76 6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd
speech_tokenizer/model.safetensors 682293092 836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258
speech_tokenizer/preprocessor_config.json 234 fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb
tokenizer_config.json 7344 dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
TT_M_TTS_QWEN3_1_7B_BASE_8BIT_COMPAT_REVISIONS=""

# tts-qwen3-0.6b-base-8bit  (1991297619 bytes, pinned 2026-11-04)
TT_M_TTS_QWEN3_0_6B_BASE_8BIT_REPO="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
TT_M_TTS_QWEN3_0_6B_BASE_8BIT_REVISION="50f45ef0047cde7e84c2ef04326acb8ada2436a7"
TT_M_TTS_QWEN3_0_6B_BASE_8BIT_ROLE="tts"; TT_M_TTS_QWEN3_0_6B_BASE_8BIT_LICENSE="Apache-2.0"
TT_M_TTS_QWEN3_0_6B_BASE_8BIT_FILES="
README.md 1026 29acd85b1992a608daab6cf532606aef3f28cf6ee836eb039b47a918eed93b37
config.json 5522 b404fb6f99dac6f7a81f3a03af5675b131ecf9936ac75a7c9d75e54044600044
generation_config.json 245 f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa
merges.txt 1671839 599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3
model.safetensors 1304461214 9488e7005cc0cf44f8804eb543668d0763bb1c649ce6f1eddc663519524b3182
model.safetensors.index.json 77731 7829f1cc24f5cbd7d7a3ba888bb08c7cf52d82ba79a4f0f3756d41f8bf5e52b4
preprocessor_config.json 127 efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119
speech_tokenizer/config.json 2336 ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167
speech_tokenizer/configuration.json 76 6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd
speech_tokenizer/model.safetensors 682293092 836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258
speech_tokenizer/preprocessor_config.json 234 fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb
tokenizer_config.json 7344 dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
TT_M_TTS_QWEN3_0_6B_BASE_8BIT_COMPAT_REVISIONS=""

# tts-ming3-0.5b-bf16 (MLX snapshot + native CAMPPlus companion, pinned 2026-11-07)
TT_M_TTS_MING3_0_5B_BF16_REPO="mlx-community/Ming-3.0-tts-0.5B-bf16"
TT_M_TTS_MING3_0_5B_BF16_REVISION="283b3c342c6fb69a7a87832c97f9799567efe05d"
TT_M_TTS_MING3_0_5B_BF16_ROLE="tts"; TT_M_TTS_MING3_0_5B_BF16_LICENSE="MIT"
TT_M_TTS_MING3_0_5B_BF16_FILES="
LICENSE 1067 2872f1918dfc04fdeb7f5d66d8d1b773594c9375e7c8f7bda39780bb97ad4fba
README.md 4245 676ba46672b6f6d7f997be010bb84bc2cc38ef8b90ffd7f982c58ae8078b9911
added_tokens.json 1785 34394b1e16d7da2db16618bd43a0f970902ade0075480bcd812fe62d559ec319
campplus.safetensors 27699096 a479586bd8f8f96cdb414eaa2fa07c6cd54d6d1636562e2d75a0211cb3b0a6fd
config.json 5882 6205fe41f5f7591e2f0d666b20464a79a983097f67e91341bfad159edca1d33e
configuration.json 51 6720b8448f6ad5b4631689a60857bdeb238053a37f6cc6a5936eb50c2a3b9296
merges.txt 1671853 8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5
model.safetensors 2959055287 16a7086c992a6eab7d855df90c9c2edbb0f4f3a702b3cd697f6011e198d0c8b4
model.safetensors.index.json 96296 b229302f1ce86b91adcf5491bfdaee1ff0559a518b0cf3766d8d6f241eb64bf8
special_tokens_map.json 2726 2c2ec51b9da5db654ac20de8310350d0c9c1a65918ae0181b80dacd2919b4fc3
tokenizer.json 11431389 87d54ca3b44ea2f822ba39a0a45cb1b61644bd6606d9d3536dea75367bffb06d
tokenizer_config.json 16260 12d6162c815edef24f8606e65b60d43fe0d92b0a4e150a0db8fa01c523aaf36a
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
speaker_encoder/campplus.safetensors 27697145 373f95ba31457cb1c54a94ce350b000c977d24aa9273c4b535e8a2dcadeaf31e
"
TT_M_TTS_MING3_0_5B_BF16_COMPAT_REVISIONS=""
# This is the byte-identical source CAMPPlus encoder converted to native MLX layouts.
# The root campplus file keeps the original conversion layout; inference uses this companion.
TT_M_TTS_MING3_0_5B_BF16_FILE_SOURCES="
speaker_encoder/campplus.safetensors mlx-community/Step-Audio-2-token2wav e21026b660069e6d1b9ac5c9a51e08ed0201f30e campplus.safetensors
"

# asr-qwen3-0.6b-8bit  (1010772242 bytes, pinned 2026-11-04)
TT_M_ASR_QWEN3_0_6B_8BIT_REPO="mlx-community/Qwen3-ASR-0.6B-8bit"
TT_M_ASR_QWEN3_0_6B_8BIT_REVISION="89e96d92ba34aca20b3e29fb10cc284097d1219f"
TT_M_ASR_QWEN3_0_6B_8BIT_ROLE="asr"; TT_M_ASR_QWEN3_0_6B_8BIT_LICENSE="Apache-2.0"
TT_M_ASR_QWEN3_0_6B_8BIT_FILES="
README.md 1008 404c9125240861c9c8c23f2452e7140a9664d8393900b42bb0a411dc15abf79c
chat_template.json 1161 75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff
config.json 7187 5d104a945fed08728ab010f12bf3ce5ab4d0794bba276d81bff5bd83ae9d2be0
generation_config.json 142 1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c
merges.txt 1671853 8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5
model.safetensors 1006229426 b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8
model.safetensors.index.json 71815 caa32ece76c395ba241533eb4aceb0efbc72488ef3d8d2fd3c677ce068dad57d
preprocessor_config.json 330 45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d
tokenizer_config.json 12487 4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
TT_M_ASR_QWEN3_0_6B_8BIT_COMPAT_REVISIONS=""

# asr-qwen3-1.7b-8bit  (2467857511 bytes, pinned 2026-11-04)
TT_M_ASR_QWEN3_1_7B_8BIT_REPO="mlx-community/Qwen3-ASR-1.7B-8bit"
TT_M_ASR_QWEN3_1_7B_8BIT_REVISION="a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
TT_M_ASR_QWEN3_1_7B_8BIT_ROLE="asr"; TT_M_ASR_QWEN3_1_7B_8BIT_LICENSE="Apache-2.0"
TT_M_ASR_QWEN3_1_7B_8BIT_FILES="
README.md 1008 b356d4bdfbe7287b06b9b5ad084d9557a24ca98ca277a839beb2e682037b08f6
chat_template.json 1161 75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff
config.json 7188 1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7
generation_config.json 142 1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c
merges.txt 1671853 8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5
model.safetensors 2463307541 bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c
model.safetensors.index.json 78968 0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5
preprocessor_config.json 330 45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d
tokenizer_config.json 12487 4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
TT_M_ASR_QWEN3_1_7B_8BIT_COMPAT_REVISIONS=""


# TalkTalkAudio.driver and the device UIDs (M0-T8; moved here from Driver/versions.env 2026-11-04).
# gen-pins.sh turns these into Sources/TalkTalkCore/Generated/DriverPins.swift and
# Driver/Sources/Generated/DriverPins.hpp; build-driver.sh and install-driver.sh source this file.
TT_DRIVER_VERSION="0.2.3"
TT_DRIVER_BUNDLE_ID="com.aaajiao.talktalk.audio-driver"
TT_DRIVER_BUNDLE_NAME="TalkTalkAudio.driver"
TT_DRIVER_EXECUTABLE="TalkTalkAudio"
TT_DRIVER_FACTORY_UUID="08A86F06-758E-4D5C-BA5C-771C7C14E222"
TT_DRIVER_FACTORY_FUNC="TalkTalkAudio_Create"
TT_DRIVER_MIN_MACOS="26.0"
TT_DRIVER_FEED_UID="com.aaajiao.talktalk.feed"
TT_DRIVER_MIC_UID="com.aaajiao.talktalk.mic"
TT_DRIVER_TESTMIC_UID="com.aaajiao.talktalk.testmic"
TT_DRIVER_OWN_UID_PREFIX="com.aaajiao.talktalk"   # every UID we create (Feed, Mic, Test Mic, taps): == this or starts with this + "."
TT_DRIVER_TAP_UID_PREFIX="${TT_DRIVER_OWN_UID_PREFIX}.tap."   # private tap aggregates (MeetingTap)
# Custom properties on TalkTalk Feed (four-character selectors; §8.3, docs/decisions/m0-t8-driver.md):
TT_DRIVER_DIAG_SELECTOR="ttdg"           # diagnostics, CFDictionary, read-only
TT_DRIVER_MEETING_MODE_SELECTOR="ttmm"   # meeting-mode switch, CFNumber 0/1; writable by accepted Feed clients only
# libASPL, vendored under Driver/third_party/libASPL (MIT; upstream file hashes in
# Driver/third_party/libASPL/UPSTREAM-SHA256SUMS).
TT_LIBASPL_VERSION="3.1.2"
TT_LIBASPL_COMMIT="47f688ed6bb637ab8b7f4b36864734b2b1f69b6b"
TT_LIBASPL_URL="https://github.com/gavv/libASPL"
# libfvad (rt-core): TT_LIBFVAD_* go here when it is vendored.
