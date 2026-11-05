#include "tt_ioproc_tap.h"

#include <stdlib.h>
#include <string.h>

struct tt_tap_ctx {
    tt_ring *left;
    tt_ring *right;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames;
    _Atomic uint64_t last_nonzero;
    _Atomic uint64_t dropped_stamps;
    _Atomic uint64_t stamp_write;   /* producer index */
    _Atomic uint64_t stamp_read;    /* consumer index */
    tt_tap_stamp stamps[TT_TAP_STAMPS];
};

tt_tap_ctx *_Nullable tt_tap_ctx_create(tt_ring *left, tt_ring *right) {
    tt_tap_ctx *ctx = calloc(1, sizeof(tt_tap_ctx));
    if (ctx == NULL) return NULL;
    ctx->left = left;
    ctx->right = right;
    atomic_init(&ctx->callbacks, 0);
    atomic_init(&ctx->frames, 0);
    atomic_init(&ctx->last_nonzero, 0);
    atomic_init(&ctx->dropped_stamps, 0);
    atomic_init(&ctx->stamp_write, 0);
    atomic_init(&ctx->stamp_read, 0);
    return ctx;
}

void tt_tap_ctx_destroy(tt_tap_ctx *_Nullable ctx) { free(ctx); }

#define TT_LOAD(field) atomic_load_explicit(&((tt_tap_ctx *)ctx)->field, memory_order_relaxed)
uint64_t tt_tap_callbacks(const tt_tap_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(callbacks); }
uint64_t tt_tap_frames(const tt_tap_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(frames); }
uint64_t tt_tap_last_nonzero_host_time(const tt_tap_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(last_nonzero); }
uint64_t tt_tap_dropped_stamps(const tt_tap_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(dropped_stamps); }
#undef TT_LOAD

static void push_stamp(tt_tap_ctx *ctx, uint64_t host, uint32_t frames, uint32_t nonzero) TT_NONBLOCKING {
    uint64_t w = atomic_load_explicit(&ctx->stamp_write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ctx->stamp_read, memory_order_acquire);
    if (w - r >= TT_TAP_STAMPS) {
        atomic_fetch_add_explicit(&ctx->dropped_stamps, 1, memory_order_relaxed);
        return;
    }
    tt_tap_stamp *s = &ctx->stamps[w & (TT_TAP_STAMPS - 1)];
    s->host_time = host;
    s->frames = frames;
    s->nonzero = nonzero;
    atomic_store_explicit(&ctx->stamp_write, w + 1, memory_order_release);
}

uint32_t tt_tap_read_stamps(tt_tap_ctx *ctx, tt_tap_stamp *dst, uint32_t max) TT_NONBLOCKING {
    uint64_t r = atomic_load_explicit(&ctx->stamp_read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ctx->stamp_write, memory_order_acquire);
    uint32_t n = 0;
    while (r < w && n < max) {
        dst[n++] = ctx->stamps[r & (TT_TAP_STAMPS - 1)];
        r++;
    }
    atomic_store_explicit(&ctx->stamp_read, r, memory_order_release);
    return n;
}

static int any_nonzero(const float *p, uint32_t count) TT_NONBLOCKING {
    for (uint32_t i = 0; i < count; i++) {
        if (p[i] != 0.0f) return 1;
    }
    return 0;
}

/* Writes channel `ch` of the input (searching interleaved and non-interleaved buffers) into
 * `ring`; zeros if absent. Returns 1 if any sample was non-zero. */
static int copy_channel(tt_ring *ring, const AudioBufferList *_Nullable input, uint32_t ch, uint32_t frames) TT_NONBLOCKING {
    uint32_t base = 0;
    if (input != NULL) {
        for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
            const AudioBuffer *buf = &input->mBuffers[b];
            uint32_t nch = buf->mNumberChannels;
            if (nch == 0) continue;
            if (ch < base + nch) {
                if (buf->mData == NULL) break;
                uint32_t avail = buf->mDataByteSize / (uint32_t)(sizeof(float) * nch);
                uint32_t n = frames < avail ? frames : avail;
                const float *src = (const float *)buf->mData + (ch - base);
                tt_ring_write_strided(ring, src, n, nch);
                if (n < frames) tt_ring_write_zeros(ring, frames - n);
                return any_nonzero((const float *)buf->mData, n * nch);
            }
            base += nch;
        }
    }
    tt_ring_write_zeros(ring, frames);
    return 0;
}

void tt_tap_process(tt_tap_ctx *ctx, const AudioBufferList *_Nullable input, uint32_t frames, uint64_t host_time) TT_NONBLOCKING {
    atomic_fetch_add_explicit(&ctx->callbacks, 1, memory_order_relaxed);
    int nz = copy_channel(ctx->left, input, 0, frames);
    if (ctx->right != ctx->left) {
        /* A mono tap has one channel: duplicate it (copy_channel finds no channel 1 and would
         * write zeros). */
        uint32_t channels = 0;
        if (input != NULL) for (uint32_t b = 0; b < input->mNumberBuffers; b++) channels += input->mBuffers[b].mNumberChannels;
        nz |= copy_channel(ctx->right, input, channels >= 2 ? 1 : 0, frames);
    }
    atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
    if (nz && host_time != 0) atomic_store_explicit(&ctx->last_nonzero, host_time, memory_order_relaxed);
    push_stamp(ctx, host_time, frames, (uint32_t)nz);
}

OSStatus tt_tap_ioproc(AudioObjectID inDevice,
                       const AudioTimeStamp * inNow,
                       const AudioBufferList * inInputData,
                       const AudioTimeStamp * inInputTime,
                       AudioBufferList * outOutputData,
                       const AudioTimeStamp * inOutputTime,
                       void *_Nullable inClientData) TT_NONBLOCKING {
    (void)inDevice; (void)inNow; (void)outOutputData; (void)inOutputTime;
    tt_tap_ctx *ctx = (tt_tap_ctx *)inClientData;
    if (ctx == NULL) return noErr;
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
    tt_tap_process(ctx, inInputData, frames, host);
    return noErr;
}
