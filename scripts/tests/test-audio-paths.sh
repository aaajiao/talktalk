#!/bin/bash
# Fixture tests for scripts/check-audio-paths.sh: a clean tree passes, comments are ignored, and
# every rule catches a planted violation. Run: scripts/tests/test-audio-paths.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/../check-audio-paths.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-audio-paths.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; return 0; }

put() {   # put <root> <relative path> <line>
  /bin/mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >> "$1/$2"
}

# The legitimate uses, each in the one file allowed to have it.
clean_tree() {
  local r="$1"
  /bin/rm -rf "$r"; /bin/mkdir -p "$r/Sources"
  put "$r" Sources/TalkTalkAudio/MicCapture.swift 'guard let ctx = tt_mic_ctx_create(ring, channel) else { throw x }'
  put "$r" Sources/CAudioCore/tt_ioproc_mic.c 'tt_mic_ctx *tt_mic_ctx_create(tt_ring *ring, uint32_t channel) {'
  put "$r" Sources/TalkTalkAudio/MicIngest.swift 'let capture = try MicCapture(device: device)'
  put "$r" Sources/TalkTalkAudio/MicIngest.swift 'let block = MicBlock(origin: .mic, hostTime: t, sampleRate: sr, samples: s)'
  put "$r" Sources/TalkTalkVoice/EnrollmentController.swift 'let capture = try MicCapture(device: device)'
  put "$r" Sources/TalkTalkApp/BenchRecord.swift 'let c = try MicCapture(device: info)'
  put "$r" Sources/TalkTalkCore/PassthroughGate.swift 'return PassthroughFrames(block: block, range: lo..<hi, generation: g)'
  put "$r" Sources/TalkTalkCore/PassthroughGate.swift 'public var feedChannel: Int {'
  put "$r" Sources/TalkTalkCore/PassthroughGate.swift 'public func openSelfTest(at t: HostTime, durationMs: Int) -> Bool {'
  put "$r" Sources/TalkTalkAudio/PassthroughStage.swift 'tt_ringp_write(ring, buf, n, gen, hostTime)'
  put "$r" Sources/TalkTalkAudio/PassthroughStage.swift 'func push(_ f: PassthroughFrames) {'
  put "$r" Sources/TalkTalkAudio/FeedOutput.swift 'let ringP = tt_ringp_create(capacity)'
  put "$r" Sources/TalkTalkAudio/FeedOutput.swift 'func play(_ frames: PassthroughFrames) {'
  put "$r" Sources/CAudioCore/tt_ioproc_feed.c 'uint32_t got = tt_ringp_read(ctx->ringp, dst, frames, gen);'
  put "$r" Sources/CAudioCore/tt_ringp.c 'uint32_t tt_ringp_read(tt_ringp *r, float *dst, uint32_t n, uint32_t gen) {'
  put "$r" Sources/CAudioCore/include/tt_ringp.h 'uint32_t tt_ringp_write(tt_ringp *r, const float *src, uint32_t n, uint32_t gen, uint64_t t);'
  put "$r" Sources/TalkTalkEngineHost/RemoteQwenTTS.swift 'yield TTSChunk(samples: s, isLast: last)'
  put "$r" Sources/TalkTalkEngineHost/RemoteQwen+Core.swift 'cont.yield(TTSChunk(job: j, seq: s, samples24k: p, isLast: false))'
  put "$r" Sources/TalkTalkApple/SystemVoiceTTS.swift 'out.append(TTSChunk(samples: s, isLast: false))'
  put "$r" Sources/TalkTalkSession/PassthroughSelfTest.swift 'gate.setSource(.selfTest, at: now)'
  put "$r" Sources/TalkTalkSession/PassthroughSelfTest.swift 'let b = MicBlock(origin: .selfTest, hostTime: t, sampleRate: 48_000, samples: pulse)'
  put "$r" Sources/TalkTalkSession/PassthroughSelfTest.swift '_ = gate.openSelfTest(at: now, durationMs: 300)'
  put "$r" Sources/TalkTalkVoice/AuditionController.swift 'try monitor.play(samples, gainDb: routing.playoutGainDb)'
  put "$r" Sources/TalkTalkVoice/AuditionController.swift 'monitor.stop() // not FeedOutput'
  put "$r" Sources/TalkTalkVoice/AuditionController.swift '/// never FeedOutput, ClauseQueue or PlayoutStage: the monitor only'
  put "$r" Sources/TalkTalkApp/SelfTestVoice.swift 'let monitor = AuditionMonitor(output: monitorOutput)'
  # names in comments do not count
  put "$r" Sources/TalkTalkAudio/MonitorOutput.swift '/// MonitorOutput never takes PassthroughFrames( or TTSChunk( from the mic.'
  put "$r" Sources/TalkTalkAudio/ClauseQueue.swift '// tt_ringp_read is feedIOProc only'
  put "$r" Sources/TalkTalkAudio/ClauseQueue.swift '/**'
  put "$r" Sources/TalkTalkAudio/ClauseQueue.swift ' * PassthroughFrames are not here'
  put "$r" Sources/TalkTalkAudio/ClauseQueue.swift ' */'
  put "$r" Sources/TalkTalkAudio/PlayoutStage.swift 'let x = 1 // not PassthroughFrames('
  # block comments, across lines and inline, as C headers write them
  put "$r" Sources/CAudioCore/include/tt_ioproc_feed.h '/* The feed IOProc reads two rings:'
  put "$r" Sources/CAudioCore/include/tt_ioproc_feed.h ' *  - ringP (passthrough, through tt_ringp_read) on the channel of its source'
  put "$r" Sources/CAudioCore/include/tt_ioproc_feed.h ' */'
  put "$r" Sources/CAudioCore/tt_ioproc_monitor.c 'static int x; /* not tt_ringp_read */ static int y;'
  put "$r" Sources/CAudioCore/tt_ioproc_monitor.c '#include "tt_ring.h"'
  put "$r" Sources/TalkTalkAudio/ClauseQueue.swift 'let u = "https://example.invalid/a" // tt_ringp_write'
}

expect_pass() {
  local out
  if out="$("$check" "$1" 2>&1)"; then ok "$2"; else no "$2" "$out"; fi
}

expect_fail() {   # expect_fail <root> <rule id> <name>
  local out
  if out="$("$check" "$1" 2>&1)"; then
    no "$3 (passed)" "$out"
  elif printf '%s\n' "$out" | /usr/bin/grep -q "^$2:"; then
    ok "$3"
  else
    no "$3 (failed without $2)" "$out"
  fi
}

r="$work/root"
clean_tree "$r"; expect_pass "$r" "clean tree passes, comments ignored"

plant() {   # plant <rule> <relative path> <line> <name>
  clean_tree "$r"; put "$r" "$2" "$3"; expect_fail "$r" "$1" "$4"
}

plant AP1 Sources/TalkTalkAudio/FeedOutput.swift 'let c = tt_mic_ctx_create(ring, 1)' "AP1 mic ring outside MicCapture"
plant AP2 Sources/TalkTalkSession/SpeakPipeline.swift 'let m = try MicCapture(device: d)' "AP2 MicCapture outside MicIngest"
plant AP2 Sources/TalkTalkAudio/MonitorOutput.swift 'private let mic = MicCapture (device: d)' "AP2 with a space before ("
plant AP3 Sources/TalkTalkAudio/FeedOutput.swift 'let f = PassthroughFrames(block: b, range: r, generation: 1)' "AP3 PassthroughFrames made outside the gate"
plant AP3 Sources/TalkTalkSession/Hook.swift 'return PassthroughFrames(samples: s)' "AP3 in TalkTalkSession"
plant AP4 Sources/TalkTalkAudio/PlayoutStage.swift 'tt_ringp_write(r, p, n, g, t)' "AP4 ringP written outside PassthroughStage"
plant AP5 Sources/CAudioCore/tt_ioproc_monitor.c 'n = tt_ringp_read(r, dst, frames, gen);' "AP5 ringP read outside feedIOProc"
plant AP6 Sources/TalkTalkAudio/PlayoutStage.swift 'let c = TTSChunk(samples: mic, isLast: true)' "AP6 TTSChunk outside the TTS engines"
plant AP7 Sources/TalkTalkAudio/MonitorOutput.swift 'func play(_ f: PassthroughFrames) {}' "AP7 MonitorOutput takes PassthroughFrames"
plant AP7 Sources/TalkTalkAudio/ClauseQueue.swift 'var pending: [PassthroughFrames] = []' "AP7 ClauseQueue holds PassthroughFrames"
plant AP7 Sources/CAudioCore/tt_ioproc_monitor.c 'static void take(PassthroughFrames *f);' "AP7 monitor IOProc"
plant AP8 Sources/TalkTalkAudio/FeedOutput.swift 'var feedChannel: Int { 2 }' "AP8 second source->channel mapping"
plant AP8 Sources/TalkTalkSession/SpeakPipeline.swift 'let s = PassthroughSource(rawValue: 1)!' "AP8 source from a raw number"
plant AP9 Sources/TalkTalkAudio/MicIngest.swift 'let b = MicBlock(origin: .selfTest, hostTime: t, sampleRate: sr, samples: s)' "AP9 mic samples labeled self-test"
plant AP9 Sources/TalkTalkSession/SpeakPipeline.swift 'gate.setSource( .selfTest, at: t)' "AP9 self-test source outside self-test code"
plant AP9 Sources/TalkTalkApp/AppDelegate.swift '_ = gate.openSelfTest(at: now, durationMs: 30_000)' "AP9 openSelfTest outside self-test code"
plant AP11 Sources/TalkTalkVoice/AuditionController.swift 'let feed = FeedOutput(device: d)' "AP11 audition reaches the Feed"
plant AP11 Sources/TalkTalkVoice/AuditionController.swift 'stage.push(clip, to: PlayoutStage.shared)' "AP11 audition through PlayoutStage"
plant AP11 Sources/TalkTalkApp/SelfTestVoice.swift 'tt_ring_write(ringO, buf, n)' "AP11 voice self-test writes ringO"
plant AP5 Sources/CAudioCore/tt_ioproc_monitor.c '*got = tt_ringp_read(r, dst, frames, gen);' "AP5 out-parameter assignment starting with *"
plant AP4 Sources/CAudioCore/tt_ioproc_monitor.c '#define RPW tt_ringp_write' "AP4 #define alias"
plant AP4 Sources/CAudioCore/tt_ioproc_monitor.c '/* x */ tt_ringp_write(r, p, n, g, t); /* y */' "AP4 code between inline block comments"
plant AP5 Sources/CAudioCore/tt_ring.cc 'n = tt_ringp_read(r, dst, frames, gen);' "AP5 in a .cc file"
plant AP4 Sources/CAudioCore/tt_copy.S 'bl _tt_ringp_write' "AP4 in an assembly file"
plant AP7 Sources/TalkTalkAudio/MonitorOutput.swift ' * PassthroughFrames(frames) // a lone * line outside a block is code' "AP7 lone * line is code"
plant AP10 Sources/TalkTalkAudio/ClauseQueue.swift 'tt_ringp_reset(ringP)' "AP10 ringP API outside its owners"

# Comment markers inside literals are not comments: the code after them is still scanned.
plant_lines() {   # plant_lines <rule> <relative path> <name> <line>...
  local rule="$1" rel="$2" name="$3"; shift 3
  clean_tree "$r"
  local l; for l in "$@"; do put "$r" "$rel" "$l"; done
  expect_fail "$r" "$rule" "$name"
}
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after a string holding /*" \
  'let glob = "voices/*.wav"' 'tt_ringp_write(r, p, n, g, t)'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after an escaped quote and // in a string" \
  'let s = "a \" // b"; tt_ringp_write(r, p, n, g, t)'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after a multi-line string holding /* and //" \
  'let doc = """' '  see /* and // here' '  """' 'tt_ringp_write(r, p, n, g, t)'
plant_lines AP5 Sources/CAudioCore/tt_ioproc_monitor.c "AP5 after C char literals / and *" \
  "if (c == '/' && d == '*') n = tt_ringp_read(r, dst, frames, gen);"
plant_lines AP5 Sources/CAudioCore/tt_ioproc_monitor.c "AP5 after a block comment closes on a later line" \
  '/* a block' '   that ends here */ n = tt_ringp_read(r, dst, frames, gen);'
# raw strings, interpolation, regex literals (Swift) and raw strings (C++)
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after a Swift raw string holding //" \
  'feed(#"{"url":"https://x"}"#); tt_ringp_write(r, p, n, g, t)'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after a raw string ending in a literal backslash" \
  'let p = #"a\"#; let b = "/*"' 'tt_ringp_write(r, p, n, g, t)'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after an interpolation with a nested /* string" \
  'let s = "a \(f("/*", "\"")) b"' 'tt_ringp_write(r, p, n, g, t)'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after a raw multi-line string holding /*" \
  'let doc = #"""' '  a "quote" and /* and """ inside' '  """#' 'tt_ringp_write(r, p, n, g, t)'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after an extended regex holding /*" \
  'let re = #/a\/*b/#; tt_ringp_write(r, p, n, g, t)'
plant_lines AP5 Sources/CAudioCore/tt_probe.cpp "AP5 after a C++ raw string holding a quote and /*" \
  'auto s = R"(" /*)"; n = tt_ringp_read(r, dst, frames, gen);'
plant_lines AP4 Sources/CAudioCore/tt_probe.cpp "AP4 #define after a raw string" \
  'auto s = u8R"(//)";' '#define W tt_ringp_write'
# each language's own rules: Swift literals are not read in C files and the other way round
plant_lines AP5 Sources/CAudioCore/tt_ioproc_monitor.c "AP5 after a C string holding \\( (not an interpolation)" \
  'const char *a = "\(", *b = "/*"; n = tt_ringp_read(r, dst, frames, gen);'
plant_lines AP5 Sources/CAudioCore/tt_ioproc_monitor.c "AP5 after a C string continued by a backslash" \
  "const char *s = \"a \\" '/* b"; n = tt_ringp_read(r, dst, frames, gen);'
plant_lines AP5 Sources/CAudioCore/tt_ioproc_monitor.c "AP5 after /* /* */ in C (no nesting)" \
  '/* a /* b */ n = tt_ringp_read(r, dst, frames, gen);'
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 after a bare regex with an escaped quote" \
  'let re = /\"/; let g = "/*"' 'tt_ringp_write(r, p, n, g, t)'
# and what each language reads as a comment stays one
clean_lines() {   # clean_lines <relative path> <name> <line>...
  local rel="$1" name="$2"; shift 2
  clean_tree "$r"
  local l; for l in "$@"; do put "$r" "$rel" "$l"; done
  expect_pass "$r" "$name"
}
clean_lines Sources/TalkTalkAudio/PlayoutStage.swift "Swift nested block comment" \
  '/* a /* b */ tt_ringp_write(r, p, n, g, t) */'
clean_lines Sources/TalkTalkAudio/PlayoutStage.swift 'Swift #"""# is a one-line raw string' \
  'let q = #"""#' '// tt_ringp_write in a comment'
clean_lines Sources/CAudioCore/tt_ioproc_monitor.c 'C """" is two empty strings' \
  'static const char *e = """";' '/* tt_ringp_read */'
# and a multi-line string that mentions a name without code after it is still scanned as text
plant_lines AP4 Sources/TalkTalkAudio/PlayoutStage.swift "AP4 name inside a multi-line string counts" \
  'let doc = """' '  tt_ringp_write' '  """'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
