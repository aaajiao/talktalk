#pragma once

#include "Shared.hpp"

#include <aspl/Device.hpp>
#include <aspl/IORequestHandler.hpp>

namespace tt {

class FeedDevice : public aspl::Device
{
public:
    FeedDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params);

    OSStatus AddClient(AudioObjectID objectID,
        const AudioServerPlugInClientInfo* rawClientInfo) override;

    OSStatus RemoveClient(AudioObjectID objectID,
        const AudioServerPlugInClientInfo* rawClientInfo) override;

    // 'ttmm' gate: only a process that is an accepted Feed client (talktalk) may write it.
    OSStatus SetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        const void* inData) override;

    // True when `pid` belongs to a client that passed AddClient (refused ones are never registered).
    bool IsAcceptedClientPID(pid_t pid) const;

protected:
    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override;
    OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override;
    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override;
};

class FeedIOHandler : public aspl::IORequestHandler
{
public:
    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override;

    void OnWriteClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override;
};

std::shared_ptr<FeedDevice> MakeFeedDevice(std::shared_ptr<const aspl::Context> context);

} // namespace tt
