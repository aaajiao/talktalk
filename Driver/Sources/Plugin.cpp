// TalkTalkAudio.driver entry point (ARCHITECTURE.md §8.2, §8.3).
//
// Object tree:
//   Plugin
//   ├── TalkTalk Feed       com.aaajiao.talktalk.feed     hidden, output, 2 ch
//   ├── TalkTalk Test Mic   com.aaajiao.talktalk.testmic  hidden, input, reads ch 2
//   └── TalkTalk Mic        com.aaajiao.talktalk.mic      input, reads ch 1, in the list only
//                                                         while used (MicVisibility)
// All three run on one shared clock (SharedClock), 48 kHz Float32.
//
// The plug-in writes no files, opens no network, and needs no mach services (§8.3). The only
// way to look inside is the Feed's read-only 'ttdg' property and os_log
// (subsystem com.aaajiao.talktalk.audio-driver).

#include "FeedDevice.hpp"
#include "MicDevice.hpp"
#include "Shared.hpp"

#include <aspl/Driver.hpp>
#include <aspl/Tracer.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <cmath>
#include <ctime>

namespace tt {

os_log_t Log()
{
    static os_log_t log = os_log_create("com.aaajiao.talktalk.audio-driver", "driver");
    return log;
}

int64_t NowNanos()
{
    return int64_t(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
}

//--------------------------------------------------------------------------------------------
// SharedClock

SharedClock::SharedClock()
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    const Float64 hostTicksPerSecond = 1.0e9 * Float64(tb.denom) / Float64(tb.numer);
    ticksPerFrame_ = hostTicksPerSecond / Float64(kSampleRate);
    anchor_ = mach_absolute_time();
}

void SharedClock::GetZeroTimeStamp(Float64* outSampleTime, UInt64* outHostTime) const
{
    const UInt64 now = mach_absolute_time();
    const Float64 ticksPerPeriod = ticksPerFrame_ * Float64(kZeroTimeStampPeriod);
    const UInt64 elapsed = now > anchor_ ? now - anchor_ : 0;
    const UInt64 period = UInt64(std::floor(Float64(elapsed) / ticksPerPeriod));

    *outSampleTime = Float64(period) * Float64(kZeroTimeStampPeriod);
    *outHostTime = anchor_ + UInt64(std::llround(Float64(period) * ticksPerPeriod));
}

//--------------------------------------------------------------------------------------------
// Diagnostics

namespace {

std::string Key(const std::string& device, UInt32 clientID)
{
    return device + "/" + std::to_string(clientID);
}

void SetNum(CFMutableDictionaryRef dict, const char* key, int64_t v)
{
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &v);
    CFDictionarySetValue(dict, k, n);
    CFRelease(n);
    CFRelease(k);
}

void SetStr(CFMutableDictionaryRef dict, const char* key, const std::string& v)
{
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, v.c_str(), kCFStringEncodingUTF8);
    CFDictionarySetValue(dict, k, s ? s : CFSTR(""));
    if (s) {
        CFRelease(s);
    }
    CFRelease(k);
}

CFMutableDictionaryRef NewDict()
{
    return CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

CFDictionaryRef ClientDict(const ClientRecord& c)
{
    CFMutableDictionaryRef d = NewDict();
    SetStr(d, "device", c.device);
    SetNum(d, "clientID", c.clientID);
    SetNum(d, "pid", c.pid);
    SetStr(d, "bundleID", c.bundleID);
    SetNum(d, "allowed", c.allowed ? 1 : 0);
    SetNum(d, "ioRunning", c.ioRunning ? 1 : 0);
    SetNum(d, "addedNanos", c.addedNanos);
    SetNum(d, "removedNanos", c.removedNanos);
    SetNum(d, "sigDone", c.sig.done ? 1 : 0);
    if (c.sig.done) {
        SetNum(d, "sigGuestStatus", c.sig.guestStatus);
        SetNum(d, "sigInfoStatus", c.sig.infoStatus);
        SetNum(d, "sigValidityStatus", c.sig.validityStatus);
        SetStr(d, "sigIdentifier", c.sig.identifier);
        SetStr(d, "sigTeamID", c.sig.teamID);
        SetStr(d, "sigCDHash", c.sig.cdhash);
        SetNum(d, "sigFlags", c.sig.flags);
        SetNum(d, "sigElapsedNanos", c.sig.elapsedNanos);
    }
    return d;
}

} // namespace

void Diagnostics::AddClient(const ClientRecord& rec)
{
    std::lock_guard lock(mutex_);
    clients_[Key(rec.device, rec.clientID)] = rec;
}

void Diagnostics::RemoveClient(const std::string& device, UInt32 clientID)
{
    std::lock_guard lock(mutex_);
    auto it = clients_.find(Key(device, clientID));
    if (it == clients_.end()) {
        return;
    }
    it->second.removedNanos = NowNanos();
    it->second.ioRunning = false;
    departed_.push_back(it->second);
    while (departed_.size() > 16) {
        departed_.pop_front();
    }
    clients_.erase(it);
}

void Diagnostics::SetClientIO(const std::string& device, UInt32 clientID, bool running)
{
    std::lock_guard lock(mutex_);
    auto it = clients_.find(Key(device, clientID));
    if (it != clients_.end()) {
        it->second.ioRunning = running;
    }
}

void Diagnostics::SetSignature(const std::string& device, UInt32 clientID, const SignatureProbe& sig)
{
    std::lock_guard lock(mutex_);
    auto it = clients_.find(Key(device, clientID));
    if (it != clients_.end()) {
        it->second.sig = sig;
        return;
    }
    for (auto& d : departed_) {
        if (d.device == device && d.clientID == clientID) {
            d.sig = sig;
        }
    }
}

void Diagnostics::Event(const std::string& what)
{
    std::lock_guard lock(mutex_);
    events_.emplace_back(NowNanos(), what);
    while (events_.size() > 64) {
        events_.pop_front();
    }
}

CFPropertyListRef Diagnostics::CopyDictionary(const std::map<std::string, int64_t>& extra) const
{
    CFMutableDictionaryRef root = NewDict();
    SetStr(root, "version", kDriverVersion);
    SetNum(root, "nowNanos", NowNanos());
    SetNum(root, "anchorHostTime", int64_t(GetShared().clock.AnchorHostTime()));
    SetNum(root, "sampleRate", kSampleRate);
    SetNum(root, "zeroTimeStampPeriod", kZeroTimeStampPeriod);
    SetNum(root, "micLagFrames", kMicLagFrames);
    SetNum(root, "feedAddClientDenied", int64_t(feedAddClientDenied.load()));
    SetNum(root, "feedStartIODenied", int64_t(feedStartIODenied.load()));
    SetNum(root, "feedWriteCycles", int64_t(feedWriteCycles.load()));
    SetNum(root, "feedWriteDroppedCycles", int64_t(feedWriteDroppedCycles.load()));
    SetNum(root, "micReadCycles", int64_t(micReadCycles.load()));
    SetNum(root, "micReadHitFrames", int64_t(micReadHitFrames.load()));
    SetNum(root, "testMicReadCycles", int64_t(testMicReadCycles.load()));
    SetNum(root, "testMicReadHitFrames", int64_t(testMicReadHitFrames.load()));
    SetNum(root, "micShows", int64_t(micShows.load()));
    SetNum(root, "micHides", int64_t(micHides.load()));
    SetNum(root, "ttmmWrites", int64_t(ttmmWrites.load()));
    SetNum(root, "ttmmDenied", int64_t(ttmmDenied.load()));
    SetNum(root, "ttmmLastPID", ttmmLastPID.load());
    for (const auto& [k, v] : extra) {
        SetNum(root, k.c_str(), v);
    }

    std::lock_guard lock(mutex_);

    CFMutableArrayRef clients = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (const auto& [k, c] : clients_) {
        CFDictionaryRef d = ClientDict(c);
        CFArrayAppendValue(clients, d);
        CFRelease(d);
    }
    CFDictionarySetValue(root, CFSTR("clients"), clients);
    CFRelease(clients);

    CFMutableArrayRef departed = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (const auto& c : departed_) {
        CFDictionaryRef d = ClientDict(c);
        CFArrayAppendValue(departed, d);
        CFRelease(d);
    }
    CFDictionarySetValue(root, CFSTR("departed"), departed);
    CFRelease(departed);

    CFMutableArrayRef events = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (const auto& [t, what] : events_) {
        CFMutableDictionaryRef e = NewDict();
        SetNum(e, "nanos", t);
        SetStr(e, "event", what);
        CFArrayAppendValue(events, e);
        CFRelease(e);
    }
    CFDictionarySetValue(root, CFSTR("events"), events);
    CFRelease(events);

    return root;
}

//--------------------------------------------------------------------------------------------

Shared& GetShared()
{
    // Intentionally leaked: the driver host never unloads the plug-in, and IO threads may
    // still touch the rings during process teardown.
    static Shared* shared = new Shared();
    return *shared;
}

namespace {

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto& shared = GetShared();
    shared.probeQueue =
        dispatch_queue_create("com.aaajiao.talktalk.audio-driver.sigprobe", DISPATCH_QUEUE_SERIAL);

    auto tracer = std::make_shared<aspl::Tracer>(
        TT_DRIVER_TRACE ? aspl::Tracer::Mode::Syslog : aspl::Tracer::Mode::Noop);
    auto context = std::make_shared<aspl::Context>(tracer);

    aspl::PluginParameters pluginParams;
    pluginParams.Manufacturer = kManufacturer;
    auto plugin = std::make_shared<aspl::Plugin>(context, pluginParams);

    auto feed = MakeFeedDevice(context);
    auto testMic = MakeTestMicDevice(context);
    auto mic = MakeMicDevice(context);

    feed->RegisterCustomProperty(kDiagnosticsSelector, [&shared]() -> CFPropertyListRef {
        return shared.diag.CopyDictionary(shared.visibility.Snapshot());
    });
    // 'ttmm' (M2): FeedDevice::SetPropertyData checks the caller and the value first.
    feed->RegisterCustomProperty(
        kMeetingModeSelector,
        std::function<CFPropertyListRef()>([&shared]() -> CFPropertyListRef {
            return CopyMeetingModeValue(shared.visibility.MeetingMode());
        }),
        std::function<void(CFPropertyListRef)>([&shared](CFPropertyListRef value) {
            shared.visibility.SetMeetingMode(ParseMeetingModeValue(value) == 1);
        }));

    plugin->AddDevice(feed);
    plugin->AddDevice(testMic);
    shared.visibility.Init(plugin, mic, &shared.diag);

    shared.diag.Event(std::string("driver.created version=") + kDriverVersion);
    os_log(Log(),
        "TalkTalkAudio %{public}s created (micMode=%d)",
        kDriverVersion,
        kMicMode);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

} // namespace tt

extern "C" __attribute__((visibility("default"))) void* TalkTalkAudio_Create(
    CFAllocatorRef allocator,
    CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = tt::CreateDriver();
    return driver->GetReference();
}
