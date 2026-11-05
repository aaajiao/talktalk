#include "tt_ringp.h"

#include "tt_fade.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* Storage is a power of two at least TT_RINGP_CAPACITY_FRAMES; the logical capacity stays 200 ms. */
#define STORAGE_FRAMES 16384u
#define STORAGE_MASK   (STORAGE_FRAMES - 1u)
#define BLOCK_MASK     (TT_RINGP_MAX_BLOCKS - 1u)

_Static_assert(STORAGE_FRAMES >= TT_RINGP_CAPACITY_FRAMES, "storage too small");
_Static_assert((TT_RINGP_MAX_BLOCKS & (TT_RINGP_MAX_BLOCKS - 1)) == 0, "blocks: power of two");

typedef struct ringp_block {
    uint64_t start;    /* frame index of the block's first frame */
    uint64_t host;     /* capture host time of that frame (mach ticks) */
    uint32_t frames;
    uint32_t gen;
} ringp_block;

/* Consumer-private reader state. */
typedef struct ringp_reader {
    uint32_t playing;        /* 0: waiting for the start buffer */
    uint32_t first_pending;  /* the first audio frame since the last flush is still to come */
    uint32_t fade_in_pos;
    uint32_t fade_in_len;    /* 0 = no fade-in running */
    uint32_t seg_active;     /* underrun fade-out over [seg_start, seg_end) */
    uint32_t seg_len;
    uint64_t seg_start;
    uint64_t seg_end;
} ringp_reader;

struct tt_ringp {
    /* Producer side. */
    _Alignas(128) _Atomic uint64_t write_frames;   /* end of the last published block */
    _Atomic uint64_t block_write;                  /* blocks published */
    _Atomic uint64_t written;
    _Atomic uint64_t overruns;
    /* Consumer side. */
    _Alignas(128) _Atomic uint64_t read_frames;
    _Atomic uint64_t block_read;                   /* first block not fully consumed */
    _Atomic uint64_t underruns;
    _Atomic uint64_t dropped_old;
    _Atomic uint64_t stale;
    _Atomic uint64_t out_of_interval;
    _Atomic uint64_t expired;
    _Atomic uint64_t flushed;
    double tpf;
    float *data;
    ringp_reader rd;
    ringp_block blocks[TT_RINGP_MAX_BLOCKS];
};

tt_ringp *_Nullable tt_ringp_create(double host_ticks_per_frame) {
    if (!(host_ticks_per_frame > 0.0)) return NULL;
    tt_ringp *rp = NULL;
    if (posix_memalign((void **)&rp, 128, sizeof(tt_ringp)) != 0 || rp == NULL) return NULL;
    memset(rp, 0, sizeof(*rp));
    rp->data = calloc(STORAGE_FRAMES, sizeof(float));
    if (rp->data == NULL) {
        free(rp);
        return NULL;
    }
    rp->tpf = host_ticks_per_frame;
    atomic_init(&rp->write_frames, 0);
    atomic_init(&rp->block_write, 0);
    atomic_init(&rp->written, 0);
    atomic_init(&rp->overruns, 0);
    atomic_init(&rp->read_frames, 0);
    atomic_init(&rp->block_read, 0);
    atomic_init(&rp->underruns, 0);
    atomic_init(&rp->dropped_old, 0);
    atomic_init(&rp->stale, 0);
    atomic_init(&rp->out_of_interval, 0);
    atomic_init(&rp->expired, 0);
    atomic_init(&rp->flushed, 0);
    rp->rd.first_pending = 1;
    return rp;
}

void tt_ringp_destroy(tt_ringp *_Nullable rp) {
    if (rp == NULL) return;
    free(rp->data);
    free(rp);
}

/* ---- producer ---- */

uint32_t tt_ringp_write(tt_ringp *rp, const float *src, uint32_t frames,
                        uint64_t src_host_ticks, uint32_t generation) TT_NONBLOCKING {
    if (frames == 0) return 0;
    uint64_t w = atomic_load_explicit(&rp->write_frames, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&rp->read_frames, memory_order_acquire);
    uint64_t bw = atomic_load_explicit(&rp->block_write, memory_order_relaxed);
    uint64_t br = atomic_load_explicit(&rp->block_read, memory_order_acquire);
    uint32_t used = (uint32_t)(w - r);
    uint32_t space = used < TT_RINGP_CAPACITY_FRAMES ? TT_RINGP_CAPACITY_FRAMES - used : 0;
    uint32_t n = frames < space ? frames : space;
    if (bw - br >= TT_RINGP_MAX_BLOCKS) n = 0;
    if (n < frames) atomic_fetch_add_explicit(&rp->overruns, frames - n, memory_order_relaxed);
    if (n == 0) return 0;
    for (uint32_t i = 0; i < n; i++) rp->data[(uint32_t)(w + i) & STORAGE_MASK] = src[i];
    rp->blocks[bw & BLOCK_MASK] = (ringp_block){ .start = w, .host = src_host_ticks, .frames = n, .gen = generation };
    atomic_store_explicit(&rp->write_frames, w + n, memory_order_release);
    atomic_store_explicit(&rp->block_write, bw + 1, memory_order_release);
    atomic_fetch_add_explicit(&rp->written, n, memory_order_relaxed);
    return n;
}

uint32_t tt_ringp_fill(const tt_ringp *rp) TT_NONBLOCKING {
    tt_ringp *m = (tt_ringp *)rp;
    uint64_t w = atomic_load_explicit(&m->write_frames, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&m->read_frames, memory_order_acquire);
    return w > r ? (uint32_t)(w - r) : 0;
}

#define TT_LOAD(field) atomic_load_explicit(&((tt_ringp *)rp)->field, memory_order_relaxed)
uint64_t tt_ringp_written_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(written); }
uint64_t tt_ringp_overrun_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(overruns); }
uint64_t tt_ringp_underruns(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(underruns); }
uint64_t tt_ringp_dropped_old_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(dropped_old); }
uint64_t tt_ringp_stale_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(stale); }
uint64_t tt_ringp_out_of_interval_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(out_of_interval); }
uint64_t tt_ringp_expired_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(expired); }
uint64_t tt_ringp_flushed_frames(const tt_ringp *rp) TT_NONBLOCKING { return TT_LOAD(flushed); }
#undef TT_LOAD

/* ---- consumer ---- */

/* Number of frames of block b captured before host time t: k with host + k * tpf < t. */
static inline uint32_t frames_before(const ringp_block *b, uint64_t t, double tpf) TT_NONBLOCKING {
    if (t <= b->host) return 0;
    double d = (double)(t - b->host) / tpf;
    if (d >= (double)b->frames) return b->frames;
    uint32_t k = (uint32_t)d;
    if ((double)k < d) k++;
    return k < b->frames ? k : b->frames;
}

typedef struct read_view {
    uint64_t r;
    uint64_t br;
    uint64_t bw;
    uint32_t gen;
    uint64_t from;
    uint64_t until;
} read_view;

static inline void reader_reset(ringp_reader *rd) TT_NONBLOCKING {
    *rd = (ringp_reader){ .first_pending = 1 };
}

/* Discards at the read position whatever must not be played: older generations, frames
 * captured before `from` or at/after `until`. Stops at playable data, a newer generation or the
 * end. Adds to the report's counters. */
static void normalize(tt_ringp *rp, read_view *v, tt_ringp_report *rep) TT_NONBLOCKING {
    while (v->br < v->bw) {
        const ringp_block *b = &rp->blocks[v->br & BLOCK_MASK];
        uint64_t bend = b->start + b->frames;
        if (v->r < b->start) v->r = b->start;
        if (v->r >= bend) {
            v->br++;
            continue;
        }
        if (tt_ringp_gen_before(b->gen, v->gen)) {
            rep->stale += (uint32_t)(bend - v->r);
            v->r = bend;
            v->br++;
            continue;
        }
        if (b->gen != v->gen) break;   /* a newer open: not ours */
        uint32_t o = (uint32_t)(v->r - b->start);
        uint32_t cf = frames_before(b, v->from, rp->tpf);
        uint32_t cu = frames_before(b, v->until, rp->tpf);
        if (o < cf) {
            rep->out_of_interval += cf - o;
            v->r = b->start + cf;
            o = cf;
            if (v->r >= bend) {
                v->br++;
                continue;
            }
        }
        if (o >= cu) {
            rep->expired += (uint32_t)(bend - v->r);
            v->r = bend;
            v->br++;
            continue;
        }
        break;
    }
}

/* End of the playable run starting at the (normalized) read position. */
static uint64_t valid_end(const tt_ringp *rp, const read_view *v) TT_NONBLOCKING {
    uint64_t vend = v->r;
    for (uint64_t k = v->br; k < v->bw; k++) {
        const ringp_block *b = &rp->blocks[k & BLOCK_MASK];
        if (b->gen != v->gen || b->start > vend) break;
        uint32_t cf = frames_before(b, v->from, rp->tpf);
        uint32_t cu = frames_before(b, v->until, rp->tpf);
        if (k != v->br && cf > 0) break;
        uint64_t e = b->start + cu;
        if (e > vend) vend = e;
        if (cu < b->frames) break;
    }
    return vend;
}

static inline uint64_t host_of(const tt_ringp *rp, const read_view *v) TT_NONBLOCKING {
    const ringp_block *b = &rp->blocks[v->br & BLOCK_MASK];
    return b->host + (uint64_t)((double)(v->r - b->start) * rp->tpf + 0.5);
}

static void copy_frames(tt_ringp *rp, read_view *v, float *dst, uint32_t n, uint32_t out,
                        tt_ringp_report *rep) TT_NONBLOCKING {
    ringp_reader *rd = &rp->rd;
    if (n == 0) return;
    if (rd->first_pending) {
        rd->first_pending = 0;
        rep->first_audio = 1;
        rep->first_offset = out;
        rep->first_src_ticks = host_of(rp, v);
    }
    for (uint32_t i = 0; i < n; i++) {
        float g = 1.0f;
        if (rd->fade_in_len != 0) {
            g *= tt_fade_in_gain(rd->fade_in_pos, rd->fade_in_len);
            if (++rd->fade_in_pos >= rd->fade_in_len) rd->fade_in_len = 0;
        }
        if (rd->seg_active) g *= tt_fade_out_gain((uint32_t)(v->r + i - rd->seg_start), rd->seg_len);
        dst[out + i] = rp->data[(uint32_t)(v->r + i) & STORAGE_MASK] * g;
    }
    v->r += n;
    rep->audio_frames += n;
}

static void publish(tt_ringp *rp, const read_view *v, const tt_ringp_report *rep) TT_NONBLOCKING {
    if (rep->dropped_old) atomic_fetch_add_explicit(&rp->dropped_old, rep->dropped_old, memory_order_relaxed);
    if (rep->stale) atomic_fetch_add_explicit(&rp->stale, rep->stale, memory_order_relaxed);
    if (rep->out_of_interval) atomic_fetch_add_explicit(&rp->out_of_interval, rep->out_of_interval, memory_order_relaxed);
    if (rep->expired) atomic_fetch_add_explicit(&rp->expired, rep->expired, memory_order_relaxed);
    atomic_store_explicit(&rp->block_read, v->br, memory_order_release);
    atomic_store_explicit(&rp->read_frames, v->r, memory_order_release);
}

uint32_t tt_ringp_read(tt_ringp *rp, float *dst, uint32_t frames, uint32_t generation,
                       uint64_t valid_from_ticks, uint64_t valid_until_ticks,
                       tt_ringp_report *_Nullable report) TT_NONBLOCKING {
    ringp_reader *rd = &rp->rd;
    tt_ringp_report local;
    tt_ringp_report *rep = report != NULL ? report : &local;
    *rep = (tt_ringp_report){ 0 };
    read_view v = {
        .bw = atomic_load_explicit(&rp->block_write, memory_order_acquire),
        .br = atomic_load_explicit(&rp->block_read, memory_order_relaxed),
        .r = atomic_load_explicit(&rp->read_frames, memory_order_relaxed),
        .gen = generation,
        .from = valid_from_ticks,
        .until = valid_until_ticks,
    };

    uint32_t out = 0;
    for (uint32_t guard = 0; out < frames && guard < 64; guard++) {
        normalize(rp, &v, rep);
        uint64_t vend = valid_end(rp, &v);
        uint64_t avail = vend - v.r;

        if (rd->seg_active) {
            if (rd->seg_end > vend) rd->seg_end = vend;   /* frames may have expired meanwhile */
            uint64_t left = rd->seg_end > v.r ? rd->seg_end - v.r : 0;
            uint32_t n = (uint32_t)(left < (uint64_t)(frames - out) ? left : (uint64_t)(frames - out));
            copy_frames(rp, &v, dst, n, out, rep);
            out += n;
            if (v.r >= rd->seg_end) {
                rd->seg_active = 0;
                rd->fade_in_len = 0;
                rd->playing = 0;
                rep->underrun = 1;
                atomic_fetch_add_explicit(&rp->underruns, 1, memory_order_relaxed);
            }
            continue;
        }

        if (!rd->playing) {
            if (avail < TT_RINGP_START_FRAMES) break;
            rd->playing = 1;
            rd->fade_in_pos = 0;
            rd->fade_in_len = rd->first_pending ? TT_RINGP_OPEN_FADE_IN_FRAMES : TT_RINGP_RESUME_FADE_IN_FRAMES;
            continue;
        }

        /* Latency bound: keep at most 60 ms; cut the oldest with a short crossfade. */
        uint32_t need = frames - out;
        if (avail > TT_RINGP_MAX_FILL_FRAMES && rd->fade_in_len == 0 && need >= TT_RINGP_XFADE_FRAMES) {
            uint64_t keep = (uint64_t)need + TT_RINGP_START_FRAMES;
            if (avail > keep + TT_RINGP_XFADE_FRAMES) {
                uint64_t newr = vend - keep;
                for (uint32_t i = 0; i < TT_RINGP_XFADE_FRAMES; i++) {
                    float g = tt_fade_in_gain(i, TT_RINGP_XFADE_FRAMES);
                    float old_s = rp->data[(uint32_t)(v.r + i) & STORAGE_MASK];
                    float new_s = rp->data[(uint32_t)(newr + i) & STORAGE_MASK];
                    dst[out + i] = old_s * (1.0f - g) + new_s * g;
                }
                if (rd->first_pending) {
                    rd->first_pending = 0;
                    rep->first_audio = 1;
                    rep->first_offset = out;
                    rep->first_src_ticks = host_of(rp, &v);
                }
                rep->dropped_old += (uint32_t)(newr - v.r);
                rep->audio_frames += TT_RINGP_XFADE_FRAMES;
                v.r = newr + TT_RINGP_XFADE_FRAMES;
                out += TT_RINGP_XFADE_FRAMES;
                continue;
            }
        }

        uint64_t free_end = avail > TT_RINGP_HOLD_FRAMES ? vend - TT_RINGP_HOLD_FRAMES : v.r;
        if (free_end > v.r) {
            uint64_t left = free_end - v.r;
            uint32_t n = (uint32_t)(left < (uint64_t)need ? left : (uint64_t)need);
            copy_frames(rp, &v, dst, n, out, rep);
            out += n;
            continue;
        }
        if (avail == 0) {
            rd->playing = 0;
            rd->fade_in_len = 0;
            rep->underrun = 1;
            atomic_fetch_add_explicit(&rp->underruns, 1, memory_order_relaxed);
            continue;
        }
        rd->seg_active = 1;
        rd->seg_start = v.r;
        rd->seg_end = vend;
        rd->seg_len = (uint32_t)avail;
    }
    for (; out < frames; out++) dst[out] = 0.0f;
    publish(rp, &v, rep);
    return frames;
}

void tt_ringp_flush(tt_ringp *rp) TT_NONBLOCKING {
    uint64_t bw = atomic_load_explicit(&rp->block_write, memory_order_acquire);
    uint64_t br = atomic_load_explicit(&rp->block_read, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&rp->read_frames, memory_order_relaxed);
    if (bw > br) {
        const ringp_block *last = &rp->blocks[(bw - 1) & BLOCK_MASK];
        uint64_t end = last->start + last->frames;
        if (end > r) {
            atomic_fetch_add_explicit(&rp->flushed, end - r, memory_order_relaxed);
            r = end;
        }
    }
    reader_reset(&rp->rd);
    atomic_store_explicit(&rp->block_read, bw, memory_order_release);
    atomic_store_explicit(&rp->read_frames, r, memory_order_release);
}

void tt_ringp_discard_through(tt_ringp *rp, uint32_t generation) TT_NONBLOCKING {
    uint64_t bw = atomic_load_explicit(&rp->block_write, memory_order_acquire);
    uint64_t br = atomic_load_explicit(&rp->block_read, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&rp->read_frames, memory_order_relaxed);
    uint64_t dropped = 0;
    while (br < bw) {
        const ringp_block *b = &rp->blocks[br & BLOCK_MASK];
        if (tt_ringp_gen_before(generation, b->gen)) break;   /* newer than `generation`: keep */
        uint64_t bend = b->start + b->frames;
        if (r < bend) {
            dropped += bend - (r > b->start ? r : b->start);
            r = bend;
        }
        br++;
    }
    if (dropped) atomic_fetch_add_explicit(&rp->stale, dropped, memory_order_relaxed);
    reader_reset(&rp->rd);
    atomic_store_explicit(&rp->block_read, br, memory_order_release);
    atomic_store_explicit(&rp->read_frames, r, memory_order_release);
}
