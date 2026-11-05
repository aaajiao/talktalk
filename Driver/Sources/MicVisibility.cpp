// MicVisibility - when TalkTalk Mic is in the device list (ARCHITECTURE.md §8.3, §8.6 layer 3).
//
// In the list while (talktalk has a client on the Feed) OR (somebody is doing IO on the Mic).
// When neither has held for kMicGraceNanos (5 s), the Mic leaves the list:
//   TT_MIC_MODE 0: Plugin::RemoveDevice  (also gone by UID; macOS must pick another default)
//   TT_MIC_MODE 1: kAudioDevicePropertyIsHidden = 1
//   TT_MIC_MODE 2: never leaves (always visible, silent without a writer)
// "Uses the Mic" is IO-based by default; TT_MIC_IN_USE_BY_CLIENT=1 switches it to
// AddDeviceClient (the M0-T9 fallback for meeting apps that stop IO while muted).
//
// Every add/remove runs on a private serial queue, never inside a HAL callback.
//
// M2 'ttmm' (meeting mode): the Mic reports CanBeDefaultDevice = 0 unless talktalk wrote
// 'ttmm' = 1 since the Mic last entered the list. The driver never sets it back to 0 on its
// own while the Mic is listed (a crash of talktalk must not make macOS move a meeting app off
// the Mic mid-call); it resets only when the Mic re-enters the list.

#include "Shared.hpp"

#ifndef TT_MIC_IN_USE_BY_CLIENT
#define TT_MIC_IN_USE_BY_CLIENT 0
#endif

namespace tt {

void MicVisibility::Init(std::shared_ptr<aspl::Plugin> plugin,
    std::shared_ptr<aspl::Device> mic,
    Diagnostics* diag)
{
    plugin_ = std::move(plugin);
    mic_ = std::move(mic);
    diag_ = diag;
    queue_ = dispatch_queue_create(
        "com.aaajiao.talktalk.audio-driver.visibility", DISPATCH_QUEUE_SERIAL);

    if (kMicMode == 2) {
        plugin_->AddDevice(mic_);
        inList_ = true;
        diag_->Event("mic.always_visible");
    } else {
        // Mode 0: not added yet. Mode 1: added but hidden (MakeMicDevice set IsHidden).
        if (kMicMode == 1) {
            plugin_->AddDevice(mic_);
        }
        inList_ = false;
        diag_->Event(kMicMode == 0 ? "mic.init_removed" : "mic.init_hidden");
    }
}

void MicVisibility::FeedClientAdded()
{
    feedClients_.fetch_add(1);
    Poke();
}

void MicVisibility::FeedClientRemoved()
{
    feedClients_.fetch_sub(1);
    Poke();
}

void MicVisibility::MicIOStarted()
{
    micIO_.fetch_add(1);
    Poke();
}

void MicVisibility::MicIOStopped()
{
    micIO_.fetch_sub(1);
    Poke();
}

void MicVisibility::MicClientAdded()
{
    micClients_.fetch_add(1);
    Poke();
}

void MicVisibility::MicClientRemoved()
{
    micClients_.fetch_sub(1);
    Poke();
}

bool MicVisibility::Wanted() const
{
    const bool micInUse = TT_MIC_IN_USE_BY_CLIENT ? (micClients_.load() > 0) : (micIO_.load() > 0);
    return feedClients_.load() > 0 || micInUse;
}

void MicVisibility::Poke()
{
    if (queue_) {
        dispatch_async_f(queue_, this, EvaluateTrampoline);
    }
}

void MicVisibility::EvaluateTrampoline(void* ctx)
{
    static_cast<MicVisibility*>(ctx)->Evaluate();
}

void MicVisibility::GraceTrampoline(void* ctx)
{
    std::unique_ptr<GraceTicket> ticket(static_cast<GraceTicket*>(ctx));
    ticket->self->GraceExpired(ticket->generation);
}

void MicVisibility::Evaluate()
{
    if (kMicMode == 2) {
        return;
    }

    if (Wanted()) {
        if (pending_) {
            generation_++; // cancels the scheduled removal
            pending_ = false;
            diag_->Event("mic.grace_cancelled");
        }
        if (!inList_) {
            Show();
        }
        return;
    }

    if (inList_ && !pending_) {
        pending_ = true;
        generation_++;
        diag_->Event("mic.grace_started");
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, kMicGraceNanos),
            queue_,
            new GraceTicket {this, generation_},
            GraceTrampoline);
    }
}

void MicVisibility::GraceExpired(uint64_t gen)
{
    if (gen != generation_ || !pending_) {
        return; // superseded
    }
    pending_ = false;
    if (!Wanted() && inList_) {
        Hide();
    }
}

void MicVisibility::SetMeetingMode(bool on)
{
    std::lock_guard lock(modeMutex_);
    meetingMode_ = on;
    if (mic_) {
        mic_->SetCanBeDefaultDevice(on); // notifies kAudioDevicePropertyDeviceCanBeDefaultDevice
    }
    if (diag_) {
        diag_->Event(on ? "ttmm.1" : "ttmm.0");
    }
    os_log(Log(), "ttmm %d", int(on));
}

void MicVisibility::Show()
{
    // §8.3 (M2): the Mic always (re)enters the list with CanBeDefaultDevice = 0, so the HAL
    // cannot make it the default input by itself (M0-T8 d3: it did when the value was 1).
    // Only a 'ttmm' = 1 write from talktalk makes it selectable again.
    {
        std::lock_guard lock(modeMutex_);
        if (meetingMode_.load() || mic_->GetCanBeDefaultDevice()) {
            diag_->Event("ttmm.reset_on_show");
        }
        meetingMode_ = false;
        mic_->SetCanBeDefaultDevice(false);
    }
    if (kMicMode == 0) {
        plugin_->AddDevice(mic_);
    } else {
        mic_->SetIsHidden(false);
    }
    inList_ = true;
    lastChangeNanos_ = NowNanos();
    diag_->micShows.fetch_add(1, std::memory_order_relaxed);
    diag_->Event(kMicMode == 0 ? "mic.added" : "mic.unhidden");
    os_log(Log(), "mic %{public}s", kMicMode == 0 ? "added" : "unhidden");
}

void MicVisibility::Hide()
{
    if (kMicMode == 0) {
        plugin_->RemoveDevice(mic_);
    } else {
        mic_->SetIsHidden(true);
    }
    inList_ = false;
    lastChangeNanos_ = NowNanos();
    diag_->micHides.fetch_add(1, std::memory_order_relaxed);
    diag_->Event(kMicMode == 0 ? "mic.removed" : "mic.hidden");
    os_log(Log(), "mic %{public}s", kMicMode == 0 ? "removed" : "hidden");
}

std::map<std::string, int64_t> MicVisibility::Snapshot() const
{
    return {
        {"micMode", kMicMode},
        {"micInUseByClient", TT_MIC_IN_USE_BY_CLIENT},
        {"micInList", inList_.load() ? 1 : 0},
        {"micGracePending", pending_.load() ? 1 : 0},
        {"micLastChangeNanos", lastChangeNanos_.load()},
        {"feedClients", feedClients_.load()},
        {"micIO", micIO_.load()},
        {"micClients", micClients_.load()},
        {"meetingMode", meetingMode_.load() ? 1 : 0},
        {"micCanBeDefault", (mic_ && mic_->GetCanBeDefaultDevice()) ? 1 : 0},
    };
}

} // namespace tt
