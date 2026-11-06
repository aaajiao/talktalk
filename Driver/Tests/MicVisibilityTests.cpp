// Metadata-only regression using the real Mic factory, visibility manager and libASPL.
// No driver is loaded or installed; any attempt to enter a device IO path aborts the test.
#include "MicDevice.hpp"

#include <aspl/Context.hpp>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace tt {
os_log_t Log() { return OS_LOG_DISABLED; }
int64_t NowNanos() { return int64_t(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); }
void Diagnostics::Event(const std::string&) {}
Shared& GetShared() { std::abort(); }
void SharedClock::GetZeroTimeStamp(Float64*, UInt64*) const { std::abort(); }
void Diagnostics::AddClient(const ClientRecord&) { std::abort(); }
void Diagnostics::RemoveClient(const std::string&, UInt32) { std::abort(); }
void Diagnostics::SetClientIO(const std::string&, UInt32, bool) { std::abort(); }
} // namespace tt

namespace {

struct InputObserver {
    std::shared_ptr<aspl::Device> device;
    std::shared_ptr<aspl::Plugin> plugin;
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<std::vector<AudioObjectID>> deviceLists;
    std::vector<std::vector<AudioObjectID>> selectableLists;
    int capabilityNotifications = 0;
    bool validReads = true;
};

InputObserver* observer = nullptr;

bool ReadInputSelectable(const std::shared_ptr<aspl::Device>& device, bool& valid)
{
    const AudioObjectPropertyAddress input {
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 value = 0, returned = 0;
    const AudioObjectID id = device->GetID();
    const bool exists = device->HasProperty(id, 0, &input);
    const OSStatus status = device->GetPropertyData(
        id, 0, &input, 0, nullptr, sizeof(value), &returned, &value);
    valid = valid && exists && status == kAudioHardwareNoError && returned == sizeof(value);
    return status == kAudioHardwareNoError && value != 0;
}

OSStatus PropertiesChanged(AudioServerPlugInHostRef, AudioObjectID object,
    UInt32 count, const AudioObjectPropertyAddress* addresses)
{
    if (!observer) {
        return kAudioHardwareNoError;
    }
    std::lock_guard lock(observer->mutex);
    for (UInt32 i = 0; i < count; ++i) {
        const auto& address = addresses[i];
        if (object == observer->device->GetID() &&
            address.mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice) {
            ++observer->capabilityNotifications;
        }
        if (object == observer->plugin->GetID() &&
            address.mSelector == kAudioPlugInPropertyDeviceList &&
            address.mScope == kAudioObjectPropertyScopeGlobal) {
            // Read capability synchronously at the first announcement, as an input picker
            // can do. Later ttmm changes must not be needed to make this list selectable.
            const auto devices = observer->plugin->GetDeviceIDs();
            std::vector<AudioObjectID> selectable;
            for (const auto id : devices) {
                const auto device = observer->plugin->GetDeviceByID(id);
                if (ReadInputSelectable(device, observer->validReads)) {
                    selectable.push_back(id);
                }
            }
            observer->deviceLists.push_back(devices);
            observer->selectableLists.push_back(selectable);
        }
    }
    observer->changed.notify_all();
    return kAudioHardwareNoError;
}

void Require(bool value, const char* message)
{
    if (!value) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

} // namespace

int main()
{
    auto context = std::make_shared<aspl::Context>(
        std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin = std::make_shared<aspl::Plugin>(context);
    auto mic = tt::MakeMicDevice(context);
    bool valid = true;
    Require(ReadInputSelectable(mic, valid) && valid,
        "the production Mic factory must create a selectable input before publication");

    InputObserver observed;
    observed.device = mic;
    observed.plugin = plugin;
    observer = &observed;
    AudioServerPlugInHostInterface host {};
    host.PropertiesChanged = PropertiesChanged;
    context->Host = &host;
    tt::Diagnostics diagnostics;
    tt::MicVisibility visibility;
    visibility.Init(plugin, mic, &diagnostics);
    Require(plugin->GetDeviceIDs().empty(), "the Mic must remain absent without a Feed client");

    visibility.FeedClientAdded();
    {
        std::unique_lock lock(observed.mutex);
        Require(observed.changed.wait_for(lock, std::chrono::seconds(2), [&] {
            return observed.deviceLists.size() == 1;
        }), "Feed registration must announce the Mic");
        const auto id = mic->GetID();
        Require(observed.deviceLists == std::vector<std::vector<AudioObjectID>> {{id}},
            "the first announcement must include the Mic");
        Require(observed.selectableLists == observed.deviceLists,
            "the Mic must already be selectable during the first announcement");
    }

    visibility.SetMeetingMode(true);
    Require(visibility.MeetingMode(), "ttmm must record an active session");
    visibility.SetMeetingMode(true);
    visibility.SetMeetingMode(false);
    Require(!visibility.MeetingMode(), "ttmm must record session end");
    Require(mic->GetCanBeDefaultDevice() && plugin->HasDevice(mic),
        "ending a session must leave the same Mic present and selectable");
    {
        std::lock_guard lock(observed.mutex);
        Require(observed.validReads, "every announced input must support the input capability read");
        Require(observed.capabilityNotifications == 0,
            "stable input capability must not emit dynamic capability notifications");
        Require(observed.deviceLists.size() == 1,
            "ttmm enable, repeat and disable must not churn or republish the device list");
    }

    const auto releasedAt = std::chrono::steady_clock::now();
    visibility.FeedClientRemoved();
    {
        std::unique_lock lock(observed.mutex);
        Require(observed.changed.wait_for(lock, std::chrono::seconds(8), [&] {
            return observed.deviceLists.size() >= 2;
        }), "normal Feed release without Mic readers must eventually remove the Mic");
        Require(observed.deviceLists.size() == 2 && observed.deviceLists.back().empty() &&
                observed.selectableLists.back().empty(),
            "normal release must announce a device list without the Mic");
        Require(std::chrono::steady_clock::now() - releasedAt >=
                std::chrono::nanoseconds(tt::kMicGraceNanos),
            "normal release must preserve the production five-second grace period");
    }
    Require(!plugin->HasDevice(mic) && mic->GetCanBeDefaultDevice(),
        "removal must change presence, not the Mic's input capability");

    // The production manager owns a process-lifetime asynchronous queue. Keep the fixture
    // alive until exit rather than racing teardown against the final visibility callback.
    std::cout << "PASS: Mic is selectable on first publication; ttmm preserves capability and identity; "
                 "normal Feed release removes it after the grace period\n";
    std::exit(0);
}
