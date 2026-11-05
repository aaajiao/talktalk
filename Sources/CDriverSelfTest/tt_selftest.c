#include "tt_selftest.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct tt_st_writer {
    float *signal;            /* signal_frames samples, copied at create */
    uint32_t signal_frames;
    uint32_t channel;         /* 0-based output channel */
    uint32_t lead_frames;
    float *tone;              /* TT_ST_RATE-entry table */
    _Atomic uint32_t mode;
    _Atomic int64_t first;    /* output sample time of the first callback since reset */
    _Atomic int64_t signal_start;
    _Atomic int64_t end;
    _Atomic uint64_t cycles;
    _Atomic uint64_t discontinuities;
    int64_t last_end;         /* IO thread only (reset while stopped) */
    tt_st_range *ranges;
    uint32_t max_ranges;
    _Atomic uint32_t n_ranges;
};

static inline int64_t tt_st_round(double t) TT_ST_NONBLOCKING {
    return (int64_t)(t >= 0 ? t + 0.5 : t - 0.5);
}

tt_st_writer *_Nullable tt_st_writer_create(const float *_Nullable signal, uint32_t signal_frames,
                                            uint32_t channel, uint32_t lead_frames, uint32_t max_ranges) {
    tt_st_writer *w = calloc(1, sizeof(tt_st_writer));
    if (w == NULL) return NULL;
    w->tone = malloc(sizeof(float) * TT_ST_RATE);
    w->ranges = calloc(max_ranges ? max_ranges : 1, sizeof(tt_st_range));
    if (signal_frames > 0) w->signal = malloc(sizeof(float) * signal_frames);
    if (w->tone == NULL || w->ranges == NULL || (signal_frames > 0 && w->signal == NULL)) {
        tt_st_writer_destroy(w);
        return NULL;
    }
    if (signal_frames > 0) {
        if (signal != NULL) memcpy(w->signal, signal, sizeof(float) * signal_frames);
        else memset(w->signal, 0, sizeof(float) * signal_frames);
    }
    for (uint32_t i = 0; i < TT_ST_RATE; i++) {
        w->tone[i] = (float)(0.25 * sin(2.0 * M_PI * (double)i / (double)TT_ST_RATE));
    }
    w->signal_frames = signal_frames;
    w->channel = channel;
    w->lead_frames = lead_frames;
    w->max_ranges = max_ranges ? max_ranges : 1;
    atomic_init(&w->mode, TT_ST_MODE_SILENCE);
    atomic_init(&w->cycles, 0);
    atomic_init(&w->discontinuities, 0);
    atomic_init(&w->n_ranges, 0);
    atomic_init(&w->first, TT_ST_NO_SAMPLE);
    atomic_init(&w->signal_start, TT_ST_NO_SAMPLE);
    atomic_init(&w->end, TT_ST_NO_SAMPLE);
    w->last_end = TT_ST_NO_SAMPLE;
    return w;
}

void tt_st_writer_destroy(tt_st_writer *_Nullable w) {
    if (w == NULL) return;
    free(w->signal);
    free(w->tone);
    free(w->ranges);
    free(w);
}

void tt_st_writer_reset(tt_st_writer *w) {
    atomic_store(&w->first, TT_ST_NO_SAMPLE);
    atomic_store(&w->signal_start, TT_ST_NO_SAMPLE);
    atomic_store(&w->end, TT_ST_NO_SAMPLE);
    atomic_store(&w->n_ranges, 0);
    atomic_store(&w->cycles, 0);
    atomic_store(&w->discontinuities, 0);
    w->last_end = TT_ST_NO_SAMPLE;
}

void tt_st_writer_break_range(tt_st_writer *w) { w->last_end = TT_ST_NO_SAMPLE; }

void tt_st_writer_set_mode(tt_st_writer *w, uint32_t mode) TT_ST_NONBLOCKING {
    atomic_store_explicit(&w->mode, mode, memory_order_release);
}

int64_t tt_st_writer_first_sample(const tt_st_writer *w) TT_ST_NONBLOCKING {
    return atomic_load_explicit(&((tt_st_writer *)w)->first, memory_order_acquire);
}
int64_t tt_st_writer_signal_start(const tt_st_writer *w) TT_ST_NONBLOCKING {
    return atomic_load_explicit(&((tt_st_writer *)w)->signal_start, memory_order_acquire);
}
int64_t tt_st_writer_end_sample(const tt_st_writer *w) TT_ST_NONBLOCKING {
    return atomic_load_explicit(&((tt_st_writer *)w)->end, memory_order_acquire);
}
uint64_t tt_st_writer_cycles(const tt_st_writer *w) TT_ST_NONBLOCKING {
    return atomic_load_explicit(&((tt_st_writer *)w)->cycles, memory_order_relaxed);
}
uint64_t tt_st_writer_discontinuities(const tt_st_writer *w) TT_ST_NONBLOCKING {
    return atomic_load_explicit(&((tt_st_writer *)w)->discontinuities, memory_order_relaxed);
}

uint32_t tt_st_writer_ranges(const tt_st_writer *w, tt_st_range *dst, uint32_t max) {
    uint32_t n = atomic_load_explicit(&((tt_st_writer *)w)->n_ranges, memory_order_acquire);
    for (uint32_t i = 0; i < n && i < max; i++) dst[i] = w->ranges[i];
    return n;
}

float tt_st_tone(const tt_st_writer *w, int64_t s) TT_ST_NONBLOCKING {
    int64_t idx = (s * 997) % (int64_t)TT_ST_RATE;
    if (idx < 0) idx += TT_ST_RATE;
    return w->tone[idx];
}

void tt_st_writer_render(tt_st_writer *w, float *out, uint32_t frames, uint32_t channels, int64_t s0) TT_ST_NONBLOCKING {
    if (channels == 0) return;
    int64_t first = atomic_load_explicit(&w->first, memory_order_relaxed);
    if (first == TT_ST_NO_SAMPLE) {
        first = s0;
        atomic_store_explicit(&w->first, s0, memory_order_release);
    }
    /* A new range starts whenever the output time is not contiguous. */
    uint32_t n = atomic_load_explicit(&w->n_ranges, memory_order_relaxed);
    if (w->last_end != s0) {
        if (w->last_end != TT_ST_NO_SAMPLE) {
            atomic_fetch_add_explicit(&w->discontinuities, 1, memory_order_relaxed);
        }
        if (n < w->max_ranges) {
            w->ranges[n].begin = s0;
            w->ranges[n].end = s0 + frames;
            atomic_store_explicit(&w->n_ranges, n + 1, memory_order_release);
        }
    } else if (n > 0 && n <= w->max_ranges) {
        w->ranges[n - 1].end = s0 + frames;
    }
    w->last_end = s0 + frames;

    const uint32_t mode = atomic_load_explicit(&w->mode, memory_order_acquire);
    const int64_t sig0 = first + (int64_t)w->lead_frames;
    for (uint32_t i = 0; i < frames; i++) {
        const int64_t s = s0 + (int64_t)i;
        float v = 0.0f;
        if (mode == TT_ST_MODE_SIGNAL) {
            const int64_t rel = s - sig0;
            if (rel >= 0 && rel < (int64_t)w->signal_frames) {
                v = w->signal[rel];
                if (rel == 0) atomic_store_explicit(&w->signal_start, s, memory_order_release);
            }
        } else if (mode == TT_ST_MODE_TONE) {
            v = tt_st_tone(w, s);
        }
        float *frame = out + (size_t)i * channels;
        for (uint32_t k = 0; k < channels; k++) frame[k] = (k == w->channel) ? v : 0.0f;
    }
    atomic_store_explicit(&w->end, s0 + frames, memory_order_release);
    atomic_fetch_add_explicit(&w->cycles, 1, memory_order_relaxed);
}

OSStatus tt_st_writer_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                             const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
                             AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
                             void *_Nullable inClientData) TT_ST_NONBLOCKING {
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime;
    tt_st_writer *w = (tt_st_writer *)inClientData;
    if (w == NULL || outOutputData->mNumberBuffers == 0) return noErr;
    AudioBuffer *buf = &outOutputData->mBuffers[0];
    if (buf->mData == NULL || buf->mNumberChannels == 0) return noErr;
    const uint32_t ch = buf->mNumberChannels;
    const uint32_t frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * ch);
    tt_st_writer_render(w, (float *)buf->mData, frames, ch, tt_st_round(inOutputTime->mSampleTime));
    /* Any further (non-interleaved) buffers get zeros. */
    for (uint32_t b = 1; b < outOutputData->mNumberBuffers; b++) {
        AudioBuffer *o = &outOutputData->mBuffers[b];
        if (o->mData != NULL) memset(o->mData, 0, o->mDataByteSize);
    }
    return noErr;
}

struct tt_st_recorder {
    float *samples;
    uint32_t capacity;
    tt_st_chunk *chunks;
    uint32_t max_chunks;
    _Atomic uint32_t n_samples;
    _Atomic uint32_t n_chunks;
    _Atomic uint64_t cycles;
    _Atomic uint64_t frames;
    _Atomic uint64_t nonzero;
    _Atomic uint64_t discontinuities;
    _Atomic uint64_t overflows;
    int64_t last_end;   /* IO thread only */
};

tt_st_recorder *_Nullable tt_st_recorder_create(uint32_t capacity_frames, uint32_t max_chunks) {
    tt_st_recorder *r = calloc(1, sizeof(tt_st_recorder));
    if (r == NULL) return NULL;
    r->samples = calloc(capacity_frames ? capacity_frames : 1, sizeof(float));
    r->chunks = calloc(max_chunks ? max_chunks : 1, sizeof(tt_st_chunk));
    if (r->samples == NULL || r->chunks == NULL) {
        tt_st_recorder_destroy(r);
        return NULL;
    }
    r->capacity = capacity_frames;
    r->max_chunks = max_chunks;
    tt_st_recorder_reset(r);
    return r;
}

void tt_st_recorder_destroy(tt_st_recorder *_Nullable r) {
    if (r == NULL) return;
    free(r->samples);
    free(r->chunks);
    free(r);
}

void tt_st_recorder_reset(tt_st_recorder *r) {
    atomic_store(&r->n_samples, 0);
    atomic_store(&r->n_chunks, 0);
    atomic_store(&r->cycles, 0);
    atomic_store(&r->frames, 0);
    atomic_store(&r->nonzero, 0);
    atomic_store(&r->discontinuities, 0);
    atomic_store(&r->overflows, 0);
    r->last_end = TT_ST_NO_SAMPLE;
}

#define TT_ST_LOAD(field) atomic_load_explicit(&((tt_st_recorder *)r)->field, memory_order_relaxed)
uint64_t tt_st_recorder_cycles(const tt_st_recorder *r) TT_ST_NONBLOCKING { return TT_ST_LOAD(cycles); }
uint64_t tt_st_recorder_frames(const tt_st_recorder *r) TT_ST_NONBLOCKING { return TT_ST_LOAD(frames); }
uint64_t tt_st_recorder_nonzero(const tt_st_recorder *r) TT_ST_NONBLOCKING { return TT_ST_LOAD(nonzero); }
uint64_t tt_st_recorder_discontinuities(const tt_st_recorder *r) TT_ST_NONBLOCKING { return TT_ST_LOAD(discontinuities); }
uint64_t tt_st_recorder_overflows(const tt_st_recorder *r) TT_ST_NONBLOCKING { return TT_ST_LOAD(overflows); }
#undef TT_ST_LOAD

uint32_t tt_st_recorder_chunk_count(const tt_st_recorder *r) {
    return atomic_load_explicit(&((tt_st_recorder *)r)->n_chunks, memory_order_acquire);
}

uint32_t tt_st_recorder_chunks(const tt_st_recorder *r, tt_st_chunk *dst, uint32_t max) {
    uint32_t n = tt_st_recorder_chunk_count(r);
    for (uint32_t i = 0; i < n && i < max; i++) dst[i] = r->chunks[i];
    return n;
}

uint32_t tt_st_recorder_sample_count(const tt_st_recorder *r) {
    return atomic_load_explicit(&((tt_st_recorder *)r)->n_samples, memory_order_acquire);
}

uint32_t tt_st_recorder_samples(const tt_st_recorder *r, float *dst, uint32_t max) {
    uint32_t n = tt_st_recorder_sample_count(r);
    uint32_t m = n < max ? n : max;
    if (m > 0) memcpy(dst, r->samples, sizeof(float) * m);
    return n;
}

void tt_st_recorder_append(tt_st_recorder *r, const float *_Nullable data, uint32_t frames, uint32_t stride,
                           int64_t s0, uint64_t host_time) TT_ST_NONBLOCKING {
    atomic_fetch_add_explicit(&r->cycles, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->frames, frames, memory_order_relaxed);
    if (r->last_end != TT_ST_NO_SAMPLE && r->last_end != s0) {
        atomic_fetch_add_explicit(&r->discontinuities, 1, memory_order_relaxed);
    }
    r->last_end = s0 + frames;
    uint64_t nz = 0;
    if (data != NULL) {
        for (uint32_t i = 0; i < frames; i++) {
            if (data[(size_t)i * stride] != 0.0f) nz++;
        }
    }
    atomic_fetch_add_explicit(&r->nonzero, nz, memory_order_relaxed);

    const uint32_t off = atomic_load_explicit(&r->n_samples, memory_order_relaxed);
    const uint32_t ci = atomic_load_explicit(&r->n_chunks, memory_order_relaxed);
    if (ci >= r->max_chunks || frames > r->capacity - off) {
        atomic_fetch_add_explicit(&r->overflows, 1, memory_order_relaxed);
        return;
    }
    for (uint32_t i = 0; i < frames; i++) {
        r->samples[off + i] = data != NULL ? data[(size_t)i * stride] : 0.0f;
    }
    r->chunks[ci].sample_time = s0;
    r->chunks[ci].host_time = host_time;
    r->chunks[ci].frames = frames;
    r->chunks[ci].offset = off;
    atomic_store_explicit(&r->n_samples, off + frames, memory_order_release);
    atomic_store_explicit(&r->n_chunks, ci + 1, memory_order_release);
}

OSStatus tt_st_recorder_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                               const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
                               AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
                               void *_Nullable inClientData) TT_ST_NONBLOCKING {
    (void)inDevice; (void)inNow; (void)outOutputData; (void)inOutputTime;
    tt_st_recorder *r = (tt_st_recorder *)inClientData;
    if (r == NULL || inInputData->mNumberBuffers == 0) return noErr;
    const AudioBuffer *buf = &inInputData->mBuffers[0];
    const uint32_t ch = buf->mNumberChannels ? buf->mNumberChannels : 1;
    const uint32_t frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * ch);
    tt_st_recorder_append(r, (const float *)buf->mData, frames, ch, tt_st_round(inInputTime->mSampleTime),
                          inInputTime->mHostTime);
    return noErr;
}
