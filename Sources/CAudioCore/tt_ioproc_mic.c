#include "tt_ioproc_mic.h"

#include <stdlib.h>
#include <string.h>

struct tt_mic_ctx {
    tt_ring *ring;              /* set before AudioDeviceStart, not changed while running */
    uint32_t channel;           /* zero-based input channel to capture */
    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames;            /* frames delivered by the HAL (stored + dropped) */
    _Atomic uint64_t first_host_time;   /* mHostTime of the first callback's input, 0 until then */
    _Atomic uint64_t last_host_time;    /* mHostTime of the latest callback's input */
    _Atomic uint64_t missing_buffers;   /* callbacks where the channel was absent (zeros written) */
    _Atomic uint64_t dropped_frames;
    _Atomic uint64_t dropped_stamps;
    _Atomic uint64_t stamp_write;
    _Atomic uint64_t stamp_read;
    tt_mic_stamp stamps[TT_MIC_STAMPS];
};

tt_mic_ctx *_Nullable tt_mic_ctx_create(tt_ring *ring, uint32_t channel) {
    tt_mic_ctx *ctx = calloc(1, sizeof(tt_mic_ctx));
    if (ctx == NULL) return NULL;
    ctx->ring = ring;
    ctx->channel = channel;
    atomic_init(&ctx->callbacks, 0);
    atomic_init(&ctx->frames, 0);
    atomic_init(&ctx->first_host_time, 0);
    atomic_init(&ctx->last_host_time, 0);
    atomic_init(&ctx->missing_buffers, 0);
    atomic_init(&ctx->dropped_frames, 0);
    atomic_init(&ctx->dropped_stamps, 0);
    atomic_init(&ctx->stamp_write, 0);
    atomic_init(&ctx->stamp_read, 0);
    return ctx;
}

void tt_mic_ctx_destroy(tt_mic_ctx *_Nullable ctx) { free(ctx); }

#define TT_LOAD(field) atomic_load_explicit(&((tt_mic_ctx *)ctx)->field, memory_order_relaxed)
uint64_t tt_mic_callbacks(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(callbacks); }
uint64_t tt_mic_frames(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(frames); }
uint64_t tt_mic_first_host_time(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(first_host_time); }
uint64_t tt_mic_last_host_time(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(last_host_time); }
uint64_t tt_mic_missing_buffers(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(missing_buffers); }
uint64_t tt_mic_dropped_frames(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(dropped_frames); }
uint64_t tt_mic_dropped_stamps(const tt_mic_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(dropped_stamps); }
#undef TT_LOAD

uint32_t tt_mic_read_stamps(tt_mic_ctx *ctx, tt_mic_stamp *dst, uint32_t max) TT_NONBLOCKING {
    uint64_t r = atomic_load_explicit(&ctx->stamp_read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ctx->stamp_write, memory_order_acquire);
    uint32_t n = 0;
    while (r < w && n < max) { dst[n++] = ctx->stamps[r++ & (TT_MIC_STAMPS - 1)]; }
    atomic_store_explicit(&ctx->stamp_read, r, memory_order_release);
    return n;
}

static void finish_copy(tt_mic_ctx *ctx, uint64_t w, uint64_t host, uint64_t first,
                        uint32_t frames, uint32_t stored) TT_NONBLOCKING {
    atomic_fetch_add_explicit(&ctx->dropped_frames, frames - stored, memory_order_relaxed);
    if (stored == 0) return;
    ctx->stamps[w & (TT_MIC_STAMPS - 1)] = (tt_mic_stamp){host, first, stored};
    atomic_store_explicit(&ctx->stamp_write, w + 1, memory_order_release);
}

void tt_mic_process(tt_mic_ctx *ctx, const AudioBufferList *_Nullable input, uint32_t frames, uint64_t host_time) TT_NONBLOCKING {
    atomic_fetch_add_explicit(&ctx->callbacks, 1, memory_order_relaxed);
    uint64_t first = atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ctx->stamp_write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ctx->stamp_read, memory_order_acquire);
    if (host_time != 0) {
        uint64_t expected = 0;
        atomic_compare_exchange_strong_explicit(&ctx->first_host_time, &expected, host_time,
                                                memory_order_relaxed, memory_order_relaxed);
        atomic_store_explicit(&ctx->last_host_time, host_time, memory_order_relaxed);
    }
    /* Never write audio without its stamp: the consumer cannot reconstruct a dropped callback. */
    if (w - r >= TT_MIC_STAMPS) {
        atomic_fetch_add_explicit(&ctx->dropped_stamps, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&ctx->dropped_frames, frames, memory_order_relaxed);
        return;
    }

    /* Find the buffer holding `channel`: non-interleaved devices have one buffer per channel,
     * interleaved devices one buffer with mNumberChannels > 1 (or a mix of both). */
    uint32_t base = 0;
    if (input != NULL) {
        for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
            const AudioBuffer *buf = &input->mBuffers[b];
            uint32_t nch = buf->mNumberChannels;
            if (nch == 0) continue;
            if (ctx->channel < base + nch) {
                if (buf->mData == NULL) break;
                uint32_t avail = buf->mDataByteSize / (uint32_t)(sizeof(float) * nch);
                uint32_t n = frames < avail ? frames : avail;
                const float *src = (const float *)buf->mData + (ctx->channel - base);
                uint32_t stored = tt_ring_write_strided(ctx->ring, src, n, nch);
                /* If source frames overflowed, appending later zeros would create a hidden gap. */
                if (stored == n && n < frames) stored += tt_ring_write_zeros(ctx->ring, frames - n);
                finish_copy(ctx, w, host_time, first, frames, stored);
                return;
            }
            base += nch;
        }
    }
    /* Channel absent this cycle: keep the timeline continuous with zeros. */
    uint32_t stored = tt_ring_write_zeros(ctx->ring, frames);
    finish_copy(ctx, w, host_time, first, frames, stored);
    atomic_fetch_add_explicit(&ctx->missing_buffers, 1, memory_order_relaxed);
}

OSStatus tt_mic_ioproc(AudioObjectID inDevice,
                       const AudioTimeStamp * inNow,
                       const AudioBufferList * inInputData,
                       const AudioTimeStamp * inInputTime,
                       AudioBufferList * outOutputData,
                       const AudioTimeStamp * inOutputTime,
                       void *_Nullable inClientData) TT_NONBLOCKING {
    (void)inDevice; (void)inNow; (void)outOutputData; (void)inOutputTime;
    tt_mic_ctx *ctx = (tt_mic_ctx *)inClientData;
    if (ctx == NULL || ctx->ring == NULL) return noErr;

    /* Frame count from the buffer that carries our channel (all input buffers of one
     * IOProc cycle have the same frame count). */
    uint32_t frames = 0;
    for (uint32_t b = 0; b < inInputData->mNumberBuffers; b++) {
        const AudioBuffer *buf = &inInputData->mBuffers[b];
        if (buf->mNumberChannels > 0 && buf->mData != NULL) {
            frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
            break;
        }
    }
    if (frames == 0) return noErr;
    uint64_t host = (inInputTime->mFlags & kAudioTimeStampHostTimeValid) ? inInputTime->mHostTime : 0;
    tt_mic_process(ctx, inInputData, frames, host);
    return noErr;
}
