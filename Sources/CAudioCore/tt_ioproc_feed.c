#include "tt_ioproc_feed.h"

#include "tt_fade.h"

#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* Where one channel lives in an AudioBufferList. */
typedef struct chan_loc {
    float *base;      /* first sample of the channel */
    uint32_t stride;  /* floats between frames */
    uint32_t frames;  /* frames the buffer holds */
} chan_loc;

#define MODE_STOP 0xFFu   /* a cycle that plays nothing (generation change, unreadable state) */

struct tt_feed_ctx {
    tt_ring *ring_o;
    tt_ringp *ring_p;
    tt_pt_state *pt;
    tt_event_ring *_Nullable events;
    tt_envelope *_Nullable env;
    double tpf;
    uint32_t latency;
    uint32_t max_cycle;
    float *scratch;

    _Atomic uint32_t chunk_p95;     /* set by the worker */
    _Atomic uint32_t mode_pub;
    _Atomic uint32_t resume_pub;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t frames;
    _Atomic uint64_t o_audio;
    _Atomic uint64_t p_audio;
    _Atomic uint64_t out_underruns;
    _Atomic uint64_t pt_underruns;
    _Atomic uint64_t pt_opens;
    _Atomic uint64_t pt_lease_expiries;
    _Atomic uint64_t pt_out_of_interval;
    _Atomic uint64_t mixed;
    _Atomic uint64_t missing;
    _Atomic uint32_t lc_frames, lc_mode, lc_o, lc_p, lc_ch, lc_gen;
    _Atomic uint64_t lc_host;

    /* IO thread only. */
    uint32_t mode;
    uint32_t gen;            /* passthrough being played */
    uint32_t channel;        /* its Feed channel */
    uint64_t open_ticks;
    uint64_t close_until;    /* PT_CLOSING: frames captured from here on are not played */
    uint32_t fade_pos;       /* progress of the O_TO_P or PT_CLOSING fade */
    uint32_t o_suspended;    /* ringO was faded out for ringP and not read since */
    uint32_t done_gen;       /* last generation seen not live: it never plays again */
    uint32_t have_done;
    uint64_t feed_frames;    /* frames processed: the clock for the rebuffer rules */
    uint32_t mult;           /* rebuffer multiplier (1, 2, 4, ...) */
    uint32_t have_underrun;
    uint64_t last_underrun;
    uint64_t decay_mark;
};

tt_feed_ctx *_Nullable tt_feed_ctx_create(tt_ring *ring_o, tt_ringp *ring_p, tt_pt_state *pt,
                                          tt_event_ring *_Nullable events,
                                          tt_envelope *_Nullable envelope,
                                          const tt_feed_config *config) {
    if (!(config->host_ticks_per_frame > 0.0)) return NULL;
    /* The generation current now is finished for this context: whatever was open before a detach
     * or an interruption never plays here, even if its lease is renewed (§3.6: a new, clean press).
     * The gate writes for nanoseconds under its own lock, so a consistent read comes at once. */
    tt_pt_snapshot snap = tt_pt_state_read(pt);
    for (int i = 0; i < 1000 && !snap.valid; i++) {
        sched_yield();
        snap = tt_pt_state_read(pt);
    }
    if (!snap.valid) return NULL;
    tt_feed_ctx *ctx = calloc(1, sizeof(tt_feed_ctx));
    if (ctx == NULL) return NULL;
    ctx->max_cycle = config->max_cycle_frames ? config->max_cycle_frames : TT_FEED_DEFAULT_MAX_CYCLE_FRAMES;
    ctx->scratch = calloc(ctx->max_cycle, sizeof(float));
    if (ctx->scratch == NULL) {
        free(ctx);
        return NULL;
    }
    ctx->ring_o = ring_o;
    ctx->ring_p = ring_p;
    ctx->pt = pt;
    ctx->events = events;
    ctx->env = envelope;
    ctx->tpf = config->host_ticks_per_frame;
    ctx->latency = config->mic_latency_frames;
    ctx->mode = TT_FEED_MODE_RING_O;
    ctx->mult = 1;
    ctx->done_gen = snap.generation;
    ctx->have_done = 1;
    atomic_init(&ctx->chunk_p95, 0);
    atomic_init(&ctx->mode_pub, TT_FEED_MODE_RING_O);
    atomic_init(&ctx->resume_pub, TT_FEED_RESUME_MIN_FRAMES);
    return ctx;
}

void tt_feed_ctx_destroy(tt_feed_ctx *_Nullable ctx) {
    if (ctx == NULL) return;
    free(ctx->scratch);
    free(ctx);
}

void tt_feed_set_chunk_interval_p95_frames(tt_feed_ctx *ctx, uint32_t frames) TT_NONBLOCKING {
    atomic_store_explicit(&ctx->chunk_p95, frames, memory_order_relaxed);
}

#define TT_LOAD(field) atomic_load_explicit(&((tt_feed_ctx *)ctx)->field, memory_order_relaxed)
uint32_t tt_feed_resume_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(resume_pub); }
uint32_t tt_feed_mode(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(mode_pub); }
uint64_t tt_feed_callbacks(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(callbacks); }
uint64_t tt_feed_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(frames); }
uint64_t tt_feed_ring_o_audio_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(o_audio); }
uint64_t tt_feed_ring_p_audio_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(p_audio); }
uint64_t tt_feed_out_underruns(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(out_underruns); }
uint64_t tt_feed_pt_underruns(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(pt_underruns); }
uint64_t tt_feed_pt_opens(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(pt_opens); }
uint64_t tt_feed_pt_lease_expiries(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(pt_lease_expiries); }
uint64_t tt_feed_pt_out_of_interval_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(pt_out_of_interval); }
uint64_t tt_feed_mixed_cycles(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(mixed); }
uint64_t tt_feed_missing_buffers(const tt_feed_ctx *ctx) TT_NONBLOCKING { return TT_LOAD(missing); }

tt_feed_cycle tt_feed_last_cycle(const tt_feed_ctx *ctx) TT_NONBLOCKING {
    return (tt_feed_cycle){
        .frames = TT_LOAD(lc_frames),
        .mode = TT_LOAD(lc_mode),
        .ring_o_audio = TT_LOAD(lc_o),
        .ring_p_audio = TT_LOAD(lc_p),
        .ring_p_channel = TT_LOAD(lc_ch),
        .generation = TT_LOAD(lc_gen),
        .out_host_ticks = TT_LOAD(lc_host),
    };
}
#undef TT_LOAD

static inline void add(_Atomic uint64_t *c, uint64_t v) TT_NONBLOCKING {
    if (v) atomic_fetch_add_explicit(c, v, memory_order_relaxed);
}

/* Host time at which frame `offset` of this cycle reaches TalkTalk Mic. */
static inline uint64_t arrival(const tt_feed_ctx *ctx, uint64_t out_host, uint32_t offset) TT_NONBLOCKING {
    if (out_host == 0) return 0;
    return out_host + (uint64_t)(((double)offset + (double)ctx->latency) * ctx->tpf + 0.5);
}

static inline void emit(tt_feed_ctx *ctx, uint16_t type, uint64_t host, uint32_t a, uint64_t b) TT_NONBLOCKING {
    if (ctx->events != NULL) tt_event_push4(ctx->events, type, TT_EV_SRC_FEED, host, a, b);
}

static bool locate(AudioBufferList *abl, uint32_t channel, chan_loc *loc) TT_NONBLOCKING {
    uint32_t base = 0;
    for (uint32_t b = 0; b < abl->mNumberBuffers; b++) {
        AudioBuffer *buf = &abl->mBuffers[b];
        uint32_t nch = buf->mNumberChannels;
        if (nch == 0) continue;
        if (channel < base + nch) {
            if (buf->mData == NULL) return false;
            loc->base = (float *)buf->mData + (channel - base);
            loc->stride = nch;
            loc->frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * nch);
            return true;
        }
        base += nch;
    }
    return false;
}

static void zero_all(AudioBufferList *abl) TT_NONBLOCKING {
    for (uint32_t b = 0; b < abl->mNumberBuffers; b++) {
        AudioBuffer *buf = &abl->mBuffers[b];
        if (buf->mData == NULL) continue;
        float *p = (float *)buf->mData;
        uint32_t n = buf->mDataByteSize / (uint32_t)sizeof(float);
        for (uint32_t i = 0; i < n; i++) p[i] = 0.0f;
    }
}

static void put(const chan_loc *loc, uint32_t offset, const float *src, uint32_t n) TT_NONBLOCKING {
    for (uint32_t i = 0; i < n && offset + i < loc->frames; i++) {
        loc->base[(size_t)(offset + i) * loc->stride] = src[i];
    }
}

static uint32_t resume_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING {
    uint64_t base = 2ull * atomic_load_explicit(&((tt_feed_ctx *)ctx)->chunk_p95, memory_order_relaxed);
    if (base < TT_FEED_RESUME_MIN_FRAMES) base = TT_FEED_RESUME_MIN_FRAMES;
    uint64_t v = base * ctx->mult;
    return v > TT_FEED_RESUME_MAX_FRAMES ? TT_FEED_RESUME_MAX_FRAMES : (uint32_t)v;
}

static void note_underrun(tt_feed_ctx *ctx, uint64_t at) TT_NONBLOCKING {
    if (ctx->have_underrun && at - ctx->last_underrun <= TT_FEED_RESUME_DOUBLE_WINDOW_FRAMES &&
        resume_frames(ctx) < TT_FEED_RESUME_MAX_FRAMES && ctx->mult < 1024) {
        ctx->mult *= 2;
    }
    ctx->have_underrun = 1;
    ctx->last_underrun = at;
    ctx->decay_mark = at;
}

/* One ringO event of a report, to be emitted in output order. */
typedef struct o_item {
    uint32_t offset;   /* dst index */
    uint32_t rank;     /* order at the same offset: what ends comes before what starts */
    uint16_t type;
    uint32_t a;
    uint64_t b;
} o_item;

#define O_ITEMS_MAX (TT_RING_REPORT_MAX_STARTS + 6u)

static void handle_o_report(tt_feed_ctx *ctx, const tt_ring_playout_report *rep, uint64_t out_host,
                            uint32_t offset) TT_NONBLOCKING {
    o_item items[O_ITEMS_MAX];
    uint32_t n = 0;
    if (rep->events & TT_RING_EV_ENDED) items[n++] = (o_item){ rep->ended_offset, 0, TT_EV_OUT_ENDED, 0, 0 };
    if (rep->events & TT_RING_EV_CUT)
        items[n++] = (o_item){ rep->cut_offset, 0, TT_EV_OUT_CLAUSE_CUT, rep->cut_tag, rep->cut_dropped };
    if (rep->events & TT_RING_EV_FLUSHED)
        items[n++] = (o_item){ rep->cut_offset, 0, TT_EV_OUT_FLUSHED, rep->cut_tag, rep->cut_dropped };
    if (rep->events & TT_RING_EV_UNDERRUN) items[n++] = (o_item){ rep->zero_offset, 0, TT_EV_OUT_UNDERRUN, 0, 0 };
    if (rep->events & TT_RING_EV_PARKED) items[n++] = (o_item){ rep->parked_offset, 1, TT_EV_OUT_PARKED, 0, 0 };
    if (rep->events & TT_RING_EV_RESUMED)
        items[n++] = (o_item){ rep->resumed_offset, 2, TT_EV_OUT_RESUMED, 0, resume_frames(ctx) };
    for (uint32_t k = 0; k < rep->start_count && n < O_ITEMS_MAX; k++) {
        items[n++] = (o_item){ rep->start_offset[k], 3, TT_EV_OUT_FIRST_SAMPLE, rep->start_tag[k], 0 };
    }
    /* Insertion sort (stable) by offset, then rank. */
    for (uint32_t i = 1; i < n; i++) {
        o_item x = items[i];
        uint32_t j = i;
        while (j > 0 && (items[j - 1].offset > x.offset ||
                         (items[j - 1].offset == x.offset && items[j - 1].rank > x.rank))) {
            items[j] = items[j - 1];
            j--;
        }
        items[j] = x;
    }
    for (uint32_t i = 0; i < n; i++) {
        const o_item *it = &items[i];
        if (it->type == TT_EV_OUT_UNDERRUN) {
            add(&ctx->out_underruns, 1);
            note_underrun(ctx, ctx->feed_frames + offset + it->offset);
        }
        emit(ctx, it->type, arrival(ctx, out_host, offset + it->offset), it->a, it->b);
    }
}

static void handle_p_report(tt_feed_ctx *ctx, const tt_ringp_report *rep, uint64_t out_host,
                            uint32_t offset, bool closing) TT_NONBLOCKING {
    if (rep->first_audio) {
        emit(ctx, TT_EV_PT_FIRST_SAMPLE, arrival(ctx, out_host, offset + rep->first_offset), ctx->gen, rep->first_src_ticks);
    }
    if (rep->underrun && !closing) {
        add(&ctx->pt_underruns, 1);
        emit(ctx, TT_EV_PT_UNDERRUN, arrival(ctx, out_host, offset), ctx->gen, 0);
    }
    uint32_t bad = rep->out_of_interval + rep->expired;
    if (bad) {
        add(&ctx->pt_out_of_interval, bad);
        emit(ctx, TT_EV_PT_DISCARDED, arrival(ctx, out_host, offset), ctx->gen, bad);
    }
}

static void enter_pt(tt_feed_ctx *ctx, const tt_pt_snapshot *snap, uint64_t out_host) TT_NONBLOCKING {
    ctx->mode = TT_FEED_MODE_PT;
    ctx->gen = snap->generation;
    ctx->channel = tt_pt_source_channel(snap->source);
    ctx->open_ticks = snap->open_ticks;
    /* Leftovers of earlier opens go; this generation's blocks stay; the reader starts fresh. */
    tt_ringp_discard_through(ctx->ring_p, snap->generation - 1u);
    add(&ctx->pt_opens, 1);
    emit(ctx, TT_EV_PT_OPEN_SEEN, arrival(ctx, out_host, 0), snap->generation, 0);
}

void tt_feed_process(tt_feed_ctx *ctx, AudioBufferList *output, uint32_t frames,
                     uint64_t out_host_ticks) TT_NONBLOCKING {
    add(&ctx->callbacks, 1);
    add(&ctx->frames, frames);
    zero_all(output);

    chan_loc loc[TT_FEED_CHANNELS];
    bool have[TT_FEED_CHANNELS];
    for (uint32_t c = 0; c < TT_FEED_CHANNELS; c++) have[c] = locate(output, c, &loc[c]);
    if (!have[0]) {
        add(&ctx->missing, 1);
        ctx->feed_frames += frames;
        return;
    }

    tt_pt_snapshot snap = tt_pt_state_read(ctx->pt);
    bool live = out_host_ticks != 0 && tt_pt_snapshot_live(&snap, out_host_ticks);
    uint64_t valid_until = tt_pt_snapshot_valid_until(&snap);
    /* A generation seen not live (closed, lease over, deadline) is finished for good, even if
     * its lease is renewed later: only a new open plays again. */
    if (snap.valid && !live) {
        ctx->done_gen = snap.generation;
        ctx->have_done = 1;
    }
    bool finished = ctx->have_done && snap.generation == ctx->done_gen;

    if (ctx->mult > 1 && ctx->feed_frames - ctx->decay_mark >= TT_FEED_RESUME_DECAY_FRAMES) {
        ctx->mult /= 2;
        ctx->decay_mark = ctx->feed_frames;
    }

    /* One source for the whole cycle. */
    uint32_t run = ctx->mode;
    switch (ctx->mode) {
    case TT_FEED_MODE_RING_O:
        if (live && !finished) {
            if (!ctx->o_suspended && tt_ring_playout_state(ctx->ring_o) == TT_RING_STATE_PLAYING) {
                ctx->mode = TT_FEED_MODE_O_TO_P;
                ctx->fade_pos = 0;
            } else {
                enter_pt(ctx, &snap, out_host_ticks);
            }
            run = ctx->mode;
        }
        break;
    case TT_FEED_MODE_PT:
        if (live && !finished && snap.generation == ctx->gen) break;
        if (snap.valid && snap.generation == ctx->gen) {
            if (snap.open) {
                add(&ctx->pt_lease_expiries, 1);
                emit(ctx, TT_EV_PT_LEASE_EXPIRED, arrival(ctx, out_host_ticks, 0), ctx->gen, 0);
            }
            ctx->close_until = valid_until;
            ctx->mode = TT_FEED_MODE_PT_CLOSING;
            ctx->fade_pos = 0;
            run = ctx->mode;
        } else {
            /* A newer generation (or no consistent state): stop at once, nothing this cycle. */
            tt_ringp_flush(ctx->ring_p);
            emit(ctx, TT_EV_PT_ZERO, arrival(ctx, out_host_ticks, 0), ctx->gen, 0);
            ctx->mode = TT_FEED_MODE_RING_O;
            run = MODE_STOP;
        }
        break;
    default: /* O_TO_P and PT_CLOSING finish their fade first */
        break;
    }

    if (run == TT_FEED_MODE_RING_O) {
        /* Passthrough is not live (or finished): every open starts from an empty ringP. */
        if (snap.valid) tt_ringp_discard_through(ctx->ring_p, snap.generation);
        else tt_ringp_flush(ctx->ring_p);
        ctx->o_suspended = 0;
    }

    if (run == TT_FEED_MODE_PT || run == TT_FEED_MODE_PT_CLOSING || run == MODE_STOP) {
        /* ringO is not read this cycle: its controls (jumps, pause) still apply, at once. */
        tt_ring_playout_report rep;
        tt_ring_playout_suspend(ctx->ring_o, &rep);
        handle_o_report(ctx, &rep, out_host_ticks, 0);
    }

    uint32_t resume = resume_frames(ctx);
    uint32_t cyc_o = 0, cyc_p = 0;
    uint32_t p_channel = ctx->channel;
    uint32_t p_gen = ctx->gen;
    for (uint32_t done = 0; done < frames;) {
        uint32_t n = frames - done < ctx->max_cycle ? frames - done : ctx->max_cycle;
        float *s = ctx->scratch;
        uint32_t channel = 0;
        bool silent = false;
        switch (run) {
        case TT_FEED_MODE_RING_O: {
            tt_ring_playout_report rep;
            tt_ring_playout_read(ctx->ring_o, s, n, resume, &rep);
            handle_o_report(ctx, &rep, out_host_ticks, done);
            cyc_o += rep.audio_frames;
            break;
        }
        case TT_FEED_MODE_O_TO_P: {
            uint32_t m = TT_FEED_O_FADE_OUT_FRAMES - ctx->fade_pos;
            if (m > n) m = n;
            if (m > 0) {
                tt_ring_playout_report rep;
                tt_ring_playout_read(ctx->ring_o, s, m, resume, &rep);
                handle_o_report(ctx, &rep, out_host_ticks, done);
                for (uint32_t i = 0; i < m; i++) s[i] *= tt_fade_out_gain(ctx->fade_pos + i, TT_FEED_O_FADE_OUT_FRAMES);
                cyc_o += rep.audio_frames;
                ctx->fade_pos += m;
            }
            for (uint32_t i = m; i < n; i++) s[i] = 0.0f;
            if (ctx->fade_pos >= TT_FEED_O_FADE_OUT_FRAMES && ctx->mode == TT_FEED_MODE_O_TO_P) {
                /* ringO is silent now: whatever fade it was in completes, controls apply. */
                tt_ring_playout_report rep;
                tt_ring_playout_suspend(ctx->ring_o, &rep);
                handle_o_report(ctx, &rep, out_host_ticks, done + m);
                ctx->o_suspended = 1;
                ctx->mode = TT_FEED_MODE_RING_O;   /* the next cycle hands over to ringP if still live */
            }
            break;
        }
        case TT_FEED_MODE_PT: {
            tt_ringp_report rep;
            tt_ringp_read(ctx->ring_p, s, n, ctx->gen, ctx->open_ticks, valid_until, &rep);
            handle_p_report(ctx, &rep, out_host_ticks, done, false);
            cyc_p += rep.audio_frames;
            channel = ctx->channel;
            break;
        }
        case TT_FEED_MODE_PT_CLOSING: {
            uint32_t m = TT_FEED_PT_FADE_OUT_FRAMES - ctx->fade_pos;
            if (m > n) m = n;
            if (m > 0) {
                tt_ringp_report rep;
                tt_ringp_read(ctx->ring_p, s, m, ctx->gen, ctx->open_ticks, ctx->close_until, &rep);
                handle_p_report(ctx, &rep, out_host_ticks, done, true);
                for (uint32_t i = 0; i < m; i++) s[i] *= tt_fade_out_gain(ctx->fade_pos + i, TT_FEED_PT_FADE_OUT_FRAMES);
                cyc_p += rep.audio_frames;
                ctx->fade_pos += m;
            }
            for (uint32_t i = m; i < n; i++) s[i] = 0.0f;
            channel = ctx->channel;
            if (ctx->fade_pos >= TT_FEED_PT_FADE_OUT_FRAMES && ctx->mode == TT_FEED_MODE_PT_CLOSING) {
                tt_ringp_flush(ctx->ring_p);
                emit(ctx, TT_EV_PT_ZERO, arrival(ctx, out_host_ticks, done + m), ctx->gen, 0);
                ctx->mode = TT_FEED_MODE_RING_O;
            }
            break;
        }
        default:
            silent = true;
            break;
        }
        if (!silent && channel < TT_FEED_CHANNELS && have[channel]) put(&loc[channel], done, s, n);
        if (ctx->env != NULL) {
            bool to_meeting = !silent && channel == 0;
            tt_envelope_push(ctx->env, to_meeting ? s : NULL, n, 1, arrival(ctx, out_host_ticks, done));
        }
        done += n;
    }

    if (cyc_o > 0 && cyc_p > 0) add(&ctx->mixed, 1);
    add(&ctx->o_audio, cyc_o);
    add(&ctx->p_audio, cyc_p);
    ctx->feed_frames += frames;
    atomic_store_explicit(&ctx->lc_frames, frames, memory_order_relaxed);
    atomic_store_explicit(&ctx->lc_mode, run, memory_order_relaxed);
    atomic_store_explicit(&ctx->lc_o, cyc_o, memory_order_relaxed);
    atomic_store_explicit(&ctx->lc_p, cyc_p, memory_order_relaxed);
    atomic_store_explicit(&ctx->lc_ch, p_channel, memory_order_relaxed);
    atomic_store_explicit(&ctx->lc_gen, p_gen, memory_order_relaxed);
    atomic_store_explicit(&ctx->lc_host, out_host_ticks, memory_order_relaxed);
    atomic_store_explicit(&ctx->mode_pub, ctx->mode, memory_order_relaxed);
    atomic_store_explicit(&ctx->resume_pub, resume_frames(ctx), memory_order_relaxed);
}

OSStatus tt_feed_ioproc(AudioObjectID inDevice,
                        const AudioTimeStamp *inNow,
                        const AudioBufferList *inInputData,
                        const AudioTimeStamp *inInputTime,
                        AudioBufferList *outOutputData,
                        const AudioTimeStamp *inOutputTime,
                        void *_Nullable inClientData) TT_NONBLOCKING {
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime;
    tt_feed_ctx *ctx = (tt_feed_ctx *)inClientData;
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
    tt_feed_process(ctx, outOutputData, frames, host);
    return noErr;
}
