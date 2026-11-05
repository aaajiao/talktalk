// TalkTalkAudio.driver - shared constants (ARCHITECTURE.md §8.2, §8.3).
//
// Values that the build script can override are guarded by #ifndef; everything that the
// app side (DriverInstaller, bench tools) must agree on comes from Generated/DriverPins.hpp
// (generated from scripts/lib/versions.sh by scripts/gen-pins.sh).

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

#include <cstdint>

#include "Generated/DriverPins.hpp"

#ifndef TT_DRIVER_VERSION_STR
#define TT_DRIVER_VERSION_STR "0.0.0-dev"
#endif

// Mic visibility strategy (§8.3): how TalkTalk Mic leaves the device list when nobody uses it.
//   0 = remove   Plugin::RemoveDevice / AddDevice (default, M0-T8 tests this first)
//   1 = hidden   kAudioDevicePropertyIsHidden toggled (fallback)
//   2 = always   always in the list, outputs silence when there is no writer (last resort)
#ifndef TT_MIC_MODE
#define TT_MIC_MODE 0
#endif

// 1 = libASPL tracer logs every HAL operation to syslog (debug builds only; very chatty).
#ifndef TT_DRIVER_TRACE
#define TT_DRIVER_TRACE 0
#endif

namespace tt {

constexpr const char* kDriverVersion = TT_DRIVER_VERSION_STR;
constexpr int kMicMode = TT_MIC_MODE;

constexpr const char* kManufacturer = "aaajiao";

constexpr const char* kFeedUID = pins::kFeedUID;
constexpr const char* kMicUID = pins::kMicUID;
constexpr const char* kTestMicUID = pins::kTestMicUID;
constexpr const char* kModelUID = pins::kModelUID;

constexpr const char* kFeedName = "TalkTalk Feed";
constexpr const char* kMicName = "TalkTalk Mic";
constexpr const char* kTestMicName = "TalkTalk Test Mic";

// One clock domain for all three devices (§8.2). Any non-zero value works; it only has to be
// the same on every device so the HAL knows they never drift against each other.
constexpr UInt32 kClockDomain = 0x74746c6b; // 'ttlk'

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kFeedChannels = 2; // 1 = meeting (TalkTalk Mic), 2 = self-test (Test Mic)
constexpr UInt32 kMicChannels = 1;

// Zero-timestamp period. AudioServerPlugIn.h (27.2 SDK): "The minimum allowed value for this
// is 10923 sample frames." ARCHITECTURE.md §8.2 originally said 480, which is illegal; 480 is
// the Mic's fixed read lag below, not the ZTS period. 12000 = 250 ms = 25 x 480.
constexpr UInt32 kZeroTimeStampPeriod = 12000;

// Mic reads the slot for sample time (T - kMicLagFrames): fixed 10 ms lag (§8.3).
constexpr UInt32 kMicLagFrames = 480;

// Loopback ring: 1 s per channel, one tagged slot per frame (§8.3).
constexpr UInt32 kRingFrames = kSampleRate;

// Mic leaves the device list after nobody has used it for this long (§8.3).
constexpr int64_t kMicGraceNanos = 5LL * 1000 * 1000 * 1000;

// Custom diagnostics property on the Feed (CFPropertyList dictionary, read-only).
// Bench tools read it via AudioObjectGetPropertyData; the app's self-test may too.
static_assert(pins::kDiagnosticsSelector == 'ttdg');
constexpr AudioObjectPropertySelector kDiagnosticsSelector = pins::kDiagnosticsSelector;

// Meeting-mode switch on the Feed (M2 CanBeDefaultDevice experiment, §8.3 / §8.6 layer 3).
// A CFNumber 0 or 1 (custom properties can only be CFString or CFPropertyList: the HAL marshals
// no other type between processes, AudioServerPlugIn.h "Custom Property Data Types").
// Anyone may read it; only a process that is an accepted Feed client may write it. 1 makes
// TalkTalk Mic report CanBeDefaultDevice = 1; 0, and every (re)entry of the Mic into the
// device list, make it report 0, so macOS cannot pick the Mic by itself when it reappears.
static_assert(pins::kMeetingModeSelector == 'ttmm');
constexpr AudioObjectPropertySelector kMeetingModeSelector = pins::kMeetingModeSelector;

} // namespace tt
