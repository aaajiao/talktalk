import Foundation

// Dispatch targets of `--bench enroll` and `--bench record` (ARCHITECTURE.md §9.2, §14 M0).
// Both exist only in the dev build. Like every entry that touches TCC (§2.2), start them through
// LaunchServices so the microphone prompt and grant belong to TalkTalk-Dev.app:
//
//   open -W -n -a "$PWD/build/TalkTalk-Dev.app" --args --bench enroll [--out <file>] [--smoke]
//   open -W -n -a "$PWD/build/TalkTalk-Dev.app" --args --bench record --set t5|t17 [--corpus <dir>] [--out <file>] [--smoke]
//
// (`open -a` needs an absolute path to a bundle.) Started any other way they refuse to run.
// --smoke opens the window, writes the result and quits after 1.5 s without opening the mic.

@MainActor func runBenchEnroll() -> Never {
    #if TALKTALK_DEV
    BenchEnrollWindow.run(outPath: argumentValue("--out"), smoke: arguments.contains("--smoke"))
    #else
    fail("--bench enroll exists only in the dev build (TalkTalk-Dev.app); the product records the voice in onboarding/settings")
    #endif
}

@MainActor func runBenchRecord() -> Never {
    #if TALKTALK_DEV
    BenchRecordWindow.run(set: argumentValue("--set"), corpus: argumentValue("--corpus"),
                          outPath: argumentValue("--out"), smoke: arguments.contains("--smoke"))
    #else
    fail("--bench record exists only in the dev build (TalkTalk-Dev.app)")
    #endif
}
