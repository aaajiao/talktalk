// plugin_harness - load TalkTalkAudio.driver in-process with a fake HAL host and exercise it
// without root and without coreaudiod (M0-T8 pre-install smoke test).
//
// What it checks (each line prints PASS/FAIL):
//   - factory, Initialize, object tree; Feed/Test Mic present, Mic absent until talktalk
//     attaches (remove mode);
//   - Feed: hidden, output-only, 2 ch, 48 kHz Float32, cannot be default;
//     Mic: input-only, 1 ch, can be default (not system default); Test Mic hidden;
//     zero-timestamp period >= 10923 (SDK minimum);
//   - gate: AddDeviceClient/StartIO refused for NULL and foreign bundle ids, accepted for
//     com.aaajiao.talktalk(.dev);
//   - loopback: ch1 -> Mic, ch2 -> Test Mic, fixed 480-frame lag, bit-exact;
//   - isolation: ch2 never reaches Mic and vice versa;
//   - anti-replay: after the Feed client stops, the Mic reads exact zeros, also for sample
//     times whose ring slots still hold old audio; 20 stop/start cycles;
//   - visibility: Mic appears <= 1 s after the Feed client attaches; leaves 5 s after the last
//     user (Feed client gone, no Mic IO); stays while a reader does IO; re-adds with same UID.
//
// Build: tools/bench/driver/build.sh   Run: build/bench-driver/plugin_harness <driver bundle>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <dlfcn.h>
#include <unistd.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../../../Driver/Sources/Generated/DriverPins.hpp"

namespace {

int gFailures = 0;

void Check(bool ok, const char* what, const std::string& detail = {})
{
    std::printf("%s  %s%s%s\n", ok ? "PASS" : "FAIL", what, detail.empty() ? "" : "  ", detail.c_str());
    if (!ok) {
        gFailures++;
    }
}

AudioServerPlugInDriverRef gDriver = nullptr;
AudioServerPlugInDriverInterface* D()
{
    return *gDriver;
}

//--------------------------------------------------------------------------------------------
// Fake host

struct PendingChange
{
    AudioObjectID device;
    UInt64 action;
    void* info;
};

std::mutex gHostMutex;
std::deque<PendingChange> gPending;
std::vector<std::pair<AudioObjectID, AudioObjectPropertySelector>> gNotifications;

OSStatus HostPropertiesChanged(AudioServerPlugInHostRef,
    AudioObjectID objectID,
    UInt32 count,
    const AudioObjectPropertyAddress* addrs)
{
    std::lock_guard lock(gHostMutex);
    for (UInt32 i = 0; i < count; i++) {
        gNotifications.emplace_back(objectID, addrs[i].mSelector);
    }
    return 0;
}

OSStatus HostCopyFromStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef* out)
{
    *out = nullptr;
    return kAudioHardwareUnknownPropertyError;
}

OSStatus HostWriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef)
{
    return 0;
}

OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef)
{
    return 0;
}

OSStatus HostRequestConfigChange(AudioServerPlugInHostRef, AudioObjectID device, UInt64 action, void* info)
{
    std::lock_guard lock(gHostMutex);
    gPending.push_back({device, action, info});
    return 0;
}

AudioServerPlugInHostInterface gHost = {
    HostPropertiesChanged,
    HostCopyFromStorage,
    HostWriteToStorage,
    HostDeleteFromStorage,
    HostRequestConfigChange,
};

// The real HAL performs requested configuration changes asynchronously; do the same.
void Pump()
{
    for (;;) {
        PendingChange c;
        {
            std::lock_guard lock(gHostMutex);
            if (gPending.empty()) {
                return;
            }
            c = gPending.front();
            gPending.pop_front();
        }
        D()->PerformDeviceConfigurationChange(gDriver, c.device, c.action, c.info);
    }
}

void PumpFor(int ms)
{
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < end) {
        Pump();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    Pump();
}

//--------------------------------------------------------------------------------------------
// Property helpers

template <typename T>
OSStatus Get(AudioObjectID obj, AudioObjectPropertySelector sel, T& out,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(T);
    return D()->GetPropertyData(gDriver, obj, 0, &a, 0, nullptr, size, &size, &out);
}

std::vector<AudioObjectID> GetIDs(AudioObjectID obj, AudioObjectPropertySelector sel,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (D()->GetPropertyDataSize(gDriver, obj, 0, &a, 0, nullptr, &size) != 0) {
        return {};
    }
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (ids.empty()) {
        return ids;
    }
    D()->GetPropertyData(gDriver, obj, 0, &a, 0, nullptr, size, &size, ids.data());
    ids.resize(size / sizeof(AudioObjectID));
    return ids;
}

AudioObjectID TranslateUID(const char* uid)
{
    CFStringRef s = CFStringCreateWithCString(nullptr, uid, kCFStringEncodingUTF8);
    AudioObjectPropertyAddress a = {
        kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    D()->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &a, sizeof(s), &s, size, &size, &id);
    CFRelease(s);
    return id;
}

bool InDeviceList(AudioObjectID dev)
{
    for (auto id : GetIDs(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList)) {
        if (id == dev) {
            return true;
        }
    }
    return false;
}

UInt32 U32(AudioObjectID obj, AudioObjectPropertySelector sel,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    UInt32 v = 0xFFFFFFFF;
    Get(obj, sel, v, scope);
    return v;
}

AudioStreamBasicDescription StreamFormat(AudioObjectID stream)
{
    AudioStreamBasicDescription f = {};
    Get(stream, kAudioStreamPropertyVirtualFormat, f);
    return f;
}

// 'ttmm' (M2 meeting-mode switch): CFNumber 0/1 on the Feed.
OSStatus SetTTMM(AudioObjectID feed, pid_t pid, CFPropertyListRef v, UInt32 size = sizeof(CFPropertyListRef))
{
    AudioObjectPropertyAddress a = {tt::pins::kMeetingModeSelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return D()->SetPropertyData(gDriver, feed, pid, &a, 0, nullptr, size, &v);
}

OSStatus SetTTMM(AudioObjectID feed, pid_t pid, int value)
{
    CFNumberRef n = CFNumberCreate(nullptr, kCFNumberIntType, &value);
    OSStatus s = SetTTMM(feed, pid, n);
    CFRelease(n);
    return s;
}

int GetTTMM(AudioObjectID feed)
{
    AudioObjectPropertyAddress a = {tt::pins::kMeetingModeSelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFPropertyListRef v = nullptr;
    UInt32 size = sizeof(v);
    if (D()->GetPropertyData(gDriver, feed, 0, &a, 0, nullptr, size, &size, &v) != 0 || !v) {
        return -2;
    }
    int out = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberIntType, &out);
    }
    CFRelease(v);
    return out;
}

int Notifications(AudioObjectID obj, AudioObjectPropertySelector sel)
{
    std::lock_guard lock(gHostMutex);
    int n = 0;
    for (auto& [o, s] : gNotifications) {
        if (o == obj && s == sel) {
            n++;
        }
    }
    return n;
}

int64_t DiagNum(CFDictionaryRef d, const char* key);

CFDictionaryRef Diagnostics(AudioObjectID feed)
{
    AudioObjectPropertyAddress a = {tt::pins::kDiagnosticsSelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFPropertyListRef v = nullptr;
    UInt32 size = sizeof(v);
    if (D()->GetPropertyData(gDriver, feed, 0, &a, 0, nullptr, size, &size, &v) != 0) {
        return nullptr;
    }
    return static_cast<CFDictionaryRef>(v);
}

int64_t DiagNum(CFDictionaryRef d, const char* key)
{
    CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
    auto n = static_cast<CFNumberRef>(CFDictionaryGetValue(d, k));
    CFRelease(k);
    int64_t v = -1;
    if (n) {
        CFNumberGetValue(n, kCFNumberSInt64Type, &v);
    }
    return v;
}

//--------------------------------------------------------------------------------------------
// Clients and IO

struct FakeClient
{
    UInt32 id;
    const char* bundle; // nullptr = bare binary
};

OSStatus AddClient(AudioObjectID dev, FakeClient c)
{
    AudioServerPlugInClientInfo info = {};
    info.mClientID = c.id;
    info.mProcessID = getpid();
    info.mIsNativeEndian = true;
    info.mBundleID = c.bundle ? CFStringCreateWithCString(nullptr, c.bundle, kCFStringEncodingUTF8) : nullptr;
    OSStatus s = D()->AddDeviceClient(gDriver, dev, &info);
    if (info.mBundleID) {
        CFRelease(info.mBundleID);
    }
    return s;
}

OSStatus RemoveClient(AudioObjectID dev, FakeClient c)
{
    AudioServerPlugInClientInfo info = {};
    info.mClientID = c.id;
    info.mProcessID = getpid();
    info.mIsNativeEndian = true;
    info.mBundleID = c.bundle ? CFStringCreateWithCString(nullptr, c.bundle, kCFStringEncodingUTF8) : nullptr;
    OSStatus s = D()->RemoveDeviceClient(gDriver, dev, &info);
    if (info.mBundleID) {
        CFRelease(info.mBundleID);
    }
    return s;
}

OSStatus FeedWrite(AudioObjectID feed, AudioObjectID stream, UInt32 client, Float64 outTime,
    std::vector<float>& interleaved, UInt32 frames)
{
    AudioServerPlugInIOCycleInfo cycle = {};
    cycle.mOutputTime.mSampleTime = outTime;
    cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
    D()->BeginIOOperation(gDriver, feed, client, kAudioServerPlugInIOOperationMixOutput, frames, &cycle);
    OSStatus s = D()->DoIOOperation(gDriver, feed, stream, client, kAudioServerPlugInIOOperationMixOutput,
        frames, &cycle, interleaved.data(), nullptr);
    D()->EndIOOperation(gDriver, feed, client, kAudioServerPlugInIOOperationMixOutput, frames, &cycle);
    return s;
}

std::vector<float> InputRead(AudioObjectID dev, AudioObjectID stream, UInt32 client, Float64 inTime, UInt32 frames)
{
    std::vector<float> buf(frames, 12345.0f);
    AudioServerPlugInIOCycleInfo cycle = {};
    cycle.mInputTime.mSampleTime = inTime;
    cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
    D()->BeginIOOperation(gDriver, dev, client, kAudioServerPlugInIOOperationReadInput, frames, &cycle);
    D()->DoIOOperation(gDriver, dev, stream, client, kAudioServerPlugInIOOperationReadInput, frames, &cycle,
        buf.data(), nullptr);
    D()->EndIOOperation(gDriver, dev, client, kAudioServerPlugInIOOperationReadInput, frames, &cycle);
    return buf;
}

bool AllZero(const std::vector<float>& v)
{
    for (float x : v) {
        if (x != 0.0f) {
            return false;
        }
    }
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <path/to/TalkTalkAudio.driver>\n", argv[0]);
        return 2;
    }
    const std::string exe = std::string(argv[1]) + "/Contents/MacOS/TalkTalkAudio";
    void* lib = dlopen(exe.c_str(), RTLD_NOW | RTLD_LOCAL);
    Check(lib != nullptr, "dlopen driver binary", lib ? "" : dlerror());
    if (!lib) {
        return 1;
    }
    using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);
    auto factory = reinterpret_cast<Factory>(dlsym(lib, "TalkTalkAudio_Create"));
    Check(factory != nullptr, "factory symbol TalkTalkAudio_Create");
    if (!factory) {
        return 1;
    }
    Check(factory(nullptr, CFUUIDGetConstantUUIDWithBytes(nullptr, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)) == nullptr,
        "factory refuses a foreign type UUID");
    gDriver = static_cast<AudioServerPlugInDriverRef>(factory(nullptr, kAudioServerPlugInTypeUUID));
    Check(gDriver != nullptr, "factory returns driver for kAudioServerPlugInTypeUUID");
    Check(D()->Initialize(gDriver, &gHost) == 0, "Initialize");
    PumpFor(50);

    const AudioObjectID feed = TranslateUID(tt::pins::kFeedUID);
    const AudioObjectID testMic = TranslateUID(tt::pins::kTestMicUID);
    AudioObjectID mic = TranslateUID(tt::pins::kMicUID);

    Check(feed != kAudioObjectUnknown, "Feed resolvable by UID");
    Check(testMic != kAudioObjectUnknown, "Test Mic resolvable by UID");
    Check(mic == kAudioObjectUnknown, "Mic not present at load (remove mode)");
    Check(InDeviceList(feed) && InDeviceList(testMic), "plug-in device list has Feed + Test Mic");

    // --- Feed properties
    Check(U32(feed, kAudioDevicePropertyIsHidden) == 1, "Feed IsHidden = 1");
    Check(U32(feed, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0,
        "Feed CanBeDefaultDevice = 0");
    Check(U32(feed, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput) == 0,
        "Feed CanBeDefaultSystemDevice = 0");
    Check(U32(feed, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual, "Feed transport = virtual");
    const UInt32 zts = U32(feed, kAudioDevicePropertyZeroTimeStampPeriod);
    Check(zts >= 10923, "zero-timestamp period >= 10923 (SDK minimum)", std::to_string(zts));
    auto feedOut = GetIDs(feed, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    auto feedIn = GetIDs(feed, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    Check(feedOut.size() == 1 && feedIn.empty(), "Feed: 1 output stream, 0 input streams");
    if (feedOut.empty()) {
        return 1;
    }
    const AudioObjectID feedStream = feedOut[0];
    auto ff = StreamFormat(feedStream);
    Check(ff.mSampleRate == 48000 && ff.mChannelsPerFrame == 2 && (ff.mFormatFlags & kAudioFormatFlagIsFloat) &&
              ff.mBitsPerChannel == 32,
        "Feed format 48 kHz / 2 ch / Float32");
    auto controls = GetIDs(feed, kAudioObjectPropertyControlList);
    Check(controls.empty(), "Feed has no volume/mute controls");

    auto tmIn = GetIDs(testMic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    Check(U32(testMic, kAudioDevicePropertyIsHidden) == 1, "Test Mic IsHidden = 1");
    Check(tmIn.size() == 1 && GetIDs(testMic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).empty(),
        "Test Mic: 1 input stream, 0 output");
    Check(U32(testMic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 0,
        "Test Mic CanBeDefaultDevice = 0");
    if (tmIn.empty()) {
        return 1;
    }
    const AudioObjectID testMicStream = tmIn[0];

    // --- gate
    const FakeClient bare {101, nullptr};
    const FakeClient probe {102, "com.aaajiao.talktalk.feedprobe"};
    const FakeClient app {103, "com.aaajiao.talktalk.dev"};
    Check(AddClient(feed, bare) == kAudioHardwareIllegalOperationError, "gate: AddDeviceClient refused for NULL bundle id");
    Check(AddClient(feed, probe) == kAudioHardwareIllegalOperationError, "gate: AddDeviceClient refused for feedprobe");
    Check(D()->StartIO(gDriver, feed, bare.id) == kAudioHardwareIllegalOperationError, "gate: StartIO refused for NULL bundle id");
    Check(D()->StartIO(gDriver, feed, probe.id) == kAudioHardwareIllegalOperationError, "gate: StartIO refused for feedprobe");
    RemoveClient(feed, bare);
    RemoveClient(feed, probe);

    PumpFor(200);
    Check(TranslateUID(tt::pins::kMicUID) == kAudioObjectUnknown, "refused Feed clients do not bring the Mic in");

    const auto tAttach = std::chrono::steady_clock::now();
    Check(AddClient(feed, app) == 0, "gate: AddDeviceClient accepted for com.aaajiao.talktalk.dev");
    // Wait for the visibility queue.
    for (int i = 0; i < 200 && TranslateUID(tt::pins::kMicUID) == kAudioObjectUnknown; i++) {
        PumpFor(5);
    }
    mic = TranslateUID(tt::pins::kMicUID);
    const double attachMs =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tAttach).count();
    Check(mic != kAudioObjectUnknown && InDeviceList(mic), "Mic appears after talktalk attaches to Feed",
        std::to_string(attachMs) + " ms");
    if (mic == kAudioObjectUnknown) {
        return 1;
    }
    Check(D()->StartIO(gDriver, feed, app.id) == 0, "gate: StartIO accepted for com.aaajiao.talktalk.dev");

    // --- Mic properties
    PumpFor(20);
    auto micIn = GetIDs(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    Check(micIn.size() == 1 && GetIDs(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).empty(),
        "Mic: 1 input stream, 0 output");
    Check(U32(mic, kAudioDevicePropertyIsHidden) == 0, "Mic IsHidden = 0 while in use");
    Check(U32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
        "Mic enters the list with stable CanBeDefaultDevice = 1");

    // --- 'ttmm' meeting-mode switch (M2): only a process with an accepted Feed client may write.
    {
        Check(GetTTMM(feed) == 0, "ttmm reads 0 at load");
        Boolean settable = false;
        AudioObjectPropertyAddress ta = {tt::pins::kMeetingModeSelector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        Check(D()->IsPropertySettable(gDriver, feed, 0, &ta, &settable) == 0 && settable, "ttmm is settable");
        Check(SetTTMM(feed, 0, 1) == kAudioHardwareIllegalOperationError, "ttmm: write with pid 0 (Host) refused");
        Check(SetTTMM(feed, getpid() + 100000, 1) == kAudioHardwareIllegalOperationError,
            "ttmm: write from a pid with no accepted Feed client refused");
        Check(SetTTMM(feed, getpid(), 2) == kAudioHardwareIllegalOperationError, "ttmm: value 2 refused");
        CFStringRef str = CFSTR("1");
        Check(SetTTMM(feed, getpid(), str) == kAudioHardwareIllegalOperationError, "ttmm: CFString value refused");
        Check(SetTTMM(feed, getpid(), nullptr, 4) == kAudioHardwareIllegalOperationError, "ttmm: wrong size refused");
        Check(GetTTMM(feed) == 0 && U32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
            "refused writes change nothing");
        const int before = Notifications(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice);
        Check(SetTTMM(feed, getpid(), 1) == 0, "ttmm: talktalk (accepted Feed client) writes 1");
        Check(GetTTMM(feed) == 1 && U32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
            "ttmm 1 records the session without changing Mic capability");
        Check(Notifications(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice) == before,
            "ttmm 1 does not notify unchanged Mic capability");
        Check(SetTTMM(feed, getpid(), 0) == 0 && GetTTMM(feed) == 0 &&
                U32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1 &&
                Notifications(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice) == before,
            "ttmm 0 records session end; Mic remains selectable without capability notification");
        Check(U32(feed, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0 &&
                U32(testMic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 0,
            "ttmm never touches Feed / Test Mic");
    }
    Check(U32(mic, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeInput) == 0,
        "Mic CanBeDefaultSystemDevice = 0");
    Check(U32(mic, kAudioDevicePropertyClockDomain) == U32(feed, kAudioDevicePropertyClockDomain) &&
              U32(mic, kAudioDevicePropertyClockDomain) != 0,
        "Mic and Feed share a non-zero clock domain");
    if (micIn.empty()) {
        return 1;
    }
    const AudioObjectID micStream = micIn[0];
    auto mf = StreamFormat(micStream);
    Check(mf.mSampleRate == 48000 && mf.mChannelsPerFrame == 1 && (mf.mFormatFlags & kAudioFormatFlagIsFloat),
        "Mic format 48 kHz / 1 ch / Float32");

    // Zero timestamps on one timeline.
    Float64 fs = 0, ms = 0;
    UInt64 fh = 0, mh = 0, seed = 0;
    D()->GetZeroTimeStamp(gDriver, feed, app.id, &fs, &fh, &seed);
    D()->GetZeroTimeStamp(gDriver, mic, app.id, &ms, &mh, &seed);
    Check(std::fabs(fs - ms) <= zts && (fh == mh || std::fabs(double(fh) - double(mh)) < 1e8),
        "Feed and Mic zero timestamps on one timeline");

    // --- loopback, lag, isolation
    const FakeClient reader {201, "us.zoom.xos"};
    Check(AddClient(mic, reader) == 0 && D()->StartIO(gDriver, mic, reader.id) == 0, "reader attaches to Mic (no gate)");
    const FakeClient tester {202, "com.aaajiao.talktalk.dev"};
    Check(AddClient(testMic, tester) == 0 && D()->StartIO(gDriver, testMic, tester.id) == 0, "self-test attaches to Test Mic");

    const UInt32 N = 480;
    Float64 T = 1000.0 * 480; // sample time well inside the ring
    std::vector<float> buf(N * 2);
    for (UInt32 i = 0; i < N; i++) {
        buf[i * 2 + 0] = 0.5f * std::sin(2 * M_PI * 1000.0 * i / 48000.0); // ch1
        buf[i * 2 + 1] = 0.0f;                                           // ch2 silent
    }
    FeedWrite(feed, feedStream, app.id, T, buf, N);
    auto micGot = InputRead(mic, micStream, reader.id, T + 480, N);
    bool exact = true;
    for (UInt32 i = 0; i < N; i++) {
        exact = exact && (micGot[i] == buf[i * 2]);
    }
    Check(exact, "loopback ch1 -> Mic bit-exact with 480-frame lag");
    auto micEarly = InputRead(mic, micStream, reader.id, T + 479, N);
    Check(micEarly[0] == 0.0f && micEarly[1] == buf[0], "lag is exactly 480 frames (off-by-one check)");
    auto tmGot = InputRead(testMic, testMicStream, tester.id, T + 480, N);
    Check(AllZero(tmGot), "isolation: ch1 audio does not reach Test Mic");

    T += N;
    for (UInt32 i = 0; i < N; i++) {
        buf[i * 2 + 0] = 0.0f;
        buf[i * 2 + 1] = 0.25f * std::sin(2 * M_PI * 440.0 * i / 48000.0);
    }
    FeedWrite(feed, feedStream, app.id, T, buf, N);
    Check(AllZero(InputRead(mic, micStream, reader.id, T + 480, N)), "isolation: ch2 (self-test) does not reach Mic");
    tmGot = InputRead(testMic, testMicStream, tester.id, T + 480, N);
    exact = true;
    for (UInt32 i = 0; i < N; i++) {
        exact = exact && (tmGot[i] == buf[i * 2 + 1]);
    }
    Check(exact, "loopback ch2 -> Test Mic bit-exact");

    // Not-yet-written / never-written times read as zero.
    Check(AllZero(InputRead(mic, micStream, reader.id, T + 480 + 10 * N, N)), "unwritten sample times read as zero");

    // --- anti-replay: stop/start 20 times; old slots must never come back.
    bool replayOK = true;
    Float64 t = T + 4 * N;
    for (int round = 0; round < 20; round++) {
        for (UInt32 i = 0; i < N; i++) {
            buf[i * 2 + 0] = 0.3f;
            buf[i * 2 + 1] = 0.0f;
        }
        FeedWrite(feed, feedStream, app.id, t, buf, N);
        if (InputRead(mic, micStream, reader.id, t + 480, N)[100] != 0.3f) {
            replayOK = false;
        }
        D()->StopIO(gDriver, feed, app.id);
        // Stopped: the reader keeps going; one second later the ring slot for (t + 48000)
        // still physically holds the 0.3 written at t, but the tag says "t", so it must be 0.
        const Float64 later = t + 48000;
        if (!AllZero(InputRead(mic, micStream, reader.id, later + 480, N))) {
            replayOK = false;
        }
        if (D()->StartIO(gDriver, feed, app.id) != 0) {
            replayOK = false;
        }
        t = later + 7 * N;
    }
    Check(replayOK, "anti-replay: 20 stop/start cycles, stopped periods read exact zeros");

    // --- mixing: two talktalk clients writing the same cycle are summed.
    const FakeClient app2 {104, "com.aaajiao.talktalk"};
    AddClient(feed, app2);
    D()->StartIO(gDriver, feed, app2.id);
    t += 3 * N;
    for (UInt32 i = 0; i < N; i++) {
        buf[i * 2 + 0] = 0.25f;
        buf[i * 2 + 1] = 0.0f;
    }
    FeedWrite(feed, feedStream, app.id, t, buf, N);
    FeedWrite(feed, feedStream, app2.id, t, buf, N);
    Check(InputRead(mic, micStream, reader.id, t + 480, N)[10] == 0.5f, "two Feed clients in one cycle are mixed (summed)");
    D()->StopIO(gDriver, feed, app2.id);
    RemoveClient(feed, app2);

    // --- visibility: reader keeps the Mic in the list after talktalk detaches.
    // Meeting mode on first: the driver must not turn it off by itself while the Mic is listed.
    Check(SetTTMM(feed, getpid(), 1) == 0, "ttmm 1 before talktalk detaches");
    D()->StopIO(gDriver, feed, app.id);
    RemoveClient(feed, app);
    Check(SetTTMM(feed, getpid(), 0) == kAudioHardwareIllegalOperationError,
        "ttmm: write refused once talktalk has no Feed client");
    PumpFor(6000);
    Check(InDeviceList(mic) && TranslateUID(tt::pins::kMicUID) == mic,
        "Mic stays while a reader does IO (talktalk gone > 5 s)");
    Check(GetTTMM(feed) == 1 && U32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
        "talktalk gone, Mic still listed: CanBeDefaultDevice stays 1 (no reset mid-call)");
    Check(AllZero(InputRead(mic, micStream, reader.id, t + 48000 * 3, N)), "Mic outputs exact zeros with no Feed writer");

    // Reader stops -> 5 s grace -> removed.
    D()->StopIO(gDriver, mic, reader.id);
    const auto tStop = std::chrono::steady_clock::now();
    PumpFor(4000);
    Check(InDeviceList(mic), "Mic still listed 4 s after the last user (grace)");
    double goneMs = -1;
    for (int i = 0; i < 400; i++) {
        PumpFor(10);
        if (!InDeviceList(mic)) {
            goneMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tStop).count();
            break;
        }
    }
    Check(goneMs >= 5000 && goneMs < 6000, "Mic removed ~5 s after the last user", std::to_string(goneMs) + " ms");
    Check(TranslateUID(tt::pins::kMicUID) == kAudioObjectUnknown, "removed Mic is not resolvable by UID");
    RemoveClient(mic, reader);

    // Short disconnect (< 5 s) does not make the Mic blink.
    AddClient(feed, app);
    PumpFor(200);
    Check(InDeviceList(mic), "Mic re-added when talktalk re-attaches (same object)");
    Check(GetTTMM(feed) == 0 && U32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
        "re-added Mic: ttmm resets to 0 while input capability stays 1");
    RemoveClient(feed, app);
    PumpFor(2000);
    AddClient(feed, app);
    PumpFor(4000);
    Check(InDeviceList(mic), "a 2 s gap does not remove the Mic");
    RemoveClient(feed, app);

    // Diagnostics property.
    if (CFDictionaryRef d = Diagnostics(feed)) {
        Check(DiagNum(d, "feedAddClientDenied") == 2 && DiagNum(d, "feedStartIODenied") == 2,
            "diagnostics counts the 2 refused AddClient + 2 refused StartIO");
        Check(DiagNum(d, "micHides") >= 1 && DiagNum(d, "micShows") >= 2, "diagnostics counts Mic shows/hides");
        Check(DiagNum(d, "ttmmWrites") == 3 && DiagNum(d, "ttmmDenied") == 3,
            "diagnostics counts accepted ttmm writes (3) and refusals by caller (3)",
            std::to_string(DiagNum(d, "ttmmWrites")) + " / " + std::to_string(DiagNum(d, "ttmmDenied")));
        Check(DiagNum(d, "meetingMode") == 0 && DiagNum(d, "micCanBeDefault") == 1,
            "diagnostics separates idle meetingMode from stable Mic capability");
        CFRelease(d);
    } else {
        Check(false, "diagnostics property 'ttdg' readable");
    }

    {
        std::lock_guard lock(gHostMutex);
        int deviceListNotes = 0;
        for (auto& [obj, sel] : gNotifications) {
            if (obj == kAudioObjectPlugInObject && sel == kAudioPlugInPropertyDeviceList) {
                deviceListNotes++;
            }
        }
        Check(deviceListNotes >= 3, "plug-in notifies kAudioPlugInPropertyDeviceList on add/remove",
            std::to_string(deviceListNotes) + " notifications");
    }

    std::printf("\n%s: %d failure(s)\n", gFailures ? "FAILED" : "OK", gFailures);
    return gFailures ? 1 : 0;
}
