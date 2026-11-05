// TalkTalk Test Mic - hidden, input-only, reads Feed channel 2 (ARCHITECTURE.md §8.2, §8.4).
//
// Only the self-test reads it. Because it reads ring[1] and TalkTalk Mic reads ring[0], a sweep
// on channel 2 can never reach the meeting, even when the self-test runs mid-call.

#include "MicDevice.hpp"

namespace tt {

std::shared_ptr<LoopInputDevice> MakeTestMicDevice(std::shared_ptr<const aspl::Context> context)
{
    aspl::DeviceParameters params;
    params.Name = kTestMicName;
    params.DeviceUID = kTestMicUID;
    params.CanBeDefault = false;

    auto device =
        MakeLoopInputDevice(std::move(context), params, LoopInputDevice::Role::TestMic);
    device->SetIsHidden(true);
    return device;
}

} // namespace tt
