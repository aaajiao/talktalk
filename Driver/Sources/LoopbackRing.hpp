// LoopbackRing - one channel of the Feed -> Mic loopback (ARCHITECTURE.md §8.3).
//
// Every frame slot stores the sample *and* the sample time it was written for, packed into a
// single 64-bit atomic: high 32 bits = low 32 bits of the sample time, low 32 bits = Float32
// bits. A reader asking for sample time T gets the sample only if the slot's tag equals T;
// otherwise (never written, or overwritten / stale) it gets 0. So:
//   - nobody writing          -> digital silence;
//   - Feed client stopped     -> silence, never a replay of old TTS;
//   - Feed client restarted   -> only freshly written frames come out.
//
// Tag collisions: a stale slot can only alias a request after 375 x 2^32 frames (~388 days at
// 48 kHz) without being rewritten, because 2^32 mod 48000 = 23296 and gcd(23296, 48000) = 128.
//
// Real-time safe: no locks, no allocation; relaxed atomics are enough because each slot is
// self-describing (tag and value travel together in one atomic word).

#pragma once

#include "Config.hpp"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace tt {

class LoopbackRing
{
public:
    LoopbackRing()
    {
        for (auto& s : slots_) {
            s.store(Pack(kNoTag, 0.0f), std::memory_order_relaxed);
        }
    }

    LoopbackRing(const LoopbackRing&) = delete;
    LoopbackRing& operator=(const LoopbackRing&) = delete;

    // Write `frameCount` frames for sample times [sampleTime, sampleTime + frameCount).
    // `frames` is interleaved with `stride` floats per frame; channel `offset` is taken.
    // If a slot already holds this exact sample time (another client wrote it in the same IO
    // cycle), the sample is added (that is the mix); otherwise it is overwritten.
    void Write(int64_t sampleTime,
        const float* frames,
        uint32_t frameCount,
        uint32_t stride,
        uint32_t offset)
    {
        for (uint32_t n = 0; n < frameCount; n++) {
            const int64_t t = sampleTime + n;
            const uint32_t tag = Tag(t);
            const float v = frames[size_t(n) * stride + offset];
            auto& slot = slots_[Index(t)];

            uint64_t cur = slot.load(std::memory_order_relaxed);
            for (;;) {
                const float base = (TagOf(cur) == tag) ? ValueOf(cur) : 0.0f;
                const uint64_t next = Pack(tag, base + v);
                if (slot.compare_exchange_weak(
                        cur, next, std::memory_order_relaxed, std::memory_order_relaxed)) {
                    break;
                }
            }
        }
        lastWriteEnd_.store(sampleTime + frameCount, std::memory_order_relaxed);
    }

    // Read frames for sample times [sampleTime, sampleTime + frameCount) into a mono buffer.
    // Returns the number of frames that had a matching tag (the rest are zero).
    uint32_t Read(int64_t sampleTime, float* out, uint32_t frameCount) const
    {
        uint32_t hits = 0;
        for (uint32_t n = 0; n < frameCount; n++) {
            const int64_t t = sampleTime + n;
            const uint64_t cur = slots_[Index(t)].load(std::memory_order_relaxed);
            if (TagOf(cur) == Tag(t)) {
                out[n] = ValueOf(cur);
                hits++;
            } else {
                out[n] = 0.0f;
            }
        }
        return hits;
    }

    int64_t LastWriteEnd() const
    {
        return lastWriteEnd_.load(std::memory_order_relaxed);
    }

private:
    // Sample times from the shared clock are >= 0, so a tag of 0xFFFFFFFF for "never written"
    // only aliases sample time 2^32-1 (~24.8 h in), and even then the stored value is 0.
    static constexpr uint32_t kNoTag = 0xFFFFFFFFu;

    static uint32_t Index(int64_t t)
    {
        const int64_t m = t % int64_t(kRingFrames);
        return uint32_t(m < 0 ? m + kRingFrames : m);
    }

    static uint32_t Tag(int64_t t)
    {
        return uint32_t(uint64_t(t) & 0xFFFFFFFFu);
    }

    static uint64_t Pack(uint32_t tag, float v)
    {
        uint32_t bits;
        std::memcpy(&bits, &v, sizeof(bits));
        return (uint64_t(tag) << 32) | bits;
    }

    static uint32_t TagOf(uint64_t w)
    {
        return uint32_t(w >> 32);
    }

    static float ValueOf(uint64_t w)
    {
        const uint32_t bits = uint32_t(w & 0xFFFFFFFFu);
        float v;
        std::memcpy(&v, &bits, sizeof(v));
        return v;
    }

    static_assert(std::atomic<uint64_t>::is_always_lock_free, "need lock-free 64-bit atomics");

    std::atomic<uint64_t> slots_[kRingFrames];
    std::atomic<int64_t> lastWriteEnd_ {0};
};

} // namespace tt
