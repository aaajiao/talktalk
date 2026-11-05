// ClientGate - who may write into TalkTalk Feed (ARCHITECTURE.md §8.3).
//
// The gate is the client's self-reported bundle id (AudioServerPlugInClientInfo.mBundleID):
// only com.aaajiao.talktalk and com.aaajiao.talktalk.dev. A bare binary reports NULL and is
// refused. This prevents mis-routing (some other app picking the Feed); it does not stop a
// local program that lies about its identifier (§2.2).
//
// M0-T8 experiment: can the sandboxed driver host read the client's code signature from
// mProcessID? ProbeSignatureAsync records what Security.framework returns; the result is
// exposed through the Feed's 'ttdg' diagnostics property and does not affect the gate yet.

#include "Shared.hpp"

#include <Security/Security.h>

#include <cstdio>

namespace tt {

bool IsAllowedFeedClient(const std::string& bundleID)
{
    return bundleID == "com.aaajiao.talktalk" || bundleID == "com.aaajiao.talktalk.dev";
}

CFPropertyListRef CopyMeetingModeValue(bool on)
{
    int v = on ? 1 : 0;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
}

int ParseMeetingModeValue(CFPropertyListRef value)
{
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return -1;
    }
    SInt64 v = -1;
    if (!CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt64Type, &v)) {
        return -1;
    }
    return (v == 0 || v == 1) ? int(v) : -1;
}

namespace {

std::string ToStdString(CFTypeRef value)
{
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return {};
    }
    auto str = static_cast<CFStringRef>(value);
    char buf[512];
    if (CFStringGetCString(str, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        return buf;
    }
    return {};
}

std::string ToHex(CFTypeRef value)
{
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) {
        return {};
    }
    auto data = static_cast<CFDataRef>(value);
    const UInt8* bytes = CFDataGetBytePtr(data);
    const CFIndex len = CFDataGetLength(data);
    std::string out;
    out.reserve(size_t(len) * 2);
    char tmp[3];
    for (CFIndex i = 0; i < len; i++) {
        std::snprintf(tmp, sizeof(tmp), "%02x", bytes[i]);
        out += tmp;
    }
    return out;
}

SignatureProbe Probe(pid_t pid)
{
    SignatureProbe res;
    const int64_t t0 = NowNanos();

    int pidValue = pid;
    CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pidValue);
    const void* keys[] = {kSecGuestAttributePid};
    const void* values[] = {pidNum};
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFRelease(pidNum);

    SecCodeRef code = nullptr;
    res.guestStatus = SecCodeCopyGuestWithAttributes(nullptr, attrs, kSecCSDefaultFlags, &code);
    CFRelease(attrs);

    if (res.guestStatus == errSecSuccess && code) {
        CFDictionaryRef info = nullptr;
        res.infoStatus = SecCodeCopySigningInformation(
            reinterpret_cast<SecStaticCodeRef>(code), kSecCSSigningInformation, &info);
        if (res.infoStatus == errSecSuccess && info) {
            res.identifier = ToStdString(CFDictionaryGetValue(info, kSecCodeInfoIdentifier));
            res.teamID = ToStdString(CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier));
            res.cdhash = ToHex(CFDictionaryGetValue(info, kSecCodeInfoUnique));
            if (auto flags = static_cast<CFNumberRef>(
                    CFDictionaryGetValue(info, kSecCodeInfoFlags))) {
                if (CFGetTypeID(flags) == CFNumberGetTypeID()) {
                    SInt64 f = 0;
                    CFNumberGetValue(flags, kCFNumberSInt64Type, &f);
                    res.flags = uint32_t(f);
                }
            }
            CFRelease(info);
        }
        res.validityStatus = SecCodeCheckValidity(code, kSecCSDefaultFlags, nullptr);
        CFRelease(code);
    }

    res.elapsedNanos = NowNanos() - t0;
    res.done = true;
    return res;
}

struct ProbeJob
{
    std::string device;
    UInt32 clientID;
    pid_t pid;
};

void RunProbe(void* ctx)
{
    std::unique_ptr<ProbeJob> job(static_cast<ProbeJob*>(ctx));
    SignatureProbe sig = Probe(job->pid);
    GetShared().diag.SetSignature(job->device, job->clientID, sig);
    os_log(Log(),
        "sigprobe device=%{public}s client=%u pid=%d guest=%d info=%d valid=%d "
        "id=%{public}s team=%{public}s flags=0x%x",
        job->device.c_str(),
        unsigned(job->clientID),
        int(job->pid),
        int(sig.guestStatus),
        int(sig.infoStatus),
        int(sig.validityStatus),
        sig.identifier.c_str(),
        sig.teamID.c_str(),
        unsigned(sig.flags));
}

} // namespace

void ProbeSignatureAsync(const std::string& device, UInt32 clientID, pid_t pid)
{
    auto& shared = GetShared();
    if (!shared.probeQueue || pid <= 0) {
        return;
    }
    dispatch_async_f(shared.probeQueue, new ProbeJob {device, clientID, pid}, RunProbe);
}

} // namespace tt
