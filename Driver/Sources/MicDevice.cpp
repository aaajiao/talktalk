// TalkTalk Mic - input-only, 1 channel, reads Feed channel 1 (ARCHITECTURE.md §8.2, §8.3).
//
// Reading is never restricted (any meeting app may read it). What comes out:
//   - the Feed's channel 1, 480 frames (10 ms) late, when talktalk is writing;
//   - exact digital zeros otherwise (tag mismatch in the loopback ring).
// Visibility in the device list is handled by MicVisibility.

#include "MicDevice.hpp"

#include <cmath>

namespace tt {

LoopInputDevice::LoopInputDevice(std::shared_ptr<const aspl::Context> context,
    const aspl::DeviceParameters& params,
    Role role)
    : aspl::Device(std::move(context), params)
    , role_(role)
{
}

OSStatus LoopInputDevice::AddClient(AudioObjectID objectID,
    const AudioServerPlugInClientInfo* rawClientInfo)
{
    auto& shared = GetShared();
    const OSStatus status = aspl::Device::AddClient(objectID, rawClientInfo);
    if (status != kAudioHardwareNoError || !rawClientInfo) {
        return status;
    }

    ClientRecord rec;
    rec.device = Tag();
    rec.clientID = rawClientInfo->mClientID;
    rec.pid = rawClientInfo->mProcessID;
    if (auto client = GetClientByID(rawClientInfo->mClientID)) {
        rec.bundleID = client->GetBundleID().empty() ? "(null)" : client->GetBundleID();
    }
    rec.addedNanos = NowNanos();
    shared.diag.AddClient(rec);

    os_log(Log(),
        "%{public}s AddClient client=%u pid=%d bundle=%{public}s",
        Tag(),
        unsigned(rec.clientID),
        int(rec.pid),
        rec.bundleID.c_str());

    if (role_ == Role::Mic) {
        shared.visibility.MicClientAdded();
    }
    return status;
}

OSStatus LoopInputDevice::RemoveClient(AudioObjectID objectID,
    const AudioServerPlugInClientInfo* rawClientInfo)
{
    auto& shared = GetShared();
    const OSStatus status = aspl::Device::RemoveClient(objectID, rawClientInfo);
    if (rawClientInfo) {
        shared.diag.RemoveClient(Tag(), rawClientInfo->mClientID);
        os_log(Log(), "%{public}s RemoveClient client=%u", Tag(), unsigned(rawClientInfo->mClientID));
    }
    if (status == kAudioHardwareNoError && role_ == Role::Mic) {
        shared.visibility.MicClientRemoved();
    }
    return status;
}

OSStatus LoopInputDevice::StartIOImpl(UInt32 clientID, UInt32 startCount)
{
    const OSStatus status = aspl::Device::StartIOImpl(clientID, startCount);
    if (status == kAudioHardwareNoError) {
        auto& shared = GetShared();
        shared.diag.SetClientIO(Tag(), clientID, true);
        if (role_ == Role::Mic) {
            shared.visibility.MicIOStarted();
        }
    }
    return status;
}

OSStatus LoopInputDevice::StopIOImpl(UInt32 clientID, UInt32 startCount)
{
    const OSStatus status = aspl::Device::StopIOImpl(clientID, startCount);
    auto& shared = GetShared();
    shared.diag.SetClientIO(Tag(), clientID, false);
    if (role_ == Role::Mic) {
        shared.visibility.MicIOStopped();
    }
    return status;
}

OSStatus LoopInputDevice::GetZeroTimeStampImpl(UInt32 clientID,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed)
{
    GetShared().clock.GetZeroTimeStamp(outSampleTime, outHostTime);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

//--------------------------------------------------------------------------------------------

void LoopInputIOHandler::OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
    const std::shared_ptr<aspl::Stream>& stream,
    Float64 zeroTimestamp,
    Float64 timestamp,
    void* bytes,
    UInt32 bytesCount)
{
    auto& shared = GetShared();
    const UInt32 frames = bytesCount / UInt32(sizeof(Float32) * kMicChannels);
    const int64_t t = int64_t(std::llround(timestamp)) - int64_t(kMicLagFrames);

    if (role_ == LoopInputDevice::Role::Mic) {
        const uint32_t hits = shared.ring[0].Read(t, static_cast<float*>(bytes), frames);
        shared.diag.micReadCycles.fetch_add(1, std::memory_order_relaxed);
        shared.diag.micReadHitFrames.fetch_add(hits, std::memory_order_relaxed);
    } else {
        const uint32_t hits = shared.ring[1].Read(t, static_cast<float*>(bytes), frames);
        shared.diag.testMicReadCycles.fetch_add(1, std::memory_order_relaxed);
        shared.diag.testMicReadHitFrames.fetch_add(hits, std::memory_order_relaxed);
    }
}

void LoopInputIOHandler::OnProcessClientInput(const std::shared_ptr<aspl::Client>& client,
    const std::shared_ptr<aspl::Stream>& stream,
    Float64 zeroTimestamp,
    Float64 timestamp,
    Float32* frames,
    UInt32 frameCount,
    UInt32 channelCount)
{
    // No volume / mute controls (§8.2): the loopback is bit-exact.
}

//--------------------------------------------------------------------------------------------

std::shared_ptr<LoopInputDevice> MakeLoopInputDevice(std::shared_ptr<const aspl::Context> context,
    aspl::DeviceParameters params,
    LoopInputDevice::Role role)
{
    params.Manufacturer = kManufacturer;
    params.ModelUID = kModelUID;
    params.FirmwareVersion = kDriverVersion;
    params.SampleRate = kSampleRate;
    params.ChannelCount = kMicChannels;
    params.ZeroTimeStampPeriod = kZeroTimeStampPeriod;
    params.ClockDomain = kClockDomain;
    params.ClockIsStable = true;
    params.CanBeDefaultForSystemSounds = false;

    auto device = std::make_shared<LoopInputDevice>(context, params, role);

    aspl::StreamParameters stream;
    stream.Direction = aspl::Direction::Input;
    stream.StartingChannel = 1;
    stream.Format = {
        .mSampleRate = Float64(kSampleRate),
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked,
        .mBytesPerPacket = UInt32(sizeof(Float32) * kMicChannels),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = UInt32(sizeof(Float32) * kMicChannels),
        .mChannelsPerFrame = kMicChannels,
        .mBitsPerChannel = 32,
    };
    device->AddStreamAsync(stream); // no volume / mute controls (§8.2)

    device->SetIOHandler(std::make_shared<LoopInputIOHandler>(role));
    return device;
}

std::shared_ptr<LoopInputDevice> MakeMicDevice(std::shared_ptr<const aspl::Context> context)
{
    aspl::DeviceParameters params;
    params.Name = kMicName;
    params.DeviceUID = kMicUID;
    // §8.2 / §8.6: the Mic must be selectable as the system default input during meeting
    // mode, but only then: it starts at CanBeDefaultDevice = 0 and talktalk's 'ttmm' = 1 write
    // turns it on (MicVisibility::SetMeetingMode). M0-T8 d3: with a fixed 1, macOS picked the
    // Mic again by itself whenever it re-entered the list.
    params.CanBeDefault = false;

    auto device = MakeLoopInputDevice(std::move(context), params, LoopInputDevice::Role::Mic);
    if (kMicMode == 1) {
        device->SetIsHidden(true); // starts hidden; MicVisibility un-hides it
    }
    return device;
}

} // namespace tt
