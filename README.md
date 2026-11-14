# TalkTalk

**English** | [简体中文](README.zh-CN.md)

![TalkTalk subtitle settings and bilingual meeting conversation preview](docs/images/talktalk-subtitles.png)

**Subtitles and voice translation in Chinese, English, German, and French for meetings, phone calls, and videos.**

TalkTalk is a native macOS menu bar app. Speech recognition and synthesis run locally, with OpenAI or Apple available for text translation. Speak with your own cloned voice or choose a macOS system voice.

## Three ways to use TalkTalk

| Mode | How it works |
|---|---|
| Meeting interpretation | Listen to a selected meeting app and see the original speech alongside its translation. Send your original or translated voice through **TalkTalk Mic**. |
| Phone interpretation | Connect to the macOS **Phone** app. Prepare interpretation in TalkTalk, then make or answer a call in Phone. Ending interpretation in TalkTalk does not hang up the call. |
| Video subtitles | Listen to a selected video or browser app and display bilingual subtitles, without enabling the microphone or generating translated speech. Browser capture includes audio from the whole app, not just one tab. |

- **Listening subtitles** support all twelve translation directions between Chinese, English, German, and French. Each mode remembers its own audio source and language direction; Phone mode always uses the Phone app.
- **Translated speech** supports Chinese, English, or French as the spoken language, translating into any of the other three languages (nine directions). Meeting and Phone modes each have their own speaking language setting and send your original voice by default. Tap **right ⌥ (Option)** to start speaking for translation, then tap again to finish. Your original voice resumes after the remaining translated audio finishes playing.
- **Bilingual subtitles** appear as a conversation timeline in Meeting and Phone modes. Video mode shows paginated sentence pairs, with drafts updated in place as final translations arrive. The video subtitle window appears only once original or translated text is available. Windows can be moved, resized, hidden, or minimized. Hiding a window keeps the session running, and new subtitles do not reopen a window you have hidden or minimized.
- **Local voice cloning** reuses your recorded voice profile across Qwen and Ming. Each model keeps its own voice cache and preview volume calibration.

The interface supports English and Chinese. Switch instantly in **Settings › General › Interface language**. The interface language is independent of your subtitle and speaking language settings.

## Get started

Requires an **Apple Silicon Mac running macOS 26.4 or later**. Use headphones for meeting and phone interpretation.

**[Download TalkTalk 1.0.21, build 88 (macOS arm64 ZIP)](https://github.com/aaajiao/talktalk/releases/download/v1.0.21/TalkTalk-1.0.21-macOS-arm64.zip)** · [Release notes](https://github.com/aaajiao/talktalk/releases/tag/v1.0.21)

Unzip the download, drag `TalkTalk.app` into Applications, and open it from Finder. The app is **ad-hoc signed, without a Developer ID signature or Apple notarization**. macOS may display a security warning or block the first launch; verify the download source and follow the system prompts.

From version 1.0.18, use **Check for Updates…** in the menu bar menu or **Settings › General › App Updates**. GitHub hosts the signed update feed and packages; you choose when to download and restart. Updates wait for interpretation, recordings and maintenance to finish. Version 1.0.17 and earlier need one manual installation to get the updater.

First-time setup:

1. Follow onboarding to grant permissions and configure the speech resources you need. Chinese and English are required Apple speech resources; German and French are optional. Meeting and phone interpretation also require the **TalkTalk Mic** virtual microphone. For video subtitles only, choose the listening-only setup.
2. The app installs its private Python runtime and local models as needed. **You do not need to install system Python or Homebrew.** The default meeting/phone model files take about **4.1 GB**, plus space for the runtime. Later upgrades reuse compatible runtimes and downloaded models.
3. In **Settings › Scenarios**, choose Meeting, Phone, or Video and configure the app and languages. In your meeting or phone app, select **TalkTalk Mic** as the input, or follow onboarding to use the system default input managed by TalkTalk.
4. For cloud text translation, enter your own OpenAI API key. For local Apple translation, install the required language resources first.
5. To use your own voice, record and preview it in **My voice**. Download or delete models in **Components**, and switch between installed synthesis models in **Models › Synthesis**.

Video mode listens only to the selected app by default. Explicitly enabling the global capture fallback captures audio from all apps. Your meeting app still controls muting. When you stop interpretation or quit TalkTalk, it restores the system input it managed.

Video-only onboarding prepares the private Python runtime, shared dependencies, and Qwen3-ASR (0.6B for a new installation), then checks actual Qwen recognition. It does not download synthesis models, install TalkTalk Mic, require a voice recording, or request microphone permission. Apple speech resources remain available as fallback, with a visible status when Qwen is unavailable. Existing models and recognition choices are kept; users who selected Apple Speech can continue using it. Downloads can be cancelled and resumed by retrying. Adding speech synthesis for meetings or calls later reuses the existing models and runtime.

## Local models and voices

Qwen remains the default. Three speech resource presets are available. Sizes below cover model files only, excluding the runtime and memory usage:

| Preset | Speech synthesis | Speech recognition | File size |
|---|---|---|---:|
| Max | Qwen3-TTS 1.7B | Qwen3-ASR 1.7B | 5.6 GB |
| Standard (default) | Qwen3-TTS 1.7B | Qwen3-ASR 0.6B | 4.1 GB |
| Lightweight | Qwen3-TTS 0.6B | Qwen3-ASR 0.6B | 3.0 GB |

Qwen uses pinned local 8-bit models. You can independently choose **Ming-3.0-TTS 0.5B (BF16, about 3.0 GB)** for synthesis, with no Ming API required. Switching changes only the synthesis model, preserving your recognition model, translation settings, subtitle and playback behavior, and downloaded Qwen files.

The synthesis menu lists only models installed and available on your Mac. Download other models in **Components** first; repair is available if the current model has missing files. Wait for any active session, recording, or preview to finish before switching. The first time you use another model, TalkTalk builds its voice cache from your existing recording.

Apple Speech can be selected independently in **Models › Recognition**, with separate choices for **Listen to others** and **My speech**. It can also serve as a fallback when Qwen recognition is unavailable. Selecting Apple does not run the model installer or change the synthesis model. Older synthesis-only installations remain compatible.

The runtime and models live in `~/Library/Application Support/TalkTalk/engine`. Compatible downloaded models are reused. Deleting a model requires confirmation in Components; deleting the active model does not automatically switch to another downloaded model.

## Data and privacy

| Step | Model or service |
|---|---|
| Audio → original text | Local Qwen3-ASR or Apple Speech |
| Original text → translation | OpenAI (with your own key) or Apple Translation |
| Translation → speech | Local Qwen3-TTS/Ming-3.0-TTS or a macOS system voice |

Audio and voice profiles are processed locally. When OpenAI is enabled, original text, translation context, and glossary entries are sent to OpenAI. Your API key is stored in macOS Keychain. Meeting recordings and transcripts are not saved by default; transcript logging, subtitle analysis, and diagnostic recording must be explicitly enabled.

System voices and third-party components are subject to their own licenses. See the [licensing notes](docs/decisions/licensing.md) (in Chinese).

## Build from source

Requires Xcode Command Line Tools with Swift 6.2 or later:

```bash
git clone https://github.com/aaajiao/talktalk.git
cd talktalk
scripts/setup-dev-python.sh
scripts/check.sh --skip-stress
scripts/build-app.sh release
```

The release app is generated at `build/TalkTalk.app`. The packaging script automatically increments the build number; the release version is maintained separately. A local build does not create a published GitHub Release. Follow the [release workflow](docs/releases.md) to publish the signed ZIP, appcast and checksums together.

The private runtime currently uses **CPython 3.14.10**. The app bundles the engine code and installer, then installs the interpreter and dependencies into a dedicated directory. Its virtual environment does not load system Python packages. Development uses the repository's `.venv`, with the interpreter pinned in `.build/dev-python`, sharing model pins and dependency lockfiles with the app. Run the setup script before checks or packaging.

`scripts/check.sh` creates an isolated temporary directory for each run and cleans it up automatically. Swift file fixtures use `@Suite(.temporaryFiles)` and `TestTemporaryDirectory.make(prefix:)`; Python uses `TemporaryDirectory`. Cleanup applies only to files created by tests. Routine checks do not replace validation with real microphones, the driver, cloud services, and calls.

## Development and validation status

Local voice recording, previews, and Qwen/Ming switching have been verified in actual use. Long meetings, audio heard by the person on the other end of a phone call, and compatibility across apps and devices still require scenario-specific validation. Local synthesis and automated tests do not substitute for complete call testing.

Further documentation (in Chinese):

- [Architecture and development constraints](docs/ARCHITECTURE.md)
- [Validation status and remaining work](docs/remaining-work.md)
- [Validation history](docs/validation-history.md)
- [Maintenance, diagnostics, and uninstalling](docs/maintenance.md)

## License

Project code is licensed under the [MIT License](LICENSE). Third-party code, models, and system services retain their own licenses; see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md).
