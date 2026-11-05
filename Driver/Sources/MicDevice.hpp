#pragma once

#include "Shared.hpp"

#include <aspl/Device.hpp>
#include <aspl/IORequestHandler.hpp>

namespace tt {

// An input-only device that reads one Feed channel from the loopback ring, sample time
// T - kMicLagFrames (§8.3). Used for TalkTalk Mic (channel 1) and TalkTalk Test Mic
// (channel 2). The two never share a ring: there is no path from channel 2 to the Mic.
class LoopInputDevice : public aspl::Device
{
public:
    enum class Role
    {
        Mic,     // ring[0], visibility-managed, can be default input
        TestMic, // ring[1], hidden, never default
    };

    LoopInputDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params,
        Role role);

    Role GetRole() const
    {
        return role_;
    }

    OSStatus AddClient(AudioObjectID objectID,
        const AudioServerPlugInClientInfo* rawClientInfo) override;

    OSStatus RemoveClient(AudioObjectID objectID,
        const AudioServerPlugInClientInfo* rawClientInfo) override;

protected:
    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override;
    OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override;
    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override;

private:
    const char* Tag() const
    {
        return role_ == Role::Mic ? "mic" : "testmic";
    }

    const Role role_;
};

class LoopInputIOHandler : public aspl::IORequestHandler
{
public:
    explicit LoopInputIOHandler(LoopInputDevice::Role role)
        : role_(role)
    {
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override;

    void OnProcessClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override;

private:
    const LoopInputDevice::Role role_;
};

std::shared_ptr<LoopInputDevice> MakeMicDevice(std::shared_ptr<const aspl::Context> context);
std::shared_ptr<LoopInputDevice> MakeTestMicDevice(std::shared_ptr<const aspl::Context> context);

// Shared by MakeMicDevice / MakeTestMicDevice.
std::shared_ptr<LoopInputDevice> MakeLoopInputDevice(std::shared_ptr<const aspl::Context> context,
    aspl::DeviceParameters params,
    LoopInputDevice::Role role);

} // namespace tt
