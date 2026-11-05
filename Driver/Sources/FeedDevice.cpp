// TalkTalk Feed - hidden, output-only, 2 channels (ARCHITECTURE.md §8.2, §8.3).
//
//   channel 1 -> ring[0] -> TalkTalk Mic      (meeting)
//   channel 2 -> ring[1] -> TalkTalk Test Mic (self-test)
//
// Mixing is done by the driver (EnableMixing = false), so every client's output arrives
// separately and the gate can drop anything that is not talktalk even if the HAL ever let it
// through. Only clients that passed AddClient are registered at all.

#include "FeedDevice.hpp"

#include <cmath>

namespace tt {

FeedDevice::FeedDevice(std::shared_ptr<const aspl::Context> context,
    const aspl::DeviceParameters& params)
    : aspl::Device(std::move(context), params)
{
}

OSStatus FeedDevice::AddClient(AudioObjectID objectID,
    const AudioServerPlugInClientInfo* rawClientInfo)
{
    auto& shared = GetShared();

    std::string bundleID;
    if (rawClientInfo && rawClientInfo->mBundleID) {
        char buf[256];
        if (CFStringGetCString(rawClientInfo->mBundleID, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            bundleID = buf;
        }
    }
    const UInt32 clientID = rawClientInfo ? rawClientInfo->mClientID : 0;
    const pid_t pid = rawClientInfo ? rawClientInfo->mProcessID : 0;
    const bool allowed = IsAllowedFeedClient(bundleID);

    ClientRecord rec;
    rec.device = "feed";
    rec.clientID = clientID;
    rec.pid = pid;
    rec.bundleID = bundleID.empty() ? "(null)" : bundleID;
    rec.allowed = allowed;
    rec.addedNanos = NowNanos();
    shared.diag.AddClient(rec);
    ProbeSignatureAsync("feed", clientID, pid);

    os_log(Log(),
        "feed AddClient client=%u pid=%d bundle=%{public}s allowed=%d",
        unsigned(clientID),
        int(pid),
        rec.bundleID.c_str(),
        int(allowed));

    if (!allowed) {
        shared.diag.feedAddClientDenied.fetch_add(1, std::memory_order_relaxed);
        return kAudioHardwareIllegalOperationError;
    }

    const OSStatus status = aspl::Device::AddClient(objectID, rawClientInfo);
    if (status == kAudioHardwareNoError) {
        shared.visibility.FeedClientAdded();
    }
    return status;
}

OSStatus FeedDevice::RemoveClient(AudioObjectID objectID,
    const AudioServerPlugInClientInfo* rawClientInfo)
{
    auto& shared = GetShared();
    const UInt32 clientID = rawClientInfo ? rawClientInfo->mClientID : 0;
    const bool known = bool(GetClientByID(clientID));

    shared.diag.RemoveClient("feed", clientID);
    os_log(Log(), "feed RemoveClient client=%u known=%d", unsigned(clientID), int(known));

    if (!known) {
        // A refused client; nothing was registered for it.
        return kAudioHardwareNoError;
    }

    const OSStatus status = aspl::Device::RemoveClient(objectID, rawClientInfo);
    shared.visibility.FeedClientRemoved();
    return status;
}

bool FeedDevice::IsAcceptedClientPID(pid_t pid) const
{
    if (pid <= 0) {
        return false; // 0 = the Host itself (AudioServerPlugIn.h); talktalk always has a pid
    }
    for (const auto& client : GetClients()) {
        if (client && client->GetProcessID() == pid && IsAllowedFeedClient(client->GetBundleID())) {
            return true;
        }
    }
    return false;
}

OSStatus FeedDevice::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    if (address && address->mSelector == kMeetingModeSelector && objectID == GetID()) {
        auto& shared = GetShared();
        shared.diag.ttmmLastPID.store(clientPID, std::memory_order_relaxed);
        if (!IsAcceptedClientPID(clientPID)) {
            shared.diag.ttmmDenied.fetch_add(1, std::memory_order_relaxed);
            os_log(Log(), "ttmm write refused pid=%d", int(clientPID));
            return kAudioHardwareIllegalOperationError;
        }
        if (inDataSize != sizeof(CFPropertyListRef) || !inData ||
            ParseMeetingModeValue(*static_cast<const CFPropertyListRef*>(inData)) < 0) {
            os_log(Log(), "ttmm write with a bad value pid=%d size=%u", int(clientPID), unsigned(inDataSize));
            return kAudioHardwareIllegalOperationError;
        }
        shared.diag.ttmmWrites.fetch_add(1, std::memory_order_relaxed);
        // Falls through to the custom property's setter (Plugin.cpp).
    }
    return aspl::Device::SetPropertyData(
        objectID, clientPID, address, qualifierDataSize, qualifierData, inDataSize, inData);
}

OSStatus FeedDevice::StartIOImpl(UInt32 clientID, UInt32 startCount)
{
    auto& shared = GetShared();
    auto client = GetClientByID(clientID);

    if (!client || !IsAllowedFeedClient(client->GetBundleID())) {
        shared.diag.feedStartIODenied.fetch_add(1, std::memory_order_relaxed);
        os_log(Log(), "feed StartIO refused client=%u", unsigned(clientID));
        return kAudioHardwareIllegalOperationError;
    }

    const OSStatus status = aspl::Device::StartIOImpl(clientID, startCount);
    if (status == kAudioHardwareNoError) {
        shared.diag.SetClientIO("feed", clientID, true);
    }
    return status;
}

OSStatus FeedDevice::StopIOImpl(UInt32 clientID, UInt32 startCount)
{
    GetShared().diag.SetClientIO("feed", clientID, false);
    return aspl::Device::StopIOImpl(clientID, startCount);
}

OSStatus FeedDevice::GetZeroTimeStampImpl(UInt32 clientID,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed)
{
    GetShared().clock.GetZeroTimeStamp(outSampleTime, outHostTime);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

//--------------------------------------------------------------------------------------------

void FeedIOHandler::OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
    const std::shared_ptr<aspl::Stream>& stream,
    Float64 zeroTimestamp,
    Float64 timestamp,
    Float32* frames,
    UInt32 frameCount,
    UInt32 channelCount)
{
    // No volume / mute controls on the Feed (§8.2): nothing to process.
}

void FeedIOHandler::OnWriteClientOutput(const std::shared_ptr<aspl::Client>& client,
    const std::shared_ptr<aspl::Stream>& stream,
    Float64 zeroTimestamp,
    Float64 timestamp,
    const Float32* frames,
    UInt32 frameCount,
    UInt32 channelCount)
{
    auto& shared = GetShared();

    // Only clients that passed the gate are ever registered; a null client means the HAL
    // did IO for someone we did not accept. Drop it.
    if (!client) {
        shared.diag.feedWriteDroppedCycles.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    const int64_t t = int64_t(std::llround(timestamp));
    const UInt32 channels = channelCount < kFeedChannels ? channelCount : kFeedChannels;
    for (UInt32 ch = 0; ch < channels; ch++) {
        shared.ring[ch].Write(t, frames, frameCount, channelCount, ch);
    }
    shared.diag.feedWriteCycles.fetch_add(1, std::memory_order_relaxed);
}

//--------------------------------------------------------------------------------------------

std::shared_ptr<FeedDevice> MakeFeedDevice(std::shared_ptr<const aspl::Context> context)
{
    aspl::DeviceParameters params;
    params.Name = kFeedName;
    params.Manufacturer = kManufacturer;
    params.DeviceUID = kFeedUID;
    params.ModelUID = kModelUID;
    params.FirmwareVersion = kDriverVersion;
    params.CanBeDefault = false;
    params.CanBeDefaultForSystemSounds = false;
    params.SampleRate = kSampleRate;
    params.ChannelCount = kFeedChannels;
    params.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
    params.ClockDomain = kClockDomain;
    params.ClockIsStable = true;
    params.EnableMixing = false; // per-client writes; the driver mixes (and can drop)

    auto device = std::make_shared<FeedDevice>(context, params);

    aspl::StreamParameters stream;
    stream.Direction = aspl::Direction::Output;
    stream.StartingChannel = 1;
    stream.Format = {
        .mSampleRate = Float64(kSampleRate),
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked,
        .mBytesPerPacket = UInt32(sizeof(Float32) * kFeedChannels),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = UInt32(sizeof(Float32) * kFeedChannels),
        .mChannelsPerFrame = kFeedChannels,
        .mBitsPerChannel = 32,
    };
    device->AddStreamAsync(stream); // no volume / mute controls (§8.2)

    device->SetIsHidden(true); // only reachable by UID (§8.2)

    auto handler = std::make_shared<FeedIOHandler>();
    device->SetIOHandler(handler);

    return device;
}

} // namespace tt
