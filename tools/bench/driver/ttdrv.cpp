// ttdrv - M0-T8 test client for TalkTalkAudio.driver, running against the real coreaudiod.
//
// Built three ways by tools/bench/driver/build.sh (same source):
//   build/bench-driver/TTDriverBench.app   bundle id com.aaajiao.talktalk.dev  (passes the Feed gate)
//   build/bench-driver/FeedProbe.app       bundle id com.aaajiao.talktalk.feedprobe (must be refused)
//   build/bench-driver/ttdrv               bare binary, no bundle id (must be refused)
//
// Commands that read TalkTalk Mic / Test Mic need microphone permission for the reading
// process. Launch those through LaunchServices so TCC asks for TTDriverBench itself:
//   open -W -n --stdout OUT --stderr ERR -a build/bench-driver/TTDriverBench.app --args loopback
// Commands that only write the Feed or read properties can run the binary inside the .app
// directly (its main bundle still reports com.aaajiao.talktalk.dev to the HAL).
//
// Commands (all print JSON lines; "tt.result" lines carry the measurements):
//   list                       devices, TalkTalk device properties, defaults, driver diagnostics
//   diag                       the Feed's 'ttdg' diagnostics dictionary
//   defaults                   default input / output / system output
//   set-default-input UID      set + read back (prints before/after)
//   hold [--channel N] [--signal silence|sine] [--seconds S]
//                              attach an IOProc to the Feed by UID and keep writing; survives
//                              coreaudiod restarts; SIGTERM = clean exit
//   read --uid UID [--seconds S]  IO on an input device (a "meeting app reader")
//   probe                      try to start IO on the Feed; report whether it was refused
//   loopback [--channel 1|2]   sweep on Feed channel N; record Mic + Test Mic; lag, peak, level,
//                              silence, isolation, callback-to-callback latency
//   replay [--cycles 20]       Feed client stops/restarts mid-tone; Mic must never replay
//   soak --minutes M           continuous sine Feed ch1 -> Mic, sample-exact glitch check
//   visibility                 Mic enters/leaves the device list with talktalk (SIGTERM, kill -9)
//   d1 | d2 [--runs 5] | d3 | d4 | d5 [--seconds 30] | d6
//                              default-input sub-tests (ARCHITECTURE.md §14 M0-T8); every one
//                              records default input/output before and restores them after
//   ttmm [get | set 0|1]       M2: read / write the Feed's meeting-mode switch as this process
//                              (only an accepted Feed client may write: TTDriverBench yes,
//                              FeedProbe.app and the bare binary no); prints the Mic's
//                              CanBeDefaultDevice and the clientPID the driver saw
//   m2a                        M2 CanBeDefaultDevice experiment (as TTDriverBench, via open: the
//                              reader part reads the Mic): default input with ttmm 0 / 1, the
//                              HAL notification, ttmm 0 while the Mic is default (no reader /
//                              with a reader)
//   d2 --ttmm / d4 --ttmm      d2+d3 and d4 with "hold --ttmm 1" (talktalk turns meeting mode on)
//   hold ... [--ttmm 1]        the hold child writes ttmm 1 once it is attached
//   guard-child --lock-fd FD --restore-uid UID   (internal, d6)
//
// Global options: --out FILE (append JSON lines), --hold-exe PATH (run "hold" children from
// that binary; visibility / d2 run as FeedProbe.app with --hold-exe TTDriverBench's binary,
// because every CoreAudio process is a HAL client of every device and an allowed tester would
// keep the Mic listed by itself).

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "../../../Driver/Sources/Generated/DriverPins.hpp"

extern char** environ;

namespace {

constexpr const char* kFeedUID = tt::pins::kFeedUID;
constexpr const char* kMicUID = tt::pins::kMicUID;
constexpr const char* kTestMicUID = tt::pins::kTestMicUID;
constexpr double kRate = 48000.0;
constexpr int64_t kLag = 480;

//--------------------------------------------------------------------------------------------
// time, output

int64_t NowNs()
{
    return int64_t(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
}

double NowMs()
{
    return double(NowNs()) / 1e6;
}

double HostToMs(UInt64 host)
{
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t t;
        mach_timebase_info(&t);
        return t;
    }();
    return double(host) * double(tb.numer) / double(tb.denom) / 1e6;
}

void SleepMs(double ms)
{
    std::this_thread::sleep_for(std::chrono::microseconds(int64_t(ms * 1000)));
}

std::string Esc(const std::string& s)
{
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') {
            o += '\\';
            o += c;
        } else if (c == '\n') {
            o += "\\n";
        } else if (static_cast<unsigned char>(c) < 0x20) {
            char b[8];
            std::snprintf(b, sizeof(b), "\\u%04x", c);
            o += b;
        } else {
            o += c;
        }
    }
    return o;
}

// Emit one JSON object line: Emit("tt.result", {{"k","v"}...}) with pre-rendered values.
void EmitRaw(const std::string& kind, const std::vector<std::pair<std::string, std::string>>& kv)
{
    std::string line = "{\"t_ms\":" + std::to_string(int64_t(NowMs())) + ",\"kind\":\"" + kind + "\"";
    for (auto& [k, v] : kv) {
        line += ",\"" + k + "\":" + v;
    }
    line += "}\n";
    std::fputs(line.c_str(), stdout);
    std::fflush(stdout);
}

std::string S(const std::string& v)
{
    return "\"" + Esc(v) + "\"";
}

std::string N(double v)
{
    if (!std::isfinite(v)) {
        return "null";
    }
    char b[64];
    if (v == std::floor(v) && std::fabs(v) < 1e15) {
        std::snprintf(b, sizeof(b), "%.0f", v);
    } else {
        std::snprintf(b, sizeof(b), "%.6g", v);
    }
    return b;
}

std::string B(bool v)
{
    return v ? "true" : "false";
}

void Note(const char* fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    EmitRaw("tt.note", {{"msg", S(buf)}});
}

//--------------------------------------------------------------------------------------------
// HAL helpers

std::string CFStr(CFStringRef s)
{
    if (!s) {
        return {};
    }
    char buf[1024];
    if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        return buf;
    }
    return {};
}

AudioObjectPropertyAddress Addr(AudioObjectPropertySelector sel,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    return {sel, scope, kAudioObjectPropertyElementMain};
}

UInt32 GetU32(AudioObjectID obj, AudioObjectPropertySelector sel,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, OSStatus* err = nullptr)
{
    auto a = Addr(sel, scope);
    UInt32 v = 0, size = sizeof(v);
    OSStatus s = AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, &v);
    if (err) {
        *err = s;
    }
    return s == noErr ? v : 0xFFFFFFFF;
}

std::string GetStr(AudioObjectID obj, AudioObjectPropertySelector sel)
{
    auto a = Addr(sel);
    CFStringRef s = nullptr;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, &s) != noErr || !s) {
        return {};
    }
    std::string r = CFStr(s);
    CFRelease(s);
    return r;
}

std::vector<AudioObjectID> GetIDs(AudioObjectID obj, AudioObjectPropertySelector sel,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    auto a = Addr(sel, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, nullptr, &size) != noErr || size == 0) {
        return {};
    }
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, ids.data()) != noErr) {
        return {};
    }
    ids.resize(size / sizeof(AudioObjectID));
    return ids;
}

AudioObjectID DeviceForUID(const char* uid)
{
    CFStringRef s = CFStringCreateWithCString(nullptr, uid, kCFStringEncodingUTF8);
    auto a = Addr(kAudioHardwarePropertyTranslateUIDToDevice);
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(s), &s, &size, &id);
    CFRelease(s);
    return st == noErr ? id : kAudioObjectUnknown;
}

std::vector<AudioObjectID> Devices()
{
    return GetIDs(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
}

bool InDeviceList(AudioObjectID dev)
{
    if (dev == kAudioObjectUnknown) {
        return false;
    }
    auto d = Devices();
    return std::find(d.begin(), d.end(), dev) != d.end();
}

bool MicListed()
{
    AudioObjectID m = DeviceForUID(kMicUID);
    return m != kAudioObjectUnknown && InDeviceList(m);
}

UInt32 Channels(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    auto a = Addr(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr || size == 0) {
        return 0;
    }
    std::vector<uint8_t> buf(size);
    auto* abl = reinterpret_cast<AudioBufferList*>(buf.data());
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, abl) != noErr) {
        return 0;
    }
    UInt32 ch = 0;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        ch += abl->mBuffers[i].mNumberChannels;
    }
    return ch;
}

double SampleRate(AudioObjectID dev)
{
    auto a = Addr(kAudioDevicePropertyNominalSampleRate);
    Float64 r = 0;
    UInt32 size = sizeof(r);
    AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &r);
    return r;
}

AudioObjectID GetDefault(AudioObjectPropertySelector sel)
{
    auto a = Addr(sel);
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &id);
    return id;
}

OSStatus SetDefaultInput(AudioObjectID dev)
{
    auto a = Addr(kAudioHardwarePropertyDefaultInputDevice);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, sizeof(dev), &dev);
}

std::string UIDOf(AudioObjectID dev)
{
    return dev == kAudioObjectUnknown ? "" : GetStr(dev, kAudioDevicePropertyDeviceUID);
}

std::string TransportStr(UInt32 t)
{
    if (t == 0xFFFFFFFF) {
        return "?";
    }
    char c[5] = {char(t >> 24), char(t >> 16), char(t >> 8), char(t), 0};
    for (char& x : c) {
        if (x && (x < 32 || x > 126)) {
            x = '?';
        }
    }
    return c;
}

struct Defaults
{
    std::string input, output, system;
};

Defaults ReadDefaults()
{
    return {UIDOf(GetDefault(kAudioHardwarePropertyDefaultInputDevice)),
        UIDOf(GetDefault(kAudioHardwarePropertyDefaultOutputDevice)),
        UIDOf(GetDefault(kAudioHardwarePropertyDefaultSystemOutputDevice))};
}

void EmitDefaults(const char* label)
{
    auto d = ReadDefaults();
    EmitRaw("tt.defaults",
        {{"label", S(label)}, {"input", S(d.input)}, {"output", S(d.output)}, {"systemOutput", S(d.system)}});
}

std::string DeviceDesc(AudioObjectID dev)
{
    if (dev == kAudioObjectUnknown) {
        return "{}";
    }
    return "{\"uid\":" + S(UIDOf(dev)) + ",\"name\":" + S(GetStr(dev, kAudioObjectPropertyName)) +
           ",\"transport\":" + S(TransportStr(GetU32(dev, kAudioDevicePropertyTransportType))) + "}";
}

// CF -> JSON (for the diagnostics dictionary)
std::string CFToJSON(CFTypeRef v)
{
    if (!v) {
        return "null";
    }
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) {
        return S(CFStr(static_cast<CFStringRef>(v)));
    }
    if (t == CFNumberGetTypeID()) {
        double d = 0;
        CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberDoubleType, &d);
        if (!CFNumberIsFloatType(static_cast<CFNumberRef>(v))) {
            SInt64 i = 0;
            CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberSInt64Type, &i);
            return std::to_string(i);
        }
        return N(d);
    }
    if (t == CFBooleanGetTypeID()) {
        return B(CFBooleanGetValue(static_cast<CFBooleanRef>(v)));
    }
    if (t == CFArrayGetTypeID()) {
        auto a = static_cast<CFArrayRef>(v);
        std::string o = "[";
        for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
            o += (i ? "," : "") + CFToJSON(CFArrayGetValueAtIndex(a, i));
        }
        return o + "]";
    }
    if (t == CFDictionaryGetTypeID()) {
        auto d = static_cast<CFDictionaryRef>(v);
        CFIndex n = CFDictionaryGetCount(d);
        std::vector<const void*> keys(n), vals(n);
        CFDictionaryGetKeysAndValues(d, keys.data(), vals.data());
        std::vector<std::pair<std::string, std::string>> items;
        for (CFIndex i = 0; i < n; i++) {
            items.emplace_back(CFStr(static_cast<CFStringRef>(keys[i])), CFToJSON(vals[i]));
        }
        std::sort(items.begin(), items.end());
        std::string o = "{";
        for (size_t i = 0; i < items.size(); i++) {
            o += (i ? "," : "") + S(items[i].first) + ":" + items[i].second;
        }
        return o + "}";
    }
    return "\"?\"";
}

CFDictionaryRef CopyDiag()
{
    AudioObjectID feed = DeviceForUID(kFeedUID);
    if (feed == kAudioObjectUnknown) {
        return nullptr;
    }
    auto a = Addr(tt::pins::kDiagnosticsSelector);
    CFPropertyListRef v = nullptr;
    UInt32 size = sizeof(v);
    if (AudioObjectGetPropertyData(feed, &a, 0, nullptr, &size, &v) != noErr || !v) {
        return nullptr;
    }
    if (CFGetTypeID(v) != CFDictionaryGetTypeID()) {
        CFRelease(v);
        return nullptr;
    }
    return static_cast<CFDictionaryRef>(v);
}

int64_t DiagNum(CFDictionaryRef d, const char* key)
{
    if (!d) {
        return -1;
    }
    CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
    auto n = static_cast<CFNumberRef>(CFDictionaryGetValue(d, k));
    CFRelease(k);
    SInt64 v = -1;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) {
        CFNumberGetValue(n, kCFNumberSInt64Type, &v);
    }
    return v;
}

// M2 'ttmm': CFNumber 0/1 on the Feed (custom properties are CFString / CFPropertyList only).
OSStatus SetTTMM(int value)
{
    AudioObjectID feed = DeviceForUID(kFeedUID);
    if (feed == kAudioObjectUnknown) {
        return kAudioHardwareBadDeviceError;
    }
    auto a = Addr(tt::pins::kMeetingModeSelector);
    CFNumberRef n = CFNumberCreate(nullptr, kCFNumberIntType, &value);
    CFPropertyListRef v = n;
    OSStatus s = AudioObjectSetPropertyData(feed, &a, 0, nullptr, sizeof(v), &v);
    CFRelease(n);
    return s;
}

int GetTTMM(OSStatus* err = nullptr)
{
    AudioObjectID feed = DeviceForUID(kFeedUID);
    auto a = Addr(tt::pins::kMeetingModeSelector);
    CFPropertyListRef v = nullptr;
    UInt32 size = sizeof(v);
    OSStatus s = feed == kAudioObjectUnknown ? OSStatus(kAudioHardwareBadDeviceError)
                                             : AudioObjectGetPropertyData(feed, &a, 0, nullptr, &size, &v);
    if (err) {
        *err = s;
    }
    if (s != noErr || !v) {
        return -2;
    }
    int out = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberIntType, &out);
    }
    CFRelease(v);
    return out;
}

// The Mic's kAudioDevicePropertyDeviceCanBeDefaultDevice (input scope); 0xFFFFFFFF = not readable.
UInt32 MicCanBeDefault()
{
    AudioObjectID m = DeviceForUID(kMicUID);
    return m == kAudioObjectUnknown ? 0xFFFFFFFF
                                    : GetU32(m, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput);
}

std::string DiagJSON()
{
    CFDictionaryRef d = CopyDiag();
    std::string j = CFToJSON(d);
    if (d) {
        CFRelease(d);
    }
    return j;
}

std::string SelfBundleID()
{
    CFBundleRef b = CFBundleGetMainBundle();
    CFStringRef id = b ? CFBundleGetIdentifier(b) : nullptr;
    return id ? CFStr(id) : "";
}

std::string SelfPath()
{
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
        return {};
    }
    char real[PATH_MAX];
    return realpath(buf, real) ? real : buf;
}

//--------------------------------------------------------------------------------------------
// signals

double SweepSample(int64_t rel)
{
    // 1 s exponential sweep 40 Hz -> 16 kHz, peak -18 dBFS (§8.4)
    const double T = 1.0, f1 = 40.0, f2 = 16000.0, amp = std::pow(10.0, -18.0 / 20.0);
    const double t = double(rel) / kRate;
    const double k = std::log(f2 / f1);
    const double phase = 2.0 * M_PI * f1 * T / k * (std::exp(t * k / T) - 1.0);
    // 5 ms raised-cosine fades so the sweep has no clicks
    double env = 1.0;
    const double fade = 0.005;
    if (t < fade) {
        env = 0.5 - 0.5 * std::cos(M_PI * t / fade);
    } else if (t > T - fade) {
        env = 0.5 - 0.5 * std::cos(M_PI * (T - t) / fade);
    }
    return amp * env * std::sin(phase);
}

// Deterministic tone keyed by absolute sample time: any replayed or shifted sample shows up
// as a mismatch against Tone(S).
float Tone(int64_t s)
{
    const double cyc = std::fmod(double(s) * 997.0, kRate) / kRate;
    return float(0.25 * std::sin(2.0 * M_PI * cyc));
}

//--------------------------------------------------------------------------------------------
// IO plumbing

struct Chunk
{
    int64_t sampleTime;
    UInt64 nowHost;
    UInt64 ioHost; // inInputTime / inOutputTime host time
    UInt32 frames;
    UInt32 offset;
};

// Preallocated recording (RT-safe append).
struct Recording
{
    std::vector<float> samples;
    std::vector<Chunk> chunks;
    std::atomic<size_t> nSamples {0};
    std::atomic<size_t> nChunks {0};

    void Reserve(size_t frames, size_t nchunks)
    {
        samples.assign(frames, 0.0f);
        chunks.assign(nchunks, Chunk {});
    }

    void Append(int64_t st, UInt64 now, UInt64 io, const float* data, UInt32 frames, UInt32 stride)
    {
        size_t off = nSamples.load(std::memory_order_relaxed);
        size_t ci = nChunks.load(std::memory_order_relaxed);
        if (ci >= chunks.size()) {
            return;
        }
        if (!data && samples.empty()) {
            // timing-only log (the writer's): record the chunk, no samples
            chunks[ci] = {st, now, io, frames, 0};
            nChunks.store(ci + 1, std::memory_order_release);
            return;
        }
        if (off + frames > samples.size()) {
            return;
        }
        for (UInt32 i = 0; i < frames; i++) {
            samples[off + i] = data ? data[size_t(i) * stride] : 0.0f;
        }
        chunks[ci] = {st, now, io, frames, UInt32(off)};
        nSamples.store(off + frames, std::memory_order_release);
        nChunks.store(ci + 1, std::memory_order_release);
    }
};

enum class Signal
{
    Silence,
    Tone,
    Sweep,
};

struct Range
{
    int64_t begin, end;
};

struct WriterCtx
{
    UInt32 channel = 0; // 0-based
    Signal signal = Signal::Silence;
    std::atomic<int64_t> firstS {INT64_MIN};
    std::atomic<int64_t> endS {INT64_MIN};
    std::atomic<uint64_t> cycles {0};
    std::atomic<uint64_t> discontinuities {0};
    int64_t lastEnd = INT64_MIN;
    Recording* log = nullptr; // optional: chunk timing only (no samples)
    Range ranges[512];
    std::atomic<int> nRanges {0};
};

OSStatus WriterProc(AudioObjectID, const AudioTimeStamp* now, const AudioBufferList*, const AudioTimeStamp*,
    AudioBufferList* out, const AudioTimeStamp* outTime, void* ctxp)
{
    auto* c = static_cast<WriterCtx*>(ctxp);
    if (!out || out->mNumberBuffers == 0) {
        return noErr;
    }
    AudioBuffer& buf = out->mBuffers[0];
    const UInt32 ch = buf.mNumberChannels;
    const UInt32 frames = buf.mDataByteSize / (sizeof(float) * (ch ? ch : 1));
    auto* f = static_cast<float*>(buf.mData);
    const int64_t s0 = int64_t(std::llround(outTime->mSampleTime));

    int64_t first = c->firstS.load(std::memory_order_relaxed);
    if (first == INT64_MIN) {
        first = s0;
        c->firstS.store(s0, std::memory_order_relaxed);
    }
    // Range bookkeeping: a new range starts whenever output time is not contiguous.
    if (c->lastEnd != s0) {
        if (c->lastEnd != INT64_MIN) {
            c->discontinuities.fetch_add(1, std::memory_order_relaxed);
        }
        int n = c->nRanges.load(std::memory_order_relaxed);
        if (n < 512) {
            c->ranges[n] = {s0, s0 + frames};
            c->nRanges.store(n + 1, std::memory_order_release);
        }
    } else {
        int n = c->nRanges.load(std::memory_order_relaxed);
        if (n > 0) {
            c->ranges[n - 1].end = s0 + frames;
        }
    }
    c->lastEnd = s0 + frames;

    for (UInt32 i = 0; i < frames; i++) {
        float v = 0.0f;
        const int64_t s = s0 + i;
        switch (c->signal) {
        case Signal::Silence:
            break;
        case Signal::Tone:
            v = Tone(s);
            break;
        case Signal::Sweep: {
            const int64_t rel = s - first - 12000; // 250 ms of silence first
            if (rel >= 0 && rel < 48000) {
                v = float(SweepSample(rel));
            }
            break;
        }
        }
        for (UInt32 k = 0; k < ch; k++) {
            f[size_t(i) * ch + k] = (k == c->channel) ? v : 0.0f;
        }
    }
    if (c->log) {
        c->log->Append(s0, now->mHostTime, outTime->mHostTime, nullptr, frames, 1);
    }
    c->endS.store(s0 + frames, std::memory_order_release);
    c->cycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

struct ReaderCtx
{
    Recording* rec = nullptr; // full recording (optional)
    // live stats
    std::atomic<uint64_t> frames {0};
    std::atomic<uint64_t> nonzero {0};
    std::atomic<uint64_t> cycles {0};
    std::atomic<uint64_t> discontinuities {0};
    int64_t lastEnd = INT64_MIN;
    std::atomic<float> peak {0.0f};
    // soak verification against a Tone writer (optional)
    WriterCtx* verifyAgainst = nullptr;
    std::atomic<uint64_t> checked {0};
    std::atomic<uint64_t> mismatches {0};
    std::atomic<uint64_t> unexpectedZeros {0};
    std::atomic<int64_t> firstMismatchS {INT64_MIN};
    std::atomic<float> maxErr {0.0f};
};

OSStatus ReaderProc(AudioObjectID, const AudioTimeStamp* now, const AudioBufferList* in, const AudioTimeStamp* inTime,
    AudioBufferList*, const AudioTimeStamp*, void* ctxp)
{
    auto* c = static_cast<ReaderCtx*>(ctxp);
    if (!in || in->mNumberBuffers == 0) {
        return noErr;
    }
    const AudioBuffer& buf = in->mBuffers[0];
    const UInt32 ch = buf.mNumberChannels ? buf.mNumberChannels : 1;
    const UInt32 frames = buf.mDataByteSize / (sizeof(float) * ch);
    const auto* f = static_cast<const float*>(buf.mData);
    const int64_t s0 = int64_t(std::llround(inTime->mSampleTime));

    if (c->lastEnd != INT64_MIN && c->lastEnd != s0) {
        c->discontinuities.fetch_add(1, std::memory_order_relaxed);
    }
    c->lastEnd = s0 + frames;

    uint64_t nz = 0;
    float pk = c->peak.load(std::memory_order_relaxed);
    for (UInt32 i = 0; f && i < frames; i++) {
        const float x = f[size_t(i) * ch];
        if (x != 0.0f) {
            nz++;
        }
        pk = std::max(pk, std::fabs(x));
    }
    c->peak.store(pk, std::memory_order_relaxed);
    c->nonzero.fetch_add(nz, std::memory_order_relaxed);
    c->frames.fetch_add(frames, std::memory_order_relaxed);
    c->cycles.fetch_add(1, std::memory_order_relaxed);

    if (c->verifyAgainst && f) {
        const int64_t first = c->verifyAgainst->firstS.load(std::memory_order_acquire);
        const int64_t end = c->verifyAgainst->endS.load(std::memory_order_acquire);
        // Only check sample times that the writer has definitely written (with margin), so
        // the check is exact: any deviation is a glitch, a gap, or a replay.
        uint64_t chk = 0, mm = 0, uz = 0;
        float me = c->maxErr.load(std::memory_order_relaxed);
        for (UInt32 i = 0; i < frames; i++) {
            const int64_t src = s0 + i - kLag;
            if (first == INT64_MIN || src < first + 4800 || src >= end) {
                continue;
            }
            const float x = f[size_t(i) * ch];
            const float e = Tone(src);
            const float err = std::fabs(x - e);
            chk++;
            if (err > 1e-6f) {
                mm++;
                if (x == 0.0f) {
                    uz++;
                }
                int64_t expect = INT64_MIN;
                c->firstMismatchS.compare_exchange_strong(expect, s0 + i);
            }
            me = std::max(me, err);
        }
        c->maxErr.store(me, std::memory_order_relaxed);
        c->checked.fetch_add(chk, std::memory_order_relaxed);
        c->mismatches.fetch_add(mm, std::memory_order_relaxed);
        c->unexpectedZeros.fetch_add(uz, std::memory_order_relaxed);
    }

    if (c->rec) {
        c->rec->Append(s0, now->mHostTime, inTime->mHostTime, f, frames, ch);
    }
    return noErr;
}

struct IOProcHandle
{
    AudioObjectID dev = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    OSStatus createStatus = noErr;
    OSStatus startStatus = noErr;
    UInt32 bufferFrames = 0;

    bool Start(AudioObjectID d, AudioDeviceIOProc fn, void* ctx, UInt32 wantFrames = 480)
    {
        dev = d;
        if (wantFrames) {
            auto a = Addr(kAudioDevicePropertyBufferFrameSize);
            AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(wantFrames), &wantFrames);
        }
        bufferFrames = GetU32(dev, kAudioDevicePropertyBufferFrameSize);
        createStatus = AudioDeviceCreateIOProcID(dev, fn, ctx, &proc);
        if (createStatus != noErr) {
            proc = nullptr;
            return false;
        }
        startStatus = AudioDeviceStart(dev, proc);
        return startStatus == noErr;
    }

    void Stop()
    {
        if (proc) {
            AudioDeviceStop(dev, proc);
            AudioDeviceDestroyIOProcID(dev, proc);
            proc = nullptr;
        }
    }

    ~IOProcHandle()
    {
        Stop();
    }
};

//--------------------------------------------------------------------------------------------
// args

struct Args
{
    std::vector<std::string> v;
    std::string Get(const char* name, const std::string& def = {}) const
    {
        for (size_t i = 0; i + 1 < v.size(); i++) {
            if (v[i] == name) {
                return v[i + 1];
            }
        }
        return def;
    }
    double Num(const char* name, double def) const
    {
        auto s = Get(name);
        return s.empty() ? def : std::atof(s.c_str());
    }
    bool Has(const char* name) const
    {
        return std::find(v.begin(), v.end(), name) != v.end();
    }
};

std::atomic<bool> gQuit {false};
std::atomic<bool> gRestarted {false};

void OnSignal(int)
{
    gQuit = true;
}

OSStatus OnServiceRestarted(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void*)
{
    gRestarted = true;
    return noErr;
}

//--------------------------------------------------------------------------------------------
// child processes

// --hold-exe PATH: run "hold" children from another binary. Every process that loads CoreAudio
// becomes a HAL client of every device (AddDeviceClient at HAL init, not at IOProc creation), so a
// tester running as com.aaajiao.talktalk.dev would itself keep the Mic listed. visibility / d2 run
// the tester as FeedProbe.app (refused) and only the hold child as TTDriverBench (allowed).
std::string gHoldExe;

pid_t Spawn(const std::vector<std::string>& args, int keepFd = -1)
{
    std::vector<char*> argv;
    std::string self = (!args.empty() && args[0] == "hold" && !gHoldExe.empty()) ? gHoldExe : SelfPath();
    argv.push_back(const_cast<char*>(self.c_str()));
    for (auto& a : args) {
        argv.push_back(const_cast<char*>(a.c_str()));
    }
    argv.push_back(nullptr);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (keepFd >= 0) {
        // The lock fd is O_CLOEXEC in the parent. On macOS adddup2(fd, fd) does NOT clear
        // FD_CLOEXEC (first d6 run: child's fstat failed, lock dropped with the parent);
        // addinherit_np is the documented way (man posix_spawn_file_actions_addclose).
        posix_spawn_file_actions_addinherit_np(&fa, keepFd);
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    pid_t pid = -1;
    int rc = posix_spawn(&pid, self.c_str(), &fa, &attr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    return rc == 0 ? pid : -1;
}

void Reap(pid_t pid)
{
    if (pid > 0) {
        int st = 0;
        waitpid(pid, &st, 0);
    }
}

bool WaitFor(const std::function<bool()>& cond, double timeoutMs, double stepMs = 5)
{
    const double end = NowMs() + timeoutMs;
    while (NowMs() < end) {
        if (cond()) {
            return true;
        }
        SleepMs(stepMs);
    }
    return cond();
}

// Records default input/output at construction, restores both at destruction.
struct DefaultsGuard
{
    Defaults before;
    explicit DefaultsGuard(const char* label)
        : before(ReadDefaults())
    {
        EmitDefaults((std::string(label) + ".before").c_str());
    }
    ~DefaultsGuard()
    {
        Restore();
    }
    void Restore()
    {
        auto now = ReadDefaults();
        if (now.input != before.input) {
            AudioObjectID d = DeviceForUID(before.input.c_str());
            if (d != kAudioObjectUnknown) {
                SetDefaultInput(d);
                SleepMs(200);
            }
        }
        auto after = ReadDefaults();
        EmitRaw("tt.defaults.restore",
            {{"inputBefore", S(before.input)},
                {"inputAfter", S(after.input)},
                {"inputRestored", B(after.input == before.input)},
                {"outputBefore", S(before.output)},
                {"outputAfter", S(after.output)},
                {"outputUnchanged", B(after.output == before.output)},
                {"systemOutputUnchanged", B(after.system == before.system)}});
    }
};

//--------------------------------------------------------------------------------------------
// commands

int CmdList(const Args&)
{
    EmitRaw("tt.self", {{"bundleID", S(SelfBundleID())}, {"pid", N(getpid())}});
    for (auto d : Devices()) {
        EmitRaw("tt.device",
            {{"id", N(d)},
                {"uid", S(UIDOf(d))},
                {"name", S(GetStr(d, kAudioObjectPropertyName))},
                {"transport", S(TransportStr(GetU32(d, kAudioDevicePropertyTransportType)))},
                {"in", N(Channels(d, kAudioObjectPropertyScopeInput))},
                {"out", N(Channels(d, kAudioObjectPropertyScopeOutput))},
                {"rate", N(SampleRate(d))}});
    }
    for (const char* uid : {kFeedUID, kMicUID, kTestMicUID}) {
        AudioObjectID d = DeviceForUID(uid);
        if (d == kAudioObjectUnknown) {
            EmitRaw("tt.ttdevice", {{"uid", S(uid)}, {"resolvable", B(false)}});
            continue;
        }
        EmitRaw("tt.ttdevice",
            {{"uid", S(uid)},
                {"resolvable", B(true)},
                {"id", N(d)},
                {"inDeviceList", B(InDeviceList(d))},
                {"name", S(GetStr(d, kAudioObjectPropertyName))},
                {"manufacturer", S(GetStr(d, kAudioObjectPropertyManufacturer))},
                {"firmware", S(GetStr(d, kAudioObjectPropertyFirmwareVersion))},
                {"hidden", N(GetU32(d, kAudioDevicePropertyIsHidden))},
                {"alive", N(GetU32(d, kAudioDevicePropertyDeviceIsAlive))},
                {"runningSomewhere", N(GetU32(d, kAudioDevicePropertyDeviceIsRunningSomewhere))},
                {"canBeDefaultIn", N(GetU32(d, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput))},
                {"canBeDefaultOut", N(GetU32(d, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput))},
                {"canBeSystemOut", N(GetU32(d, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput))},
                {"transport", S(TransportStr(GetU32(d, kAudioDevicePropertyTransportType)))},
                {"clockDomain", N(GetU32(d, kAudioDevicePropertyClockDomain))},
                {"in", N(Channels(d, kAudioObjectPropertyScopeInput))},
                {"out", N(Channels(d, kAudioObjectPropertyScopeOutput))},
                {"rate", N(SampleRate(d))},
                {"latencyIn", N(GetU32(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput))},
                {"latencyOut", N(GetU32(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput))},
                {"safetyIn", N(GetU32(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput))},
                {"safetyOut", N(GetU32(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput))},
                {"bufferFrames", N(GetU32(d, kAudioDevicePropertyBufferFrameSize))}});
    }
    EmitDefaults("now");
    EmitRaw("tt.diag", {{"diag", DiagJSON()}});
    return 0;
}

int CmdDiag(const Args&)
{
    EmitRaw("tt.diag", {{"diag", DiagJSON()}});
    return 0;
}

int CmdDefaults(const Args&)
{
    EmitDefaults("now");
    return 0;
}

int CmdSetDefaultInput(const Args& a)
{
    if (a.v.size() < 2) {
        Note("usage: set-default-input UID");
        return 2;
    }
    EmitDefaults("before");
    AudioObjectID d = DeviceForUID(a.v[1].c_str());
    OSStatus st = d == kAudioObjectUnknown ? OSStatus(kAudioHardwareBadDeviceError) : SetDefaultInput(d);
    SleepMs(200);
    EmitRaw("tt.result", {{"test", S("set-default-input")}, {"status", N(st)}, {"target", S(a.v[1])}});
    EmitDefaults("after");
    return st == noErr ? 0 : 1;
}

int CmdHold(const Args& a)
{
    signal(SIGTERM, OnSignal);
    signal(SIGINT, OnSignal);
    auto ra = Addr(kAudioHardwarePropertyServiceRestarted);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &ra, OnServiceRestarted, nullptr);

    WriterCtx w;
    w.channel = UInt32(a.Num("--channel", 1)) - 1;
    const std::string sig = a.Get("--signal", "silence");
    w.signal = sig == "sine" ? Signal::Tone : Signal::Silence;
    const double seconds = a.Num("--seconds", 0);
    const double end = seconds > 0 ? NowMs() + seconds * 1000 : 1e300;

    IOProcHandle h;
    int setups = 0;
    auto setup = [&]() {
        h.Stop();
        AudioObjectID feed = kAudioObjectUnknown;
        WaitFor([&] { return (feed = DeviceForUID(kFeedUID)) != kAudioObjectUnknown; }, 15000, 50);
        bool ok = feed != kAudioObjectUnknown && h.Start(feed, WriterProc, &w);
        setups++;
        EmitRaw("tt.hold",
            {{"event", S(setups == 1 ? "ready" : "re-setup")},
                {"ok", B(ok)},
                {"feed", N(feed)},
                {"create", N(h.createStatus)},
                {"start", N(h.startStatus)},
                {"bufferFrames", N(h.bufferFrames)},
                {"bundleID", S(SelfBundleID())},
                {"pid", N(getpid())}});
        return ok;
    };
    const bool ok = setup();
    if (ok && a.Has("--ttmm")) {
        // talktalk entering meeting mode: the hold child is the accepted Feed client, so it writes.
        const int want = int(a.Num("--ttmm", 1));
        WaitFor(MicListed, 5000);
        const OSStatus st = SetTTMM(want);
        // Since 0.2.3 capability stays true; ttmm reports session state independently.
        if (st == noErr) {
            WaitFor([&] { return GetTTMM() == want; }, 1000, 2);
        }
        EmitRaw("tt.hold",
            {{"event", S("ttmm")}, {"want", N(want)}, {"status", N(st)}, {"readback", N(GetTTMM())},
                {"micCanBeDefault", N(MicCanBeDefault())}});
    }
    while (!gQuit && NowMs() < end) {
        if (gRestarted.exchange(false)) {
            SleepMs(500);
            setup();
        }
        SleepMs(20);
    }
    h.Stop();
    EmitRaw("tt.hold", {{"event", S("exit")}, {"cycles", N(double(w.cycles.load()))}});
    return 0;
}

int CmdRead(const Args& a)
{
    signal(SIGTERM, OnSignal);
    signal(SIGINT, OnSignal);
    const std::string uid = a.Get("--uid", kMicUID);
    const double seconds = a.Num("--seconds", 0);
    const double end = seconds > 0 ? NowMs() + seconds * 1000 : 1e300;
    ReaderCtx r;
    IOProcHandle h;
    AudioObjectID dev = kAudioObjectUnknown;
    WaitFor([&] { return (dev = DeviceForUID(uid.c_str())) != kAudioObjectUnknown; }, 15000, 50);
    bool ok = dev != kAudioObjectUnknown && h.Start(dev, ReaderProc, &r);
    EmitRaw("tt.read",
        {{"event", S("ready")}, {"uid", S(uid)}, {"ok", B(ok)}, {"create", N(h.createStatus)}, {"start", N(h.startStatus)}});
    double nextReport = NowMs() + 1000;
    while (!gQuit && NowMs() < end) {
        SleepMs(20);
        if (NowMs() >= nextReport) {
            nextReport += 1000;
            EmitRaw("tt.read",
                {{"event", S("stats")},
                    {"frames", N(double(r.frames.load()))},
                    {"nonzero", N(double(r.nonzero.load()))},
                    {"peak", N(r.peak.load())},
                    {"discontinuities", N(double(r.discontinuities.load()))}});
        }
    }
    h.Stop();
    EmitRaw("tt.read", {{"event", S("exit")}, {"frames", N(double(r.frames.load()))}, {"nonzero", N(double(r.nonzero.load()))}});
    return 0;
}

int CmdProbe(const Args&)
{
    CFDictionaryRef d0 = CopyDiag();
    const int64_t addDenied0 = DiagNum(d0, "feedAddClientDenied");
    const int64_t ioDenied0 = DiagNum(d0, "feedStartIODenied");
    if (d0) {
        CFRelease(d0);
    }

    AudioObjectID feed = DeviceForUID(kFeedUID);
    WriterCtx w;
    w.signal = Signal::Tone;
    IOProcHandle h;
    bool started = feed != kAudioObjectUnknown && h.Start(feed, WriterProc, &w);
    SleepMs(1000);
    const uint64_t cycles = w.cycles.load();
    h.Stop();
    SleepMs(200);

    CFDictionaryRef d1 = CopyDiag();
    const int64_t addDenied = DiagNum(d1, "feedAddClientDenied") - addDenied0;
    const int64_t ioDenied = DiagNum(d1, "feedStartIODenied") - ioDenied0;
    std::string clients = "[]";
    if (d1) {
        clients = CFToJSON(CFDictionaryGetValue(d1, CFSTR("departed")));
        CFRelease(d1);
    }
    const bool refused = !started || cycles == 0;
    EmitRaw("tt.result",
        {{"test", S("probe")},
            {"bundleID", S(SelfBundleID())},
            {"feed", N(feed)},
            {"createStatus", N(h.createStatus)},
            {"startStatus", N(h.startStatus)},
            {"ioCycles", N(double(cycles))},
            {"driverAddClientDenied", N(double(addDenied))},
            {"driverStartIODenied", N(double(ioDenied))},
            {"refused", B(refused)},
            {"recentClients", clients}});
    return 0;
}

// Cross-correlate recorded input (indexed by sample time) against the written signal.
struct LoopStats
{
    int64_t bestLag = -1;
    double peak = 0;
    double levelDb = NAN;
    uint64_t nonzeroOutside = 0;
    uint64_t samples = 0;
    uint64_t nonzero = 0;
};

LoopStats AnalyzeLoop(const Recording& rec, int64_t firstWritten, bool expectSignal)
{
    LoopStats st;
    const size_t nc = rec.nChunks.load();
    if (nc == 0 || firstWritten == INT64_MIN) {
        return st;
    }
    // Dense copy of the recording indexed by sample time (gaps = not recorded).
    int64_t lo = INT64_MAX, hi = INT64_MIN;
    for (size_t c = 0; c < nc; c++) {
        lo = std::min(lo, rec.chunks[c].sampleTime);
        hi = std::max(hi, rec.chunks[c].sampleTime + int64_t(rec.chunks[c].frames));
    }
    std::vector<float> R(size_t(hi - lo), 0.0f);
    std::vector<uint8_t> have(size_t(hi - lo), 0);
    for (size_t c = 0; c < nc; c++) {
        const Chunk& k = rec.chunks[c];
        for (UInt32 i = 0; i < k.frames; i++) {
            const float x = rec.samples[k.offset + i];
            const size_t at = size_t(k.sampleTime + i - lo);
            R[at] = x;
            have[at] = 1;
            st.samples++;
            if (x != 0.0f) {
                st.nonzero++;
            }
        }
    }
    if (!expectSignal) {
        return st;
    }
    const int64_t sweepBegin = firstWritten + 12000;
    const int64_t sweepLen = 48000;
    std::vector<double> W(sweepLen);
    double eRef = 0;
    for (int64_t j = 0; j < sweepLen; j++) {
        W[j] = SweepSample(j);
        eRef += W[j] * W[j];
    }
    // Search lag 0..4800 frames: dot product of the sweep with the recording shifted by lag.
    double bestNum = -1e300, bestNorm = 0;
    int64_t best = -1;
    for (int64_t lag = 0; lag <= 4800; lag++) {
        double num = 0, eRec = 0;
        for (int64_t j = 0; j < sweepLen; j++) {
            const int64_t at = sweepBegin + j + lag - lo;
            if (at < 0 || at >= int64_t(R.size()) || !have[at]) {
                continue;
            }
            const double x = R[at];
            num += x * W[j];
            eRec += x * x;
        }
        if (num > bestNum) {
            bestNum = num;
            best = lag;
            bestNorm = (eRec > 0 && eRef > 0) ? num / std::sqrt(eRec * eRef) : 0;
        }
    }
    st.bestLag = best;
    st.peak = bestNorm;
    double eRec = 0;
    for (size_t at = 0; at < R.size(); at++) {
        if (!have[at]) {
            continue;
        }
        const int64_t src = int64_t(at) + lo - best;
        if (src >= sweepBegin && src < sweepBegin + sweepLen) {
            eRec += double(R[at]) * double(R[at]);
        } else if (R[at] != 0.0f) {
            st.nonzeroOutside++;
        }
    }
    st.levelDb = (eRec > 0 && eRef > 0) ? 10.0 * std::log10(eRec / eRef) : NAN;
    return st;
}

int CmdLoopback(const Args& a)
{
    const int channel = int(a.Num("--channel", 2));
    AudioObjectID feed = DeviceForUID(kFeedUID);
    AudioObjectID testMic = DeviceForUID(kTestMicUID);
    if (feed == kAudioObjectUnknown || testMic == kAudioObjectUnknown) {
        EmitRaw("tt.result", {{"test", S("loopback")}, {"error", S("Feed or Test Mic not found")}});
        return 1;
    }

    WriterCtx w;
    w.channel = UInt32(channel - 1);
    // Silence until the readers run; the sweep is written only by the second writer run
    // (first T8 run wrote the sweep's first ~100 ms before the restart).
    w.signal = Signal::Silence;
    Recording wlog;
    wlog.Reserve(0, 2000);
    w.log = &wlog;
    IOProcHandle hw;
    if (!hw.Start(feed, WriterProc, &w)) {
        EmitRaw("tt.result", {{"test", S("loopback")}, {"error", S("Feed IO failed")}, {"create", N(hw.createStatus)}, {"start", N(hw.startStatus)}});
        return 1;
    }
    // Mic appears once we are attached to the Feed.
    AudioObjectID mic = kAudioObjectUnknown;
    const double t0 = NowMs();
    WaitFor([&] { return (mic = DeviceForUID(kMicUID)) != kAudioObjectUnknown && InDeviceList(mic); }, 3000);
    const double micAppearMs = NowMs() - t0;

    Recording rMic, rTest;
    rMic.Reserve(48000 * 6, 4000);
    rTest.Reserve(48000 * 6, 4000);
    ReaderCtx cm, ct;
    cm.rec = &rMic;
    ct.rec = &rTest;
    IOProcHandle hm, ht;
    bool micOK = mic != kAudioObjectUnknown && hm.Start(mic, ReaderProc, &cm);
    bool testOK = ht.Start(testMic, ReaderProc, &ct);

    // Restart the writer so its sweep starts after both readers are running.
    SleepMs(300);
    hw.Stop();
    w.firstS = INT64_MIN;
    w.lastEnd = INT64_MIN;
    w.nRanges = 0;
    wlog.nChunks = 0;
    w.signal = Signal::Sweep;
    hw.Start(feed, WriterProc, &w);
    SleepMs(2500);
    hw.Stop();
    SleepMs(300);
    hm.Stop();
    ht.Stop();

    CFDictionaryRef diag = CopyDiag();
    const int64_t micHits = DiagNum(diag, "micReadHitFrames");
    const int64_t testHits = DiagNum(diag, "testMicReadHitFrames");
    if (diag) {
        CFRelease(diag);
    }

    const int64_t first = w.firstS.load();
    LoopStats sm = AnalyzeLoop(rMic, first, channel == 1);
    LoopStats stt = AnalyzeLoop(rTest, first, channel == 2);
    const LoopStats& sig = channel == 1 ? sm : stt;
    const LoopStats& iso = channel == 1 ? stt : sm;

    // Callback-to-callback latency: host time of the Feed callback that wrote the sweep's
    // first sample vs. host time of the reader callback that delivered it.
    double cbLatencyMs = NAN, tsLatencyMs = NAN;
    const Recording& rr = channel == 1 ? rMic : rTest;
    const int64_t sweepFirst = first + 12000;
    for (size_t i = 0; i < wlog.nChunks.load(); i++) {
        const Chunk& k = wlog.chunks[i];
        if (sweepFirst >= k.sampleTime && sweepFirst < k.sampleTime + k.frames) {
            for (size_t j = 0; j < rr.nChunks.load(); j++) {
                const Chunk& r = rr.chunks[j];
                const int64_t want = sweepFirst + (sig.bestLag >= 0 ? sig.bestLag : kLag);
                if (want >= r.sampleTime && want < r.sampleTime + r.frames) {
                    cbLatencyMs = HostToMs(r.nowHost) - HostToMs(k.nowHost);
                    tsLatencyMs = HostToMs(r.ioHost) - HostToMs(k.ioHost);
                    break;
                }
            }
            break;
        }
    }

    const bool tccSuspect = sig.nonzero == 0 && (channel == 1 ? micHits : testHits) > 0;
    EmitRaw("tt.result",
        {{"test", S("loopback")},
            {"channel", N(channel)},
            {"micAppearMs", N(micAppearMs)},
            {"micStarted", B(micOK)},
            {"testMicStarted", B(testOK)},
            {"feedBufferFrames", N(hw.bufferFrames)},
            {"readerBufferFrames", N(channel == 1 ? hm.bufferFrames : ht.bufferFrames)},
            {"lagFrames", N(double(sig.bestLag))},
            {"addedLatencyMs", N(sig.bestLag >= 0 ? double(sig.bestLag) / 48.0 : NAN)},
            {"peak", N(sig.peak)},
            {"levelDeltaDb", N(sig.levelDb)},
            {"nonzeroOutsideSweep", N(double(sig.nonzeroOutside))},
            {"signalSamples", N(double(sig.samples))},
            {"signalNonzero", N(double(sig.nonzero))},
            {"isolationDevice", S(channel == 1 ? "testmic" : "mic")},
            {"isolationSamples", N(double(iso.samples))},
            {"isolationNonzero", N(double(iso.nonzero))},
            {"callbackToCallbackMs", N(cbLatencyMs)},
            {"timestampToTimestampMs", N(tsLatencyMs)},
            {"writerDiscontinuities", N(double(w.discontinuities.load()))},
            {"readerDiscontinuities", N(double((channel == 1 ? cm : ct).discontinuities.load()))},
            {"driverMicHitFrames", N(double(micHits))},
            {"driverTestMicHitFrames", N(double(testHits))},
            {"tccSuspect", B(tccSuspect)},
            {"pass", B(sig.bestLag >= 0 && sig.bestLag <= 480 && sig.peak >= 0.95 && std::fabs(sig.levelDb) <= 0.5 &&
                       sig.nonzeroOutside == 0 && iso.nonzero == 0)}});
    return 0;
}

int CmdReplay(const Args& a)
{
    const int cycles = int(a.Num("--cycles", 20));
    AudioObjectID feed = DeviceForUID(kFeedUID);
    if (feed == kAudioObjectUnknown) {
        EmitRaw("tt.result", {{"test", S("replay")}, {"error", S("Feed not found")}});
        return 1;
    }
    // No keep-alive writer on purpose: a second client writing zeros would overwrite stale
    // slots and hide a replay. Our own reader IO keeps the Mic in the list between cycles.
    WriterCtx w;
    w.signal = Signal::Tone;
    w.channel = 0;
    auto first = std::make_unique<IOProcHandle>();
    first->Start(feed, WriterProc, &w);
    AudioObjectID mic = kAudioObjectUnknown;
    WaitFor([&] { return (mic = DeviceForUID(kMicUID)) != kAudioObjectUnknown && InDeviceList(mic); }, 3000);

    Recording rec;
    rec.Reserve(size_t(48000 * (cycles + 4)), 20000);
    ReaderCtx rc;
    rc.rec = &rec;
    IOProcHandle hr;
    hr.Start(mic, ReaderProc, &rc);
    SleepMs(500);

    for (int i = 0; i < cycles; i++) {
        if (i > 0) {
            first = std::make_unique<IOProcHandle>();
            w.lastEnd = INT64_MIN; // new range per cycle
            first->Start(feed, WriterProc, &w);
        }
        SleepMs(500);
        first->Stop(); // AudioDeviceStop + DestroyIOProcID: the driver sees StopIO
        SleepMs(500);
    }
    SleepMs(200);
    hr.Stop();

    // Every recorded sample must be Tone(S - 480) if S - 480 was written by the tone client,
    // and exactly 0 otherwise.
    const int nr = w.nRanges.load();
    auto written = [&](int64_t s) {
        for (int i = 0; i < nr; i++) {
            if (s >= w.ranges[i].begin && s < w.ranges[i].end) {
                return true;
            }
        }
        return false;
    };
    uint64_t checked = 0, playedOK = 0, playedBad = 0, silentOK = 0, silentBad = 0;
    for (size_t c = 0; c < rec.nChunks.load(); c++) {
        const Chunk& k = rec.chunks[c];
        for (UInt32 i = 0; i < k.frames; i++) {
            const int64_t s = k.sampleTime + i;
            const float x = rec.samples[k.offset + i];
            checked++;
            if (written(s - kLag)) {
                (std::fabs(x - Tone(s - kLag)) <= 1e-6f ? playedOK : playedBad)++;
            } else {
                (x == 0.0f ? silentOK : silentBad)++;
            }
        }
    }
    EmitRaw("tt.result",
        {{"test", S("replay")},
            {"cycles", N(cycles)},
            {"ranges", N(nr)},
            {"checkedFrames", N(double(checked))},
            {"playedFramesOK", N(double(playedOK))},
            {"playedFramesBad", N(double(playedBad))},
            {"silentFramesOK", N(double(silentOK))},
            {"silentFramesNonzero", N(double(silentBad))},
            {"readerDiscontinuities", N(double(rc.discontinuities.load()))},
            {"pass", B(playedBad == 0 && silentBad == 0 && playedOK > 0 && nr >= cycles)}});
    return 0;
}

std::atomic<uint64_t> gOverloads {0};
OSStatus OnOverload(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void*)
{
    gOverloads++;
    return noErr;
}

int CmdSoak(const Args& a)
{
    signal(SIGTERM, OnSignal);
    signal(SIGINT, OnSignal);
    const double minutes = a.Num("--minutes", 60);
    AudioObjectID feed = DeviceForUID(kFeedUID);
    if (feed == kAudioObjectUnknown) {
        EmitRaw("tt.result", {{"test", S("soak")}, {"error", S("Feed not found")}});
        return 1;
    }
    WriterCtx w;
    w.signal = Signal::Tone;
    w.channel = 0;
    IOProcHandle hw;
    hw.Start(feed, WriterProc, &w);
    AudioObjectID mic = kAudioObjectUnknown;
    WaitFor([&] { return (mic = DeviceForUID(kMicUID)) != kAudioObjectUnknown; }, 3000);
    ReaderCtx r;
    r.verifyAgainst = &w;
    IOProcHandle hr;
    hr.Start(mic, ReaderProc, &r);
    auto oa = Addr(kAudioDeviceProcessorOverload);
    AudioObjectAddPropertyListener(feed, &oa, OnOverload, nullptr);
    AudioObjectAddPropertyListener(mic, &oa, OnOverload, nullptr);

    const double t0 = NowMs(), end = t0 + minutes * 60000;
    double next = t0 + 60000;
    while (!gQuit && NowMs() < end) {
        SleepMs(100);
        if (NowMs() >= next) {
            next += 60000;
            EmitRaw("tt.soak",
                {{"minute", N(std::round((NowMs() - t0) / 60000))},
                    {"checked", N(double(r.checked.load()))},
                    {"mismatches", N(double(r.mismatches.load()))},
                    {"unexpectedZeros", N(double(r.unexpectedZeros.load()))},
                    {"writerDiscontinuities", N(double(w.discontinuities.load()))},
                    {"readerDiscontinuities", N(double(r.discontinuities.load()))},
                    {"overloads", N(double(gOverloads.load()))}});
        }
    }
    hr.Stop();
    hw.Stop();
    const uint64_t mm = r.mismatches.load();
    EmitRaw("tt.result",
        {{"test", S("soak")},
            {"minutes", N((NowMs() - t0) / 60000)},
            {"checkedFrames", N(double(r.checked.load()))},
            {"mismatches", N(double(mm))},
            {"unexpectedZeros", N(double(r.unexpectedZeros.load()))},
            {"maxAbsError", N(r.maxErr.load())},
            {"firstMismatchSampleTime", N(double(r.firstMismatchS.load()))},
            {"writerDiscontinuities", N(double(w.discontinuities.load()))},
            {"readerDiscontinuities", N(double(r.discontinuities.load()))},
            {"overloads", N(double(gOverloads.load()))},
            {"readerPeak", N(r.peak.load())},
            {"pass", B(mm == 0 && r.checked.load() > 0 && w.discontinuities.load() == 0 && r.discontinuities.load() == 0)}});
    return 0;
}

// Mic in / out of the device list as a talktalk-like Feed client attaches, exits cleanly and
// is killed (§8.3 5 s grace).
int CmdVisibility(const Args&)
{
    struct Run
    {
        const char* how;
        int sig;
    };
    for (Run run : {Run {"sigterm", SIGTERM}, Run {"kill9", SIGKILL}}) {
        WaitFor([] { return !MicListed(); }, 8000, 20);
        const double t0 = NowMs();
        pid_t hold = Spawn({"hold"});
        bool appeared = WaitFor(MicListed, 5000, 2);
        const double appearMs = NowMs() - t0;
        SleepMs(1000);
        const double tk = NowMs();
        kill(hold, run.sig);
        Reap(hold);
        // Still there during the grace period?
        bool stillAt4s = WaitFor([] { return !MicListed(); }, 4000, 5) == false;
        bool gone = WaitFor([] { return !MicListed(); }, 6000, 5);
        const double goneMs = NowMs() - tk;
        EmitRaw("tt.result",
            {{"test", S("visibility")},
                {"exit", S(run.how)},
                {"testerBundleID", S(SelfBundleID())},
                {"appeared", B(appeared)},
                {"appearMs", N(appearMs)},
                {"stillListedAt4s", B(stillAt4s)},
                {"removed", B(gone)},
                {"removedAfterMs", N(goneMs)},
                {"pass", B(appeared && appearMs <= 1000 && stillAt4s && gone && goneMs <= 6500)}});
    }
    return 0;
}

int CmdTTMM(const Args& a)
{
    const bool set = a.v.size() >= 3 && a.v[1] == "set";
    OSStatus setStatus = 0;
    const UInt32 cbdBefore = MicCanBeDefault();
    if (set) {
        setStatus = SetTTMM(std::atoi(a.v[2].c_str()));
        SleepMs(50);
    }
    OSStatus getStatus = 0;
    const int value = GetTTMM(&getStatus);
    CFDictionaryRef d = CopyDiag();
    EmitRaw("tt.result",
        {{"test", S(set ? "ttmm.set" : "ttmm.get")},
            {"bundleID", S(SelfBundleID())},
            {"pid", N(getpid())},
            {"setValue", set ? N(std::atoi(a.v[2].c_str())) : std::string("null")},
            {"setStatus", N(setStatus)},
            {"getStatus", N(getStatus)},
            {"value", N(value)},
            {"micListed", B(MicListed())},
            {"micCanBeDefaultBefore", N(cbdBefore)},
            {"micCanBeDefault", N(MicCanBeDefault())},
            {"diagTtmmLastPID", N(double(DiagNum(d, "ttmmLastPID")))},
            {"diagTtmmWrites", N(double(DiagNum(d, "ttmmWrites")))},
            {"diagTtmmDenied", N(double(DiagNum(d, "ttmmDenied")))},
            {"diagVersion", S(d ? CFToJSON(CFDictionaryGetValue(d, CFSTR("version"))) : std::string("null"))}});
    if (d) {
        CFRelease(d);
    }
    return 0;
}

std::atomic<int> gCbdNotes {0};
std::atomic<double> gCbdNoteMs {NAN};

OSStatus OnMicCanBeDefault(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void*)
{
    if (std::isnan(gCbdNoteMs.load())) {
        gCbdNoteMs = NowMs();
    }
    gCbdNotes.fetch_add(1);
    return noErr;
}

// Follows the default input for `ms` after an action; returns a JSON trace and the last UID.
std::string TraceDefaultInput(double ms, std::string* last, double* firstChangeMs)
{
    const double t0 = NowMs();
    std::string prev = UIDOf(GetDefault(kAudioHardwarePropertyDefaultInputDevice));
    std::string trace = "[{\"ms\":0,\"input\":" + S(prev) + "}";
    *firstChangeMs = NAN;
    while (NowMs() < t0 + ms) {
        AudioObjectID cur = GetDefault(kAudioHardwarePropertyDefaultInputDevice);
        std::string uid = cur == kAudioObjectUnknown ? std::string("(none)") : UIDOf(cur);
        if (uid != prev) {
            const double at = NowMs() - t0;
            if (std::isnan(*firstChangeMs)) {
                *firstChangeMs = at;
            }
            trace += ",{\"ms\":" + N(at) + ",\"input\":" + S(uid) + "}";
            prev = uid;
        }
        SleepMs(2);
    }
    *last = prev;
    return trace + "]";
}

// Historical 0.2.0-0.2.2 dynamic CanBeDefaultDevice experiment. The measurements remain
// available, but the expected false->true transition/notification does not apply to 0.2.3+.
// Run as TTDriverBench through open (part 3 starts a Mic reader).
int CmdM2a(const Args& a)
{
    DefaultsGuard guard("m2a");
    const bool listed = WaitFor(MicListed, 5000); // this process is an accepted Feed client itself
    AudioObjectID mic = DeviceForUID(kMicUID);
    auto isMicDefault = [&] { return GetDefault(kAudioHardwarePropertyDefaultInputDevice) == mic; };
    auto la = Addr(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeWildcard);
    const OSStatus listenStatus = mic == kAudioObjectUnknown ? -1 : AudioObjectAddPropertyListener(mic, &la, OnMicCanBeDefault, nullptr);

    // 1. ttmm 0: the HAL must not accept the Mic as default input.
    const int ttmm0 = GetTTMM();
    const UInt32 cbd0 = MicCanBeDefault();
    const OSStatus set0 = SetDefaultInput(mic);
    const bool became0 = WaitFor(isMicDefault, 1500, 2);
    if (became0) {
        guard.Restore();
    }

    // 2. ttmm 1: CanBeDefaultDevice 1, notified; then the Mic can be made default.
    gCbdNotes = 0;
    gCbdNoteMs = NAN;
    const double t1 = NowMs();
    const OSStatus w1 = SetTTMM(1);
    const bool cbd1 = WaitFor([] { return MicCanBeDefault() == 1; }, 1000, 1);
    const double cbd1Ms = NowMs() - t1;
    WaitFor([] { return gCbdNotes.load() > 0; }, 1000, 1);
    const double note1Ms = gCbdNoteMs.load() - t1;
    const int notes1 = gCbdNotes.load();
    const double t2 = NowMs();
    const OSStatus set1 = SetDefaultInput(mic);
    const bool became1 = WaitFor(isMicDefault, 2000, 1);
    const double became1Ms = NowMs() - t2;
    const bool outputSame1 = ReadDefaults().output == guard.before.output;

    // 3. ttmm 0 while the Mic is the default input, nobody reading it.
    std::string last3;
    double change3 = NAN;
    const OSStatus w3 = became1 ? SetTTMM(0) : OSStatus(-1);
    const std::string trace3 = became1 ? TraceDefaultInput(5000, &last3, &change3) : "[]";
    guard.Restore();

    // 4. the same with a reader on the Mic (a meeting app that follows the system default would
    //    be moved to whatever macOS picks now).
    SetTTMM(1);
    WaitFor([] { return MicCanBeDefault() == 1; }, 1000, 1);
    SetDefaultInput(mic);
    const bool became4 = WaitFor(isMicDefault, 2000, 1);
    pid_t reader = Spawn({"read", "--uid", kMicUID});
    const bool reading = WaitFor([&] { return GetU32(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1; }, 3000);
    SleepMs(500);
    std::string last4;
    double change4 = NAN;
    const OSStatus w4 = became4 ? SetTTMM(0) : OSStatus(-1);
    const std::string trace4 = became4 ? TraceDefaultInput(5000, &last4, &change4) : "[]";
    const bool readerStillRunning = GetU32(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1;
    kill(reader, SIGTERM);
    Reap(reader);
    guard.Restore();
    SetTTMM(0);

    if (listenStatus == noErr) {
        AudioObjectRemovePropertyListener(mic, &la, OnMicCanBeDefault, nullptr);
    }
    CFDictionaryRef d = CopyDiag();
    const int64_t lastPID = DiagNum(d, "ttmmLastPID");
    if (d) {
        CFRelease(d);
    }
    EmitRaw("tt.result",
        {{"test", S("m2a")},
            {"bundleID", S(SelfBundleID())},
            {"pid", N(getpid())},
            {"micListed", B(listed)},
            {"p1_ttmm", N(ttmm0)},
            {"p1_micCanBeDefault", N(cbd0)},
            {"p1_setDefaultStatus", N(set0)},
            {"p1_becameDefault", B(became0)},
            {"p2_ttmmWriteStatus", N(w1)},
            {"p2_canBeDefault1", B(cbd1)},
            {"p2_canBeDefault1Ms", N(cbd1Ms)},
            {"p2_notifications", N(notes1)},
            {"p2_notificationMs", N(note1Ms)},
            {"p2_diagLastPID", N(double(lastPID))},
            {"p2_halPassedOwnPID", B(lastPID == getpid())},
            {"p2_setDefaultStatus", N(set1)},
            {"p2_becameDefault", B(became1)},
            {"p2_becameDefaultMs", N(became1Ms)},
            {"p2_outputUnchanged", B(outputSame1)},
            {"p3_ttmm0Status", N(w3)},
            {"p3_defaultInputTrace", trace3},
            {"p3_firstChangeMs", N(change3)},
            {"p3_defaultAfter", S(last3)},
            {"p4_becameDefault", B(became4)},
            {"p4_readerRunning", B(reading)},
            {"p4_ttmm0Status", N(w4)},
            {"p4_defaultInputTrace", trace4},
            {"p4_firstChangeMs", N(change4)},
            {"p4_defaultAfter", S(last4)},
            {"p4_readerStillRunning", B(readerStillRunning)},
            {"pass", B(listed && cbd0 == 0 && !became0 && w1 == noErr && cbd1 && notes1 > 0 && became1 && outputSame1)}});
    return 0;
}

int CmdD1(const Args&)
{
    DefaultsGuard guard("d1");
    pid_t hold = Spawn({"hold"});
    bool listed = WaitFor(MicListed, 5000);
    AudioObjectID mic = DeviceForUID(kMicUID);
    const double t0 = NowMs();
    OSStatus st = SetDefaultInput(mic);
    bool became = WaitFor([&] { return GetDefault(kAudioHardwarePropertyDefaultInputDevice) == mic; }, 2000, 2);
    const double ms = NowMs() - t0;
    auto during = ReadDefaults();
    SleepMs(3000); // leave time to look at System Settings / meeting apps if watching
    guard.Restore();
    kill(hold, SIGTERM);
    Reap(hold);
    EmitRaw("tt.result",
        {{"test", S("d1")},
            {"micListed", B(listed)},
            {"setStatus", N(st)},
            {"becameDefault", B(became)},
            {"setToReadBackMs", N(ms)},
            {"outputUnchangedWhileMicDefault", B(during.output == guard.before.output)},
            {"pass", B(listed && st == noErr && became && during.output == guard.before.output)}});
    return 0;
}

int CmdD2(const Args& a)
{
    const int runs = int(a.Num("--runs", 5));
    const bool withTTMM = a.Has("--ttmm");
    DefaultsGuard guard(withTTMM ? "d2-ttmm" : "d2");
    int passes = 0;
    for (int run = 1; run <= runs; run++) {
        WaitFor([] { return !MicListed(); }, 8000, 20);
        pid_t hold = withTTMM ? Spawn({"hold", "--ttmm", "1"}) : Spawn({"hold"});
        bool listed = WaitFor(MicListed, 5000);
        AudioObjectID mic = DeviceForUID(kMicUID);
        if (withTTMM) {
            WaitFor([] { return MicCanBeDefault() == 1; }, 2000, 2);
        }
        const UInt32 cbdBefore = MicCanBeDefault();
        SetDefaultInput(mic);
        bool isDefault = WaitFor([&] { return GetDefault(kAudioHardwarePropertyDefaultInputDevice) == mic; }, 2000);
        pid_t reader = Spawn({"read", "--uid", kMicUID});
        WaitFor([&] { return GetU32(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1; }, 3000);
        SleepMs(500);

        // kill -9 the talktalk stand-in while a reader is attached
        kill(hold, SIGKILL);
        Reap(hold);
        SleepMs(7000);
        const bool stayed = MicListed();
        const bool stillDefault = GetDefault(kAudioHardwarePropertyDefaultInputDevice) == mic;
        const UInt32 cbdAfterKill9 = MicCanBeDefault();
        CFDictionaryRef d = CopyDiag();
        const int64_t feedClients = DiagNum(d, "feedClients");
        const int64_t micIO = DiagNum(d, "micIO");
        if (d) {
            CFRelease(d);
        }

        // stop the reader -> 5 s grace -> Mic removed -> macOS picks a new default input
        const double tStop = NowMs();
        kill(reader, SIGKILL);
        Reap(reader);
        // Trace the default input until 3 s after it first changes: the first value seen is
        // often kAudioObjectUnknown (first d2 run), the settled one is what macOS picked.
        double removedMs = NAN, switchedMs = NAN, settledMs = NAN;
        AudioObjectID newDefault = kAudioObjectUnknown;
        std::string trace = "[";
        std::string lastUID = UIDOf(mic);
        const double deadline = tStop + 15000;
        while (NowMs() < deadline) {
            const double now = NowMs() - tStop;
            if (std::isnan(removedMs) && !MicListed()) {
                removedMs = now;
            }
            AudioObjectID cur = GetDefault(kAudioHardwarePropertyDefaultInputDevice);
            const std::string curUID = cur == kAudioObjectUnknown ? std::string("(none)") : UIDOf(cur);
            if (curUID != lastUID) {
                trace += (trace.size() > 1 ? "," : "") + std::string("{\"ms\":") + N(now) + ",\"input\":" + S(curUID) + "}";
                lastUID = curUID;
            }
            if (std::isnan(switchedMs) && cur != mic) {
                switchedMs = now;
            }
            if (cur != mic && cur != kAudioObjectUnknown) {
                if (cur != newDefault) {
                    newDefault = cur;
                    settledMs = now;
                }
            }
            if (!std::isnan(removedMs) && !std::isnan(switchedMs) && now > switchedMs + 3000) {
                break;
            }
            SleepMs(2);
        }
        trace += "]";
        const UInt32 tr = newDefault == kAudioObjectUnknown ? 0 : GetU32(newDefault, kAudioDevicePropertyTransportType);
        const bool physical = newDefault != kAudioObjectUnknown && tr != kAudioDeviceTransportTypeVirtual &&
                              tr != kAudioDeviceTransportTypeAggregate;
        const double switchAfterRemoval = settledMs - removedMs;

        // d3 (folded in): bring talktalk back; does macOS re-select the Mic as default?
        pid_t hold2 = Spawn({"hold"});
        bool back = WaitFor(MicListed, 5000);
        SleepMs(3000);
        const bool reselected = GetDefault(kAudioHardwarePropertyDefaultInputDevice) == DeviceForUID(kMicUID);
        const UInt32 cbdAfterReturn = MicCanBeDefault();
        kill(hold2, SIGTERM);
        Reap(hold2);

        const bool pass = listed && isDefault && stayed && stillDefault && !std::isnan(settledMs) && physical &&
                          switchAfterRemoval <= 2000 && !reselected;
        passes += pass;
        EmitRaw("tt.result",
            {{"test", S(withTTMM ? "d2-ttmm" : "d2")},
                {"run", N(run)},
                {"micCanBeDefaultBefore", N(cbdBefore)},
                {"micCanBeDefaultAfterKill9", N(cbdAfterKill9)},
                {"micCanBeDefaultAfterReturn", N(cbdAfterReturn)},
                {"testerBundleID", S(SelfBundleID())},
                {"micWasDefault", B(isDefault)},
                {"micStayedWithReaderAfterKill9", B(stayed)},
                {"stillDefaultWithReader", B(stillDefault)},
                {"diagFeedClientsAfterKill9", N(double(feedClients))},
                {"diagMicIOAfterKill9", N(double(micIO))},
                {"removedAfterReaderStopMs", N(removedMs)},
                {"defaultSwitchedAfterReaderStopMs", N(switchedMs)},
                {"defaultSettledAfterReaderStopMs", N(settledMs)},
                {"defaultInputTrace", trace},
                {"switchAfterRemovalMs", N(switchAfterRemoval)},
                {"newDefault", DeviceDesc(newDefault)},
                {"newDefaultPhysical", B(physical)},
                {"d3_micBack", B(back)},
                {"d3_reselectedAsDefault", B(reselected)},
                {"pass", B(pass)}});
        guard.Restore();
    }
    EmitRaw("tt.result", {{"test", S(withTTMM ? "d2-ttmm.summary" : "d2.summary")}, {"runs", N(runs)}, {"passes", N(passes)}});
    return 0;
}

// d4: coreaudiod restart while the Mic is the default input. Run this, then (as root, in
// another terminal) `scripts/driver/install-driver.sh restart-audio` within 60 s.
int CmdD4(const Args& a)
{
    const bool withTTMM = a.Has("--ttmm");
    DefaultsGuard guard(withTTMM ? "d4-ttmm" : "d4");
    pid_t hold = withTTMM ? Spawn({"hold", "--ttmm", "1"}) : Spawn({"hold"});
    WaitFor(MicListed, 5000);
    if (withTTMM) {
        WaitFor([] { return MicCanBeDefault() == 1; }, 2000, 2);
    }
    const UInt32 cbdBefore = MicCanBeDefault();
    CFDictionaryRef d0 = CopyDiag();
    const std::string versionBefore = d0 ? CFToJSON(CFDictionaryGetValue(d0, CFSTR("version"))) : "null";
    if (d0) {
        CFRelease(d0);
    }
    AudioObjectID mic = DeviceForUID(kMicUID);
    SetDefaultInput(mic);
    bool isDefault = WaitFor([&] { return GetDefault(kAudioHardwarePropertyDefaultInputDevice) == mic; }, 2000);
    auto ra = Addr(kAudioHardwarePropertyServiceRestarted);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &ra, OnServiceRestarted, nullptr);
    EmitRaw("tt.d4", {{"event", S("waiting-for-restart")}, {"micDefault", B(isDefault)}});
    const double wait = a.Num("--wait", 90) * 1000;
    bool restarted = WaitFor([] { return gRestarted.load(); }, wait, 20);
    const double tR = NowMs();
    // Sample the default input for 10 s after the restart.
    std::vector<std::pair<double, std::string>> trace;
    std::string last = "?";
    bool micBackMs_set = false;
    double micBackMs = NAN;
    while (restarted && NowMs() < tR + 10000) {
        std::string cur = UIDOf(GetDefault(kAudioHardwarePropertyDefaultInputDevice));
        if (cur != last) {
            trace.emplace_back(NowMs() - tR, cur);
            last = cur;
        }
        if (!micBackMs_set && MicListed()) {
            micBackMs = NowMs() - tR;
            micBackMs_set = true;
        }
        SleepMs(5);
    }
    std::string tj = "[";
    for (size_t i = 0; i < trace.size(); i++) {
        tj += (i ? "," : "") + std::string("{\"ms\":") + N(trace[i].first) + ",\"input\":" + S(trace[i].second) + "}";
    }
    tj += "]";
    CFDictionaryRef d1 = CopyDiag();
    const std::string versionAfter = d1 ? CFToJSON(CFDictionaryGetValue(d1, CFSTR("version"))) : "null";
    if (d1) {
        CFRelease(d1);
    }
    EmitRaw("tt.result",
        {{"test", S(withTTMM ? "d4-ttmm" : "d4")},
            {"micDefaultBefore", B(isDefault)},
            {"micCanBeDefaultBefore", N(cbdBefore)},
            {"micCanBeDefaultAfter", N(MicCanBeDefault())},
            {"driverVersionBefore", versionBefore},
            {"driverVersionAfter", versionAfter},
            {"restartSeen", B(restarted)},
            {"micBackAfterMs", N(micBackMs)},
            {"defaultInputTrace", tj},
            {"defaultInputAfter", S(last)}});
    kill(hold, SIGTERM);
    Reap(hold);
    return 0;
}

// d5: while the Mic is the default input, which processes read it?
int CmdD5(const Args& a)
{
    const double seconds = a.Num("--seconds", 30);
    DefaultsGuard guard("d5");
    pid_t hold = Spawn({"hold"});
    WaitFor(MicListed, 5000);
    AudioObjectID mic = DeviceForUID(kMicUID);
    SetDefaultInput(mic);
    WaitFor([&] { return GetDefault(kAudioHardwarePropertyDefaultInputDevice) == mic; }, 2000);
    std::map<std::string, int> readers; // bundle/pid -> samples seen reading
    int samples = 0, runningSomewhere = 0;
    const double end = NowMs() + seconds * 1000;
    while (NowMs() < end) {
        samples++;
        if (GetU32(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1) {
            runningSomewhere++;
        }
        for (auto p : GetIDs(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
            if (GetU32(p, kAudioProcessPropertyIsRunningInput) != 1) {
                continue;
            }
            auto devs = GetIDs(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput);
            if (std::find(devs.begin(), devs.end(), mic) == devs.end()) {
                continue;
            }
            pid_t pid = 0;
            auto pa = Addr(kAudioProcessPropertyPID);
            UInt32 sz = sizeof(pid);
            AudioObjectGetPropertyData(p, &pa, 0, nullptr, &sz, &pid);
            readers[GetStr(p, kAudioProcessPropertyBundleID) + "#" + std::to_string(pid)]++;
        }
        SleepMs(500);
    }
    std::string rj = "{";
    bool firstItem = true;
    for (auto& [k, v] : readers) {
        rj += (firstItem ? "" : ",") + S(k) + ":" + N(v);
        firstItem = false;
    }
    rj += "}";
    std::string clients = "[]";
    if (CFDictionaryRef d = CopyDiag()) {
        clients = CFToJSON(CFDictionaryGetValue(d, CFSTR("clients")));
        CFRelease(d);
    }
    EmitRaw("tt.result",
        {{"test", S("d5")},
            {"seconds", N(seconds)},
            {"samples", N(samples)},
            {"micRunningSomewhereSamples", N(runningSomewhere)},
            {"processesReadingMic", rj},
            {"driverClients", clients}});
    guard.Restore();
    kill(hold, SIGTERM);
    Reap(hold);
    return 0;
}

// d6 child: what `TalkTalk --sysinput-guard` must be able to do without TCC prompts.
int CmdGuardChild(const Args& a)
{
    const int fd = int(a.Num("--lock-fd", -1));
    const std::string restoreUID = a.Get("--restore-uid");
    // 1. read the process object list (MeetingSourceResolver needs this)
    auto procs = GetIDs(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList);
    int withBundle = 0;
    for (auto p : procs) {
        if (!GetStr(p, kAudioProcessPropertyBundleID).empty()) {
            withBundle++;
        }
    }
    // 2. still own the lock?
    struct stat st {};
    const bool fdValid = fd >= 0 && fstat(fd, &st) == 0;
    // 3. wait until the parent is gone (stdin EOF in the real guard; here: parent pid 1)
    const pid_t parent = getppid();
    WaitFor([&] { return getppid() != parent; }, 30000, 20);
    const bool parentGone = getppid() != parent;
    // 4. write the default input back (the restore)
    AudioObjectID target = DeviceForUID(restoreUID.c_str());
    OSStatus ws = target == kAudioObjectUnknown ? OSStatus(kAudioHardwareBadDeviceError) : SetDefaultInput(target);
    SleepMs(300);
    const bool restored = UIDOf(GetDefault(kAudioHardwarePropertyDefaultInputDevice)) == restoreUID;
    EmitRaw("tt.result",
        {{"test", S("d6.child")},
            {"processObjects", N(double(procs.size()))},
            {"processObjectsWithBundleID", N(withBundle)},
            {"lockFdValid", B(fdValid)},
            {"parentGone", B(parentGone)},
            {"writeStatus", N(ws)},
            {"restored", B(restored)}});
    SleepMs(1500); // keep the lock a little longer so the tester can probe it
    return 0;
}

// d6: the parent plays "the app": takes the restore lock, spawns the guard child with the lock
// fd, switches the default input to the Mic, then the tester kills the parent with -9 and
// checks that the lock survives (held by the child) and that the child restores the default.
int CmdD6(const Args& a)
{
    const std::string lockPath = a.Get("--lock", std::string(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp") + "/tt-d6.lock");
    if (a.Has("--as-app")) {
        // --- the "app" side (gets kill -9'd by the tester) ---
        int fd = open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
            EmitRaw("tt.result", {{"test", S("d6.app")}, {"error", S("lock failed")}});
            return 1;
        }
        WaitFor(MicListed, 5000);
        const std::string original = a.Get("--restore-uid");
        pid_t child = Spawn({"guard-child", "--lock-fd", std::to_string(fd), "--restore-uid", original}, fd);
        SetDefaultInput(DeviceForUID(kMicUID));
        EmitRaw("tt.d6", {{"event", S("app-ready")}, {"child", N(child)}});
        for (;;) {
            SleepMs(1000); // wait to be killed
        }
    }

    // --- the tester ---
    DefaultsGuard guard("d6");
    std::remove(lockPath.c_str());
    // The tester (not the "app") holds the Feed so the Mic stays listed and we can clean up.
    pid_t hold = Spawn({"hold"});
    WaitFor(MicListed, 5000);
    // Run the app side as a child of the tester; its output goes to our stdout.
    pid_t app = Spawn({"d6", "--as-app", "--lock", lockPath, "--restore-uid", guard.before.input});
    bool micDefault = WaitFor([] { return UIDOf(GetDefault(kAudioHardwarePropertyDefaultInputDevice)) == kMicUID; }, 8000);
    SleepMs(500);
    kill(app, SIGKILL);
    Reap(app);
    // Lock must still be held (by the guard child).
    int fd = open(lockPath.c_str(), O_RDWR | O_CLOEXEC);
    const bool lockHeldAfterKill = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK;
    // The guard child restores the default input once it sees its parent die.
    bool restored = WaitFor([&] { return UIDOf(GetDefault(kAudioHardwarePropertyDefaultInputDevice)) == guard.before.input; }, 10000);
    // After the child exits the kernel drops the lock.
    bool lockFreed = WaitFor([&] { return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0; }, 10000, 50);
    if (fd >= 0) {
        close(fd);
    }
    kill(hold, SIGTERM);
    Reap(hold);
    EmitRaw("tt.result",
        {{"test", S("d6")},
            {"micWasDefault", B(micDefault)},
            {"lockHeldByChildAfterKill9", B(lockHeldAfterKill)},
            {"childRestoredDefault", B(restored)},
            {"lockFreedAfterChildExit", B(lockFreed)},
            {"pass", B(micDefault && lockHeldAfterKill && restored && lockFreed)}});
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    Args a;
    for (int i = 1; i < argc; i++) {
        a.v.emplace_back(argv[i]);
    }
    // --out FILE: append JSON lines to a file (for runs launched with `open`).
    const std::string out = a.Get("--out");
    if (!out.empty()) {
        if (!std::freopen(out.c_str(), "a", stdout)) {
            return 3;
        }
    }
    if (a.v.empty()) {
        std::fprintf(stderr, "usage: ttdrv <command> [...]  (see the header of tools/bench/driver/ttdrv.cpp)\n");
        return 2;
    }
    // Run the HAL's notifications on its own thread (no run loop in this tool).
    auto rl = Addr(kAudioHardwarePropertyRunLoop);
    CFRunLoopRef none = nullptr;
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof(none), &none);

    gHoldExe = a.Get("--hold-exe");
    const std::string cmd = a.v[0];
    static const std::map<std::string, int (*)(const Args&)> cmds = {
        {"list", CmdList},
        {"diag", CmdDiag},
        {"defaults", CmdDefaults},
        {"set-default-input", CmdSetDefaultInput},
        {"hold", CmdHold},
        {"read", CmdRead},
        {"probe", CmdProbe},
        {"loopback", CmdLoopback},
        {"replay", CmdReplay},
        {"soak", CmdSoak},
        {"visibility", CmdVisibility},
        {"ttmm", CmdTTMM},
        {"m2a", CmdM2a},
        {"d1", CmdD1},
        {"d2", CmdD2},
        {"d4", CmdD4},
        {"d5", CmdD5},
        {"d6", CmdD6},
        {"guard-child", CmdGuardChild},
    };
    auto it = cmds.find(cmd);
    if (it == cmds.end()) {
        std::fprintf(stderr, "ttdrv: unknown command %s\n", cmd.c_str());
        return 2;
    }
    return it->second(a);
}
