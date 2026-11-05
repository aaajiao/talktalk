# TalkTalk development rules

Design authority: `docs/ARCHITECTURE.md`. Keep it aligned with behavior changes.
Current scope and open acceptance work: `docs/remaining-work.md`.

## Validation

- Keep changes and checks proportional. Do not add redundant tests or run stress/soak tests unless requested.
- `scripts/check.sh --skip-stress` runs the existing functional checks; focused checks are sufficient for small changes.
- After editing `scripts/lib/versions.sh`, run `scripts/gen-pins.sh`.
- Generate model pins with `scripts/pin-model.sh` and lock files with `scripts/lock-deps.sh`; do not invent hashes.
- Distinguish unit/build checks from real microphone, driver, cloud and meeting acceptance.

## Environment and privacy

- Use Swift 6.2+ and the macOS SDK. `scripts/build-app.sh release` creates the normal app; only explicit dev builds enable development hooks.
- Launch permission-requiring flows through LaunchServices (`open -a …`), not a bare executable.
- Engine Python runs as `venv/bin/python3 -I -B`, using the app-managed runtime.
- Shell scripts target macOS Bash 3.2. Use absolute paths for system tools.
- Never read, print, log or copy API keys. Users enter them in the app and handle Keychain prompts themselves.
- Do not inspect or change unrelated applications' files, secrets, processes or permissions.
- Keep voice recordings, transcripts, models, raw diagnostics and benchmark results out of Git.
- Arrange microphone capture, cloud requests, large downloads, driver installation/removal, audio-service restart and system permission changes with the user first.

## Publishing

- Commit locally by default. Push only when the user explicitly authorizes the destination.
- The public branch is `main`. Earlier local development branches/tags contain private diagnostics and must not be pushed; never use `git push --all` or `--mirror`.
- Preserve third-party notices, LICENSE, PATENTS and attribution files.
