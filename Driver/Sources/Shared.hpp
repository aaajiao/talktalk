// Shared state of TalkTalkAudio.driver: one clock, two loopback rings, diagnostics, and the
// Mic visibility manager. Owned by Plugin.cpp for the lifetime of the driver host process.

#pragma once

#include "Config.hpp"
#include "LoopbackRing.hpp"

#include <aspl/Device.hpp>
#include <aspl/Plugin.hpp>

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <os/log.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>

namespace tt {

os_log_t Log();

// Nanoseconds on CLOCK_UPTIME_RAW (same timeline as mach_absolute_time / HostTime).
int64_t NowNanos();

//--------------------------------------------------------------------------------------------
// SharedClock: one zero-timestamp timeline for Feed, Mic and Test Mic (§8.2 "共用同一个时钟域").
//
// libASPL's default GetZeroTimeStampImpl anchors each device at its own StartIO, so the Feed's
// sample time T and the Mic's sample time T would be different instants. The loopback ring is
// keyed by sample time, so all three devices must report sample times on one timeline: we
// anchor once, when the driver is created, and every device derives its zero timestamp from
// that anchor.
class SharedClock
{
public:
    SharedClock();

    // Most recent zero timestamp (sample time is a multiple of kZeroTimeStampPeriod).
    void GetZeroTimeStamp(Float64* outSampleTime, UInt64* outHostTime) const;

    UInt64 AnchorHostTime() const
    {
        return anchor_;
    }

private:
    UInt64 anchor_ = 0;
    Float64 ticksPerFrame_ = 0;
};

//--------------------------------------------------------------------------------------------
// Result of trying to read a client's code signature from inside the driver host (M0-T8:
// "驱动里能否用 mProcessID 校验客户端签名"). Recorded only; the gate itself uses the bundle id.
struct SignatureProbe
{
    bool done = false;
    OSStatus guestStatus = 0;    // SecCodeCopyGuestWithAttributes(pid)
    OSStatus infoStatus = 0;     // SecCodeCopySigningInformation
    OSStatus validityStatus = 0; // SecCodeCheckValidity
    std::string identifier;
    std::string teamID;
    std::string cdhash;
    uint32_t flags = 0;
    int64_t elapsedNanos = 0;
};

struct ClientRecord
{
    std::string device; // "feed" | "mic" | "testmic"
    UInt32 clientID = 0;
    pid_t pid = 0;
    std::string bundleID;
    bool allowed = true;
    bool ioRunning = false;
    int64_t addedNanos = 0;
    int64_t removedNanos = 0;
    SignatureProbe sig;
};

class Diagnostics
{
public:
    // Counters (relaxed atomics; some are bumped on IO threads).
    std::atomic<uint64_t> feedAddClientDenied {0};
    std::atomic<uint64_t> feedStartIODenied {0};
    std::atomic<uint64_t> feedWriteCycles {0};
    std::atomic<uint64_t> feedWriteDroppedCycles {0};
    std::atomic<uint64_t> micReadCycles {0};
    std::atomic<uint64_t> micReadHitFrames {0};
    std::atomic<uint64_t> testMicReadCycles {0};
    std::atomic<uint64_t> testMicReadHitFrames {0};
    std::atomic<uint64_t> micShows {0};
    std::atomic<uint64_t> micHides {0};
    std::atomic<uint64_t> ttmmWrites {0};  // accepted 'ttmm' writes
    std::atomic<uint64_t> ttmmDenied {0};  // refused 'ttmm' writes (caller not a Feed client)
    std::atomic<int64_t> ttmmLastPID {-1}; // clientPID the HAL passed on the last 'ttmm' write

    void AddClient(const ClientRecord& rec);
    void RemoveClient(const std::string& device, UInt32 clientID);
    void SetClientIO(const std::string& device, UInt32 clientID, bool running);
    void SetSignature(const std::string& device, UInt32 clientID, const SignatureProbe& sig);
    void Event(const std::string& what);

    // Snapshot for the custom 'ttdg' property; caller owns the result.
    CFPropertyListRef CopyDictionary(const std::map<std::string, int64_t>& extra) const;

private:
    mutable std::mutex mutex_;
    std::map<std::string, ClientRecord> clients_; // key = device + "/" + clientID
    std::deque<ClientRecord> departed_;           // last few removed clients
    std::deque<std::pair<int64_t, std::string>> events_;
};

//--------------------------------------------------------------------------------------------
// MicVisibility (§8.3): TalkTalk Mic is in the device list while talktalk has a client on the
// Feed or somebody is doing IO on the Mic; after 5 s with neither it leaves the list
// (RemoveDevice, or IsHidden in mode 1). All list changes happen on a private serial queue,
// never synchronously inside a HAL callback.
class MicVisibility
{
public:
    void Init(std::shared_ptr<aspl::Plugin> plugin,
        std::shared_ptr<aspl::Device> mic,
        Diagnostics* diag);

    void FeedClientAdded();
    void FeedClientRemoved();
    void MicIOStarted();
    void MicIOStopped();
    void MicClientAdded();
    void MicClientRemoved();

    // 'ttmm' (§8.3, M2): sets the Mic's CanBeDefaultDevice and notifies the HAL, synchronously
    // (called from SetPropertyData, like the SDK's NullAudio sample does for its controls).
    // Show() resets it to 0 before the Mic enters the list again.
    void SetMeetingMode(bool on);
    bool MeetingMode() const
    {
        return meetingMode_.load();
    }

    // For diagnostics (approximate; read from any thread).
    std::map<std::string, int64_t> Snapshot() const;

private:
    struct GraceTicket
    {
        MicVisibility* self;
        uint64_t generation;
    };

    static void EvaluateTrampoline(void* ctx);
    static void GraceTrampoline(void* ctx);

    void Poke();
    void Evaluate();                   // queue only
    void GraceExpired(uint64_t gen);   // queue only
    bool Wanted() const;
    void Show();                       // queue only
    void Hide();                       // queue only

    std::shared_ptr<aspl::Plugin> plugin_;
    std::shared_ptr<aspl::Device> mic_;
    Diagnostics* diag_ = nullptr;
    dispatch_queue_t queue_ = nullptr;

    std::atomic<int> feedClients_ {0};
    std::atomic<int> micIO_ {0};
    std::atomic<int> micClients_ {0};

    // Written on the queue only; read by Snapshot() racily (diagnostic).
    std::atomic<bool> inList_ {false};
    std::atomic<bool> pending_ {false};
    std::atomic<int64_t> lastChangeNanos_ {0};
    uint64_t generation_ = 0;

    // Meeting mode: written by SetMeetingMode (HAL thread) and Show() (queue) under modeMutex_.
    mutable std::mutex modeMutex_;
    std::atomic<bool> meetingMode_ {false};
};

//--------------------------------------------------------------------------------------------
struct Shared
{
    SharedClock clock;
    LoopbackRing ring[kFeedChannels]; // [0] = meeting -> Mic, [1] = self-test -> Test Mic
    Diagnostics diag;
    MicVisibility visibility;
    dispatch_queue_t probeQueue = nullptr; // code-signature probes (off the HAL threads)
};

Shared& GetShared();

//--------------------------------------------------------------------------------------------
// ClientGate (§8.3): only talktalk may start IO on the Feed.
bool IsAllowedFeedClient(const std::string& bundleID);

// Builds the 'ttmm' value (CFNumber, caller owns it) / parses a written one (0 or 1, else -1).
CFPropertyListRef CopyMeetingModeValue(bool on);
int ParseMeetingModeValue(CFPropertyListRef value);

// Asynchronously probe the client's code signature and store it in diagnostics.
void ProbeSignatureAsync(const std::string& device, UInt32 clientID, pid_t pid);

} // namespace tt
