#include "tt_ioproc_monitor.h"

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

struct tt_monitor_ctx {
    tt_ring *ring_o2;
    tt_ring *_Nullable cues;
    tt_event_ring *_Nullable events;
    uint32_t max_cycle;
    float *scratch;
    float *cue_scratch;
    _Atomic uint32_t gain_bits;   /* target gain (float bits), set from any thread */
    _Atomic uint32_t cue_gain_bits; /* target cue gain (float bits), set from any thread */
    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames;
    _Atomic uint64_t audio_frames;
    _Atomic uint64_t cue_frames;
    _Atomic uint64_t underruns;
    float gain_now;               /* IO thread: gain reached at the end of the last cycle */
    float cue_gain_now;           /* IO thread: the same for the cue gain */
    int started;                  /* IO thread: the first cycle has run */
    int have_slots;               /* set before the IOProc runs: write only slot_buf/slot_ch */
    uint32_t slot_buf[2];
    uint32_t slot_ch[2];
};

static inline uint32_t f2u(float f) TT_NONBLOCKING {
    union { float f; uint32_t u; } x = { .f = f };
    return x.u;
}

static inline float u2f(uint32_t u) TT_NONBLOCKING {
    union { float f; uint32_t u; } x = { .u = u };
    return x.f;
}

tt_monitor_ctx *_Nullable tt_monitor_ctx_create(tt_ring *ring_o2, tt_ring *_Nullable cues,
                                                tt_event_ring *_Nullable events,
                                                uint32_t max_cycle_frames) {
    tt_monitor_ctx *ctx = calloc(1, sizeof(tt_monitor_ctx));
    if (ctx == NULL) return NULL;
    ctx->max_cycle = max_cycle_frames ? max_cycle_frames : TT_MONITOR_DEFAULT_MAX_CYCLE;
    ctx->scratch = calloc(ctx->max_cycle, sizeof(float));
    ctx->cue_scratch = calloc(ctx->max_cycle, sizeof(float));
    if (ctx->scratch == NULL || ctx->cue_scratch == NULL) {
        free(ctx->scratch);
        free(ctx->cue_scratch);
        free(ctx);
        return NULL;
    }
    ctx->ring_o2 = ring_o2;
    ctx->cues = cues;
    ctx->events = events;
    ctx->gain_now = TT_MONITOR_DEFAULT_GAIN;
    atomic_init(&ctx->gain_bits, f2u(TT_MONITOR_DEFAULT_GAIN));
    ctx->cue_gain_now = 1.0f;
    atomic_init(&ctx->cue_gain_bits, f2u(1.0f));
    return ctx;
}

void tt_monitor_ctx_destroy(tt_monitor_ctx *_Nullable ctx) {
    if (ctx == NULL) return;
    free(ctx->scratch);
    free(ctx->cue_scratch);
    free(ctx);
}

void tt_monitor_set_gain(tt_monitor_ctx *ctx, float linear) TT_NONBLOCKING {
    if (!(linear > 0.0f)) linear = 0.0f;   /* also catches NaN */
    if (linear > 4.0f) linear = 4.0f;
    atomic_store_explicit(&ctx->gain_bits, f2u(linear), memory_order_relaxed);
}

float tt_monitor_gain(const tt_monitor_ctx *ctx) TT_NONBLOCKING {
    return u2f(atomic_load_explicit(&((tt_monitor_ctx *)ctx)->gain_bits, memory_order_relaxed));
}

void tt_monitor_set_gain_db(tt_monitor_ctx *ctx, float db) {
    if (!(db > -60.0f)) {
        tt_monitor_set_gain(ctx, 0.0f);
        return;
    }
    if (db > 12.0f) db = 12.0f;
    tt_monitor_set_gain(ctx, powf(10.0f, db / 20.0f));
}

void tt_monitor_set_gain_initial(tt_monitor_ctx *ctx, float linear) {
    tt_monitor_set_gain(ctx, linear);
    ctx->gain_now = tt_monitor_gain(ctx);
}

void tt_monitor_set_cue_gain(tt_monitor_ctx *ctx, float linear) TT_NONBLOCKING {
    if (!(linear > 0.0f)) linear = 0.0f;   /* also catches NaN */
    if (linear > 1.0f) linear = 1.0f;
    atomic_store_explicit(&ctx->cue_gain_bits, f2u(linear), memory_order_relaxed);
}

float tt_monitor_cue_gain(const tt_monitor_ctx *ctx) TT_NONBLOCKING {
    return u2f(atomic_load_explicit(&((tt_monitor_ctx *)ctx)->cue_gain_bits, memory_order_relaxed));
}

void tt_monitor_set_cue_gain_initial(tt_monitor_ctx *ctx, float linear) {
    tt_monitor_set_cue_gain(ctx, linear);
    ctx->cue_gain_now = tt_monitor_cue_gain(ctx);
}

void tt_monitor_set_channels(tt_monitor_ctx *ctx, uint32_t left_buffer, uint32_t left_channel,
                             uint32_t right_buffer, uint32_t right_channel) {
    ctx->slot_buf[0] = left_buffer;
    ctx->slot_ch[0] = left_channel;
    ctx->slot_buf[1] = right_buffer;
    ctx->slot_ch[1] = right_channel;
    ctx->have_slots = 1;
}

#define TT_LOAD(field) atomic_load_explicit(&((tt_monitor_ctx *)ctx)->field, memory_order_relaxed)
uint64_t tt_monitor_callbacks(const tt_monitor_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(callbacks); }
uint64_t tt_monitor_frames(const tt_monitor_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(frames); }
uint64_t tt_monitor_audio_frames(const tt_monitor_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(audio_frames); }
uint64_t tt_monitor_cue_frames(const tt_monitor_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(cue_frames); }
uint64_t tt_monitor_underruns(const tt_monitor_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(underruns); }
#undef TT_LOAD

void tt_monitor_process(tt_monitor_ctx *ctx, AudioBufferList *output, uint32_t frames,
                        uint64_t out_host_ticks) TT_NONBLOCKING {
    atomic_fetch_add_explicit(&ctx->callbacks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
    for (uint32_t b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buf = &output->mBuffers[b];
        if (buf->mData == NULL) continue;
        float *p = (float *)buf->mData;
        uint32_t n = buf->mDataByteSize / (uint32_t)sizeof(float);
        for (uint32_t i = 0; i < n; i++) p[i] = 0.0f;
    }

    if (!ctx->started) {
        /* A new context: a jump requested while no monitor ran completes now, without a fade. */
        ctx->started = 1;
        tt_ring_playout_suspend(ctx->ring_o2, NULL);
    }
    float target = tt_monitor_gain(ctx);
    float start = ctx->gain_now;
    float cue_target = tt_monitor_cue_gain(ctx);
    float cue_start = ctx->cue_gain_now;
    for (uint32_t done = 0; done < frames;) {
        uint32_t n = frames - done < ctx->max_cycle ? frames - done : ctx->max_cycle;
        tt_ring_playout_report rep;
        tt_ring_playout_read(ctx->ring_o2, ctx->scratch, n, TT_MONITOR_RESUME_FRAMES, &rep);
        atomic_fetch_add_explicit(&ctx->audio_frames, rep.audio_frames, memory_order_relaxed);
        if (rep.events & TT_RING_EV_UNDERRUN) {
            atomic_fetch_add_explicit(&ctx->underruns, 1, memory_order_relaxed);
            if (ctx->events != NULL) tt_event_push4(ctx->events, TT_EV_MON_UNDERRUN, TT_EV_SRC_MONITOR, out_host_ticks, 0, 0);
        }
        /* Gain ramps linearly from the last cycle's value to the target over this cycle. */
        for (uint32_t i = 0; i < n; i++) {
            float g = target;
            if (start != target) g = start + (target - start) * ((float)(done + i + 1) / (float)frames);
            ctx->scratch[i] *= g;
        }
        if (ctx->cues != NULL) {
            /* Read every cycle, also at gain 0 (dropped then), ramped like the ringO2 gain. */
            uint32_t c = tt_ring_read(ctx->cues, ctx->cue_scratch, n);
            for (uint32_t i = 0; i < c; i++) {
                float g = cue_target;
                if (cue_start != cue_target) g = cue_start + (cue_target - cue_start) * ((float)(done + i + 1) / (float)frames);
                ctx->scratch[i] += ctx->cue_scratch[i] * g;
            }
            atomic_fetch_add_explicit(&ctx->cue_frames, c, memory_order_relaxed);
        }
        if (ctx->have_slots) {
            /* The device's stereo pair only (the same slot twice: one channel). */
            for (uint32_t s = 0; s < 2; s++) {
                if (s == 1 && ctx->slot_buf[1] == ctx->slot_buf[0] && ctx->slot_ch[1] == ctx->slot_ch[0]) break;
                if (ctx->slot_buf[s] >= output->mNumberBuffers) continue;
                AudioBuffer *buf = &output->mBuffers[ctx->slot_buf[s]];
                uint32_t nch = buf->mNumberChannels;
                if (buf->mData == NULL || ctx->slot_ch[s] >= nch) continue;
                float *p = (float *)buf->mData;
                uint32_t avail = buf->mDataByteSize / (uint32_t)(sizeof(float) * nch);
                for (uint32_t i = 0; i < n && done + i < avail; i++) p[(size_t)(done + i) * nch + ctx->slot_ch[s]] = ctx->scratch[i];
            }
        } else {
            /* Same mono signal on every output channel. */
            for (uint32_t b = 0; b < output->mNumberBuffers; b++) {
                AudioBuffer *buf = &output->mBuffers[b];
                uint32_t nch = buf->mNumberChannels;
                if (buf->mData == NULL || nch == 0) continue;
                float *p = (float *)buf->mData;
                uint32_t avail = buf->mDataByteSize / (uint32_t)(sizeof(float) * nch);
                for (uint32_t i = 0; i < n && done + i < avail; i++) {
                    for (uint32_t ch = 0; ch < nch; ch++) p[(size_t)(done + i) * nch + ch] = ctx->scratch[i];
                }
            }
        }
        done += n;
    }
    ctx->gain_now = target;
    ctx->cue_gain_now = cue_target;
}

OSStatus tt_monitor_ioproc(AudioObjectID inDevice,
                           const AudioTimeStamp *inNow,
                           const AudioBufferList *inInputData,
                           const AudioTimeStamp *inInputTime,
                           AudioBufferList *outOutputData,
                           const AudioTimeStamp *inOutputTime,
                           void *_Nullable inClientData) TT_NONBLOCKING {
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime;
    tt_monitor_ctx *ctx = (tt_monitor_ctx *)inClientData;
    if (ctx == NULL || outOutputData == NULL) return noErr;
    uint32_t frames = 0;
    for (uint32_t b = 0; b < outOutputData->mNumberBuffers; b++) {
        const AudioBuffer *buf = &outOutputData->mBuffers[b];
        if (buf->mNumberChannels > 0 && buf->mData != NULL) {
            frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
            break;
        }
    }
    if (frames == 0) return noErr;
    uint64_t host = (inOutputTime != NULL && (inOutputTime->mFlags & kAudioTimeStampHostTimeValid)) ? inOutputTime->mHostTime : 0;
    tt_monitor_process(ctx, outOutputData, frames, host);
    return noErr;
}
