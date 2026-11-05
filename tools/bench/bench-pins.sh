# shellcheck shell=bash
# shellcheck disable=SC2034  # sourced by tools/bench/fetch-bench-models.sh and cleanup.sh
# Bench-only model pins (ARCHITECTURE.md §14 M0 day 1). Installed under
# ~/Library/Application Support/TalkTalk-bench/ and deleted by tools/bench/cleanup.sh at the end of M0.
# Same pinning discipline as scripts/lib/versions.sh (40-char revision, per-file bytes + sha256).
# Formal models that M0 also installs into the bench dir (asr-qwen3-1.7b-8bit for T5) keep their
# pins in versions.sh.

TB_BENCH_MODELS="tts-qwen3-1.7b-customvoice-8bit"

# tts-qwen3-1.7b-customvoice-8bit  (3080140019 bytes, pinned 2026-11-04)
TT_M_TTS_QWEN3_1_7B_CUSTOMVOICE_8BIT_REPO="mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
TT_M_TTS_QWEN3_1_7B_CUSTOMVOICE_8BIT_REVISION="41d3337e8b7f2843a75841595fc14e4b9a7a4b96"
TT_M_TTS_QWEN3_1_7B_CUSTOMVOICE_8BIT_ROLE="tts"; TT_M_TTS_QWEN3_1_7B_CUSTOMVOICE_8BIT_LICENSE="Apache-2.0"
TT_M_TTS_QWEN3_1_7B_CUSTOMVOICE_8BIT_FILES="
README.md 1118 50fe8f13fc95466beb50a96ae743e40573512754e80330373a043f4bd34d6212
config.json 6058 43f29f9ab55cf387bd2ce1d07e9d95a5ca8974fa2fda4e2b45c13ae64aad3bfa
generation_config.json 245 f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa
merges.txt 1671839 599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3
model.safetensors 2393308931 b696f4bf45f54497b6de758981e76f1410bd68af05a657477dee466b0202df1a
model.safetensors.index.json 71786 2551ed02dc288b90cd6b7ec98652433f08ef2ae98fb3eda5248a4b9e5b47d08b
preprocessor_config.json 127 efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119
speech_tokenizer/config.json 2336 ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167
speech_tokenizer/configuration.json 76 6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd
speech_tokenizer/model.safetensors 682293092 836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258
speech_tokenizer/preprocessor_config.json 234 fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb
tokenizer_config.json 7344 dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670
vocab.json 2776833 ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910
"
