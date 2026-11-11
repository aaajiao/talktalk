#include "tt_ring.h"

#include "tt_fade.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct tt_ring_mark {
    uint64_t pos;    /* frame index the mark sits at */
    uint32_t tag;
    uint32_t kind;   /* TT_RING_CLAUSE_START or TT_RING_CLAUSE_END */
} tt_ring_mark;

/* Playout reader state (consumer thread only, §3.3). */
typedef struct tt_ring_reader {
    uint32_t state;          /* TT_RING_STATE_* */
    uint32_t fade_in_pos;    /* next frame of the running fade-in */
    uint32_t fade_in_len;    /* 0 = no fade-in running */
    uint32_t seg_kind;       /* SEG_* (0 = no fade-out segment) */
    uint64_t seg_start;      /* fade-out segment [seg_start, seg_end) in frame indices */
    uint64_t seg_end;
    uint32_t seg_len;        /* fade length (seg_end - seg_start when it started) */
    uint32_t jump_kind;      /* jump being executed by a SEG_CUT */
    uint64_t jump_target;
    uint64_t jump_seq;
    uint64_t jump_marks;     /* marks pushed before that request (dropped by a WRITE_INDEX jump) */
    uint32_t cut_tag;
    uint32_t current_tag;    /* tag of the last START mark played */
} tt_ring_reader;

struct tt_ring {
    /* Separate cache lines for the two indices so producer and consumer don't false-share. */
    _Alignas(128) _Atomic uint64_t write_index;
    _Alignas(128) _Atomic uint64_t read_index;
    _Alignas(128) _Atomic uint64_t overruns;
    uint32_t capacity; /* power of two */
    uint32_t mask;
    float *data;

    /* Playout extension. Producer side. */
    _Alignas(128) _Atomic uint64_t mark_write;      /* marks pushed */
    _Atomic uint32_t max_lead;
    _Atomic uint32_t pause_req;
    _Atomic uint64_t jump_req_seq;                  /* even = stable request, odd = writer updating it */
    _Atomic uint64_t jump_req_word;                 /* (write index << 2) | kind */
    _Atomic uint64_t jump_req_marks;                /* mark_write at the request */
    _Atomic uint64_t mark_overflows;
    /* Consumer side, published. */
    _Alignas(128) _Atomic uint64_t mark_read;       /* marks retired by the reader */
    _Atomic uint64_t jump_ack_seq;
    _Atomic uint32_t reader_state;
    _Atomic uint64_t underruns;
    tt_ring_reader reader;
    tt_ring_mark marks[TT_RING_MAX_MARKS];
};

#define SEG_NONE     0u
#define SEG_END      1u   /* hold-back fade at a clause END: then idle */
#define SEG_UNDERRUN 2u   /* hold-back fade without END: then underrun */
#define SEG_PAUSE    3u   /* fade before the START mark the reader parks on */
#define SEG_CUT      4u   /* 30 ms fade before a jump */

_Static_assert((TT_RING_MAX_MARKS & (TT_RING_MAX_MARKS - 1)) == 0, "marks: power of two");

static uint32_t round_up_pow2(uint32_t v) {
    uint32_t c = 1024;
    while (c < v && c < (1u << 30)) c <<= 1;
    return c;
}

tt_ring *tt_ring_create(uint32_t min_capacity_frames) {
    tt_ring *ring = NULL;
    if (posix_memalign((void **)&ring, 128, sizeof(tt_ring)) != 0 || ring == NULL) return NULL;
    memset(ring, 0, sizeof(*ring));
    ring->capacity = round_up_pow2(min_capacity_frames);
    ring->mask = ring->capacity - 1;
    ring->data = calloc(ring->capacity, sizeof(float));
    if (ring->data == NULL) {
        free(ring);
        return NULL;
    }
    atomic_init(&ring->write_index, 0);
    atomic_init(&ring->read_index, 0);
    atomic_init(&ring->overruns, 0);
    atomic_init(&ring->mark_write, 0);
    atomic_init(&ring->max_lead, ring->capacity);
    atomic_init(&ring->pause_req, 0);
    atomic_init(&ring->jump_req_seq, 0);
    atomic_init(&ring->jump_req_word, 0);
    atomic_init(&ring->mark_overflows, 0);
    atomic_init(&ring->mark_read, 0);
    atomic_init(&ring->jump_ack_seq, 0);
    atomic_init(&ring->reader_state, TT_RING_STATE_IDLE);
    atomic_init(&ring->underruns, 0);
    return ring;
}

void tt_ring_destroy(tt_ring *ring) {
    if (ring == NULL) return;
    free(ring->data);
    free(ring);
}

uint32_t tt_ring_capacity(const tt_ring *ring) { return ring->capacity; }

static inline uint32_t free_space(tt_ring *ring, uint64_t w) TT_NONBLOCKING {
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    return ring->capacity - (uint32_t)(w - r);
}

uint32_t tt_ring_write_strided(tt_ring *ring, const float *src, uint32_t frames, uint32_t stride) TT_NONBLOCKING {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint32_t space = free_space(ring, w);
    uint32_t n = frames < space ? frames : space;
    if (stride == 0) stride = 1;
    for (uint32_t i = 0; i < n; i++) {
        ring->data[(uint32_t)(w + i) & ring->mask] = src[(size_t)i * stride];
    }
    atomic_store_explicit(&ring->write_index, w + n, memory_order_release);
    if (n < frames) atomic_fetch_add_explicit(&ring->overruns, frames - n, memory_order_relaxed);
    return n;
}

uint32_t tt_ring_write_zeros(tt_ring *ring, uint32_t frames) TT_NONBLOCKING {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint32_t space = free_space(ring, w);
    uint32_t n = frames < space ? frames : space;
    for (uint32_t i = 0; i < n; i++) ring->data[(uint32_t)(w + i) & ring->mask] = 0.0f;
    atomic_store_explicit(&ring->write_index, w + n, memory_order_release);
    if (n < frames) atomic_fetch_add_explicit(&ring->overruns, frames - n, memory_order_relaxed);
    return n;
}

uint32_t tt_ring_read(tt_ring *ring, float *dst, uint32_t max_frames) TT_NONBLOCKING {
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - r);
    uint32_t n = max_frames < avail ? max_frames : avail;
    for (uint32_t i = 0; i < n; i++) dst[i] = ring->data[(uint32_t)(r + i) & ring->mask];
    atomic_store_explicit(&ring->read_index, r + n, memory_order_release);
    return n;
}

uint32_t tt_ring_available(const tt_ring *ring) TT_NONBLOCKING {
    tt_ring *m = (tt_ring *)ring;
    uint64_t w = atomic_load_explicit(&m->write_index, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&m->read_index, memory_order_acquire);
    return (uint32_t)(w - r);
}

uint64_t tt_ring_written_frames(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->write_index, memory_order_acquire);
}

uint64_t tt_ring_overrun_frames(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->overruns, memory_order_relaxed);
}

void tt_ring_reset(tt_ring *ring) {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    atomic_store_explicit(&ring->read_index, w, memory_order_release);
}

/* ---- Playout (ringO, ringO2; ARCHITECTURE.md, "实时音频与生命周期约束") ------------------------------------------ */

#define MARK_MASK (TT_RING_MAX_MARKS - 1u)

static inline uint32_t effective_lead(const tt_ring *ring) TT_NONBLOCKING {
    uint32_t lead = atomic_load_explicit(&((tt_ring *)ring)->max_lead, memory_order_relaxed);
    return (lead == 0 || lead > ring->capacity) ? ring->capacity : lead;
}

void tt_ring_set_max_lead(tt_ring *ring, uint32_t frames) {
    uint32_t lead = (frames == 0 || frames > ring->capacity) ? ring->capacity : frames;
    atomic_store_explicit(&ring->max_lead, lead, memory_order_relaxed);
}

uint32_t tt_ring_max_lead(const tt_ring *ring) TT_NONBLOCKING { return effective_lead(ring); }

uint32_t tt_ring_lead_room(const tt_ring *ring) TT_NONBLOCKING {
    tt_ring *m = (tt_ring *)ring;
    uint64_t w = atomic_load_explicit(&m->write_index, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&m->read_index, memory_order_acquire);
    uint32_t used = (uint32_t)(w - r);
    uint32_t lead = effective_lead(ring);
    return used < lead ? lead - used : 0;
}

uint32_t tt_ring_write_clause(tt_ring *ring, const float *_Nullable src, uint32_t frames,
                              uint32_t flags, uint32_t tag) TT_NONBLOCKING {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint32_t room = tt_ring_lead_room(ring);
    uint32_t n = frames < room ? frames : room;
    bool push_start = (flags & TT_RING_CLAUSE_START) != 0 && (n > 0 || frames == 0);
    bool push_end = (flags & TT_RING_CLAUSE_END) != 0 && n == frames;
    if (push_start || push_end) {
        uint64_t mw = atomic_load_explicit(&ring->mark_write, memory_order_relaxed);
        uint64_t mr = atomic_load_explicit(&ring->mark_read, memory_order_acquire);
        uint32_t need = (push_start ? 1u : 0u) + (push_end ? 1u : 0u);
        if (mw - mr + need > TT_RING_MAX_MARKS) {
            atomic_fetch_add_explicit(&ring->mark_overflows, 1, memory_order_relaxed);
            return 0;
        }
        /* Both marks are published before the frames. The reader only trusts an END mark at
         * the write index it loaded, and a START mark at or before it, so an END published
         * early is invisible until its frames are, and is never mistaken for an underrun. */
        if (push_start) {
            ring->marks[mw & MARK_MASK] = (tt_ring_mark){ .pos = w, .tag = tag, .kind = TT_RING_CLAUSE_START };
            mw++;
        }
        if (push_end) {
            ring->marks[mw & MARK_MASK] = (tt_ring_mark){ .pos = w + n, .tag = tag, .kind = TT_RING_CLAUSE_END };
            mw++;
        }
        atomic_store_explicit(&ring->mark_write, mw, memory_order_release);
    }
    for (uint32_t i = 0; i < n; i++) {
        ring->data[(uint32_t)(w + i) & ring->mask] = src != NULL ? src[i] : 0.0f;
    }
    atomic_store_explicit(&ring->write_index, w + n, memory_order_release);
    return n;
}

void tt_ring_set_pause(tt_ring *ring, bool paused) TT_NONBLOCKING {
    atomic_store_explicit(&ring->pause_req, paused ? 1u : 0u, memory_order_release);
}

bool tt_ring_pause_requested(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->pause_req, memory_order_acquire) != 0;
}

bool tt_ring_is_parked(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->reader_state, memory_order_acquire) == TT_RING_STATE_PARKED;
}

bool tt_ring_request_jump(tt_ring *ring, uint32_t kind) TT_NONBLOCKING {
    if (kind != TT_RING_JUMP_NEXT_START && kind != TT_RING_JUMP_WRITE_INDEX) return false;
    uint64_t seq = atomic_load_explicit(&ring->jump_req_seq, memory_order_relaxed);
    uint64_t ack = atomic_load_explicit(&ring->jump_ack_seq, memory_order_acquire);
    if (seq != ack && kind != TT_RING_JUMP_WRITE_INDEX) return false;
    /* WRITE_INDEX supersedes a pending cut. Publish a consistent word/marks pair; readers
     * never wait for this writer and return silence if both bounded snapshot attempts fail. */
    atomic_store_explicit(&ring->jump_req_seq, seq + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    atomic_store_explicit(&ring->jump_req_word, (w << 2) | kind, memory_order_relaxed);
    atomic_store_explicit(&ring->jump_req_marks, atomic_load_explicit(&ring->mark_write, memory_order_relaxed),
                          memory_order_relaxed);
    atomic_store_explicit(&ring->jump_req_seq, seq + 2, memory_order_release);
    return true;
}

bool tt_ring_jump_pending(const tt_ring *ring) TT_NONBLOCKING {
    tt_ring *m = (tt_ring *)ring;
    return atomic_load_explicit(&m->jump_req_seq, memory_order_acquire) !=
           atomic_load_explicit(&m->jump_ack_seq, memory_order_acquire);
}

uint32_t tt_ring_playout_state(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->reader_state, memory_order_acquire);
}

uint64_t tt_ring_playout_underruns(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->underruns, memory_order_relaxed);
}

uint64_t tt_ring_mark_overflows(const tt_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_ring *)ring)->mark_overflows, memory_order_relaxed);
}

void tt_ring_playout_reset(tt_ring *ring) {
    uint64_t w = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    atomic_store_explicit(&ring->read_index, w, memory_order_release);
    atomic_store_explicit(&ring->mark_read, atomic_load_explicit(&ring->mark_write, memory_order_acquire),
                          memory_order_release);
    atomic_store_explicit(&ring->jump_ack_seq, atomic_load_explicit(&ring->jump_req_seq, memory_order_acquire),
                          memory_order_release);
    atomic_store_explicit(&ring->pause_req, 0, memory_order_release);
    ring->reader = (tt_ring_reader){ .state = TT_RING_STATE_IDLE };
    atomic_store_explicit(&ring->reader_state, TT_RING_STATE_IDLE, memory_order_release);
}

/* Reader view of the marks [mr, mw), only those at or before the write index w it loaded. */
typedef struct mark_view {
    uint64_t mr;
    uint64_t mw;
    uint64_t w;
} mark_view;

static inline void retire_marks(const tt_ring *ring, mark_view *v, uint64_t r) TT_NONBLOCKING {
    while (v->mr < v->mw && ring->marks[v->mr & MARK_MASK].pos < r) v->mr++;
}

/* First START mark with from <= pos <= upto. */
static bool find_start(const tt_ring *ring, const mark_view *v, uint64_t from, uint64_t upto,
                       uint64_t *pos) TT_NONBLOCKING {
    for (uint64_t k = v->mr; k < v->mw; k++) {
        const tt_ring_mark *m = &ring->marks[k & MARK_MASK];
        if (m->pos > upto || m->pos > v->w) break;
        if (m->kind == TT_RING_CLAUSE_START && m->pos >= from) {
            *pos = m->pos;
            return true;
        }
    }
    return false;
}

/* An END mark exactly at the loaded write index. */
static bool end_at_write(const tt_ring *ring, const mark_view *v) TT_NONBLOCKING {
    for (uint64_t k = v->mr; k < v->mw; k++) {
        const tt_ring_mark *m = &ring->marks[k & MARK_MASK];
        if (m->pos > v->w) break;
        if (m->pos == v->w && m->kind == TT_RING_CLAUSE_END) return true;
    }
    return false;
}

/* Copies n frames starting at r into dst with the running fade-in and (in_seg) the fade-out
 * segment's gain; records START marks whose first frame is played. */
static void reader_copy(tt_ring *ring, const mark_view *v, uint64_t r, float *dst, uint32_t n,
                        bool in_seg, bool report_starts, uint32_t out_base,
                        tt_ring_playout_report *rep) TT_NONBLOCKING {
    tt_ring_reader *rd = &ring->reader;
    for (uint32_t i = 0; i < n; i++) {
        float g = 1.0f;
        if (rd->fade_in_len != 0) {
            g *= tt_fade_in_gain(rd->fade_in_pos, rd->fade_in_len);
            if (++rd->fade_in_pos >= rd->fade_in_len) rd->fade_in_len = 0;
        }
        if (in_seg) g *= tt_fade_out_gain((uint32_t)(r + i - rd->seg_start), rd->seg_len);
        dst[i] = ring->data[(uint32_t)(r + i) & ring->mask] * g;
    }
    for (uint64_t k = v->mr; k < v->mw; k++) {
        const tt_ring_mark *m = &ring->marks[k & MARK_MASK];
        if (m->pos >= r + n || m->pos > v->w) break;
        if (m->kind != TT_RING_CLAUSE_START || m->pos < r) continue;
        rd->current_tag = m->tag;
        if (report_starts && rep->start_count < TT_RING_REPORT_MAX_STARTS) {
            rep->start_tag[rep->start_count] = m->tag;
            rep->start_offset[rep->start_count] = out_base + (uint32_t)(m->pos - r);
            rep->start_count++;
        }
    }
    rep->ring_frames += n;
    rep->audio_frames += n;
}

/* Records an event once per call, with the dst index of its first occurrence. */
static void rep_event(tt_ring_playout_report *rep, uint32_t ev, uint32_t at) TT_NONBLOCKING {
    if ((rep->events & ev) == 0) {
        switch (ev) {
        case TT_RING_EV_UNDERRUN: rep->zero_offset = at; break;
        case TT_RING_EV_RESUMED: rep->resumed_offset = at; break;
        case TT_RING_EV_ENDED: rep->ended_offset = at; break;
        case TT_RING_EV_PARKED: rep->parked_offset = at; break;
        default: rep->cut_offset = at; break;   /* EV_CUT, EV_FLUSHED */
        }
    }
    rep->events |= ev;
}

/* Moves the read index to target (never backwards) and acknowledges the jump. A jump that
 * drops the clause in progress (it moved, or the ring had run dry inside the clause) leaves
 * the reader idle; a parked reader stays parked. A WRITE_INDEX jump also drops the marks pushed
 * before the request (`marks`): a START at the request's write index belongs to the flushed
 * audio. */
static void reader_jump(tt_ring *ring, mark_view *v, uint64_t *r, uint64_t target, uint32_t kind,
                        uint64_t seq, uint64_t marks, uint32_t at, tt_ring_playout_report *rep) TT_NONBLOCKING {
    tt_ring_reader *rd = &ring->reader;
    bool moved = target > *r;
    if (moved) {
        rep->cut_dropped += (uint32_t)(target - *r);
        *r = target;
    }
    if ((moved || rd->state == TT_RING_STATE_UNDERRUN) && rd->state != TT_RING_STATE_PARKED) {
        rd->state = TT_RING_STATE_IDLE;
        rd->fade_in_len = 0;
    }
    if (kind == TT_RING_JUMP_WRITE_INDEX && v->mr < marks) v->mr = marks < v->mw ? marks : v->mw;
    rep_event(rep, kind == TT_RING_JUMP_NEXT_START ? TT_RING_EV_CUT : TT_RING_EV_FLUSHED, at);
    rep->cut_tag = rd->cut_tag;
    atomic_store_explicit(&ring->jump_ack_seq, seq, memory_order_release);
}

/* Target of a new jump request: the request's write index, or for NEXT_START the first START
 * mark between the read index and it. */
static uint64_t jump_target(const tt_ring *ring, const mark_view *v, uint64_t r, uint64_t word) TT_NONBLOCKING {
    uint32_t kind = (uint32_t)(word & 3u);
    uint64_t target = word >> 2;
    if (kind == TT_RING_JUMP_NEXT_START) {
        uint64_t p;
        if (find_start(ring, v, r, word >> 2, &p)) target = p;
    }
    return target < r ? r : target;
}

static void publish_reader(tt_ring *ring, const mark_view *v, uint64_t r) TT_NONBLOCKING {
    atomic_store_explicit(&ring->mark_read, v->mr, memory_order_release);
    atomic_store_explicit(&ring->read_index, r, memory_order_release);
    atomic_store_explicit(&ring->reader_state, ring->reader.state, memory_order_release);
}

/* A bounded seqlock snapshot: flush can supersede a pending request without exposing a
 * write-index/mark-count pair from different requests. Never spin on the real-time thread. */
typedef struct jump_request { uint64_t seq, word, marks; } jump_request;
static bool load_view(tt_ring *ring, jump_request *request, mark_view *v) TT_NONBLOCKING {
    for (uint32_t attempt = 0; attempt < 2; attempt++) {
        uint64_t seq = atomic_load_explicit(&ring->jump_req_seq, memory_order_acquire);
        if (seq & 1u) continue;
        uint64_t word = atomic_load_explicit(&ring->jump_req_word, memory_order_relaxed);
        uint64_t marks = atomic_load_explicit(&ring->jump_req_marks, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (seq != atomic_load_explicit(&ring->jump_req_seq, memory_order_relaxed)) continue;
        *request = (jump_request){ seq, word, marks };
        v->w = atomic_load_explicit(&ring->write_index, memory_order_acquire);
        v->mw = atomic_load_explicit(&ring->mark_write, memory_order_acquire);
        v->mr = atomic_load_explicit(&ring->mark_read, memory_order_relaxed);
        return true;
    }
    return false;
}

/* A WRITE_INDEX arriving during a cut takes over its destination without starting another
 * fade. Both read and suspend call this immediately before acknowledging the cut. */
static void refresh_cut(tt_ring *ring, mark_view *v, uint64_t r) TT_NONBLOCKING {
    jump_request request;
    mark_view fresh;
    if (!load_view(ring, &request, &fresh)) return;
    tt_ring_reader *rd = &ring->reader;
    if (request.seq == rd->jump_seq || (request.word & 3u) != TT_RING_JUMP_WRITE_INDEX) return;
    v->w = fresh.w; v->mw = fresh.mw;
    rd->jump_kind = TT_RING_JUMP_WRITE_INDEX;
    rd->jump_target = jump_target(ring, v, r, request.word);
    rd->jump_seq = request.seq;
    rd->jump_marks = request.marks;
}

void tt_ring_playout_suspend(tt_ring *ring, tt_ring_playout_report *_Nullable report) TT_NONBLOCKING {
    tt_ring_reader *rd = &ring->reader;
    tt_ring_playout_report local;
    tt_ring_playout_report *rep = report != NULL ? report : &local;
    *rep = (tt_ring_playout_report){ 0 };
    jump_request request;
    uint64_t jack = atomic_load_explicit(&ring->jump_ack_seq, memory_order_relaxed);
    bool pause = atomic_load_explicit(&ring->pause_req, memory_order_acquire) != 0;
    mark_view v;
    if (!load_view(ring, &request, &v)) return;
    uint64_t jseq = request.seq;
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    retire_marks(ring, &v, r);

    /* The caller faded the ring to silence: a fade-out segment in progress completes now. */
    if (rd->seg_kind != SEG_NONE) {
        uint32_t kind = rd->seg_kind;
        rd->seg_kind = SEG_NONE;
        rd->fade_in_len = 0;
        if (kind == SEG_CUT) {
            refresh_cut(ring, &v, r);
            reader_jump(ring, &v, &r, rd->jump_target, rd->jump_kind, rd->jump_seq, rd->jump_marks, 0, rep);
            rd->state = TT_RING_STATE_IDLE;
            jseq = jack = rd->jump_seq;
        } else {
            /* A hold-back fade (END or underrun) can hold the next clause's START: stop on it,
             * so that clause plays from its first frame (and reports it) when the ring is read
             * again. The clause before ended there; nothing of the next one was audible. A
             * pause fade already ends on a START; a cut drops its STARTs on purpose. */
            uint64_t p = 0;
            bool on_start = (kind == SEG_END || kind == SEG_UNDERRUN) && rd->seg_end > r &&
                            find_start(ring, &v, r, rd->seg_end - 1, &p);
            uint64_t stop_at = on_start ? p : rd->seg_end;
            if (stop_at > r) {
                rep->ring_frames += (uint32_t)(stop_at - r);
                r = stop_at;
            }
            if (on_start) {
                rd->state = TT_RING_STATE_IDLE;
                rep_event(rep, TT_RING_EV_ENDED, 0);
            } else if (kind == SEG_PAUSE) {
                rd->state = TT_RING_STATE_PARKED;
                rep_event(rep, TT_RING_EV_PARKED, 0);
            } else if (kind == SEG_END) {
                rd->state = TT_RING_STATE_IDLE;
                rep_event(rep, TT_RING_EV_ENDED, 0);
            } else {
                rd->state = TT_RING_STATE_UNDERRUN;
                atomic_fetch_add_explicit(&ring->underruns, 1, memory_order_relaxed);
                rep_event(rep, TT_RING_EV_UNDERRUN, 0);
            }
        }
        retire_marks(ring, &v, r);
    }
    /* Nothing is audible, so a new jump happens at once, without a fade. */
    if (jseq != jack) {
        uint64_t word = request.word;
        uint64_t marks = request.marks;
        uint64_t target = jump_target(ring, &v, r, word);
        rd->cut_tag = rd->current_tag;
        reader_jump(ring, &v, &r, target, (uint32_t)(word & 3u), jseq, marks, 0, rep);
        retire_marks(ring, &v, r);
    }
    if (rd->state == TT_RING_STATE_IDLE && pause) {
        rd->state = TT_RING_STATE_PARKED;
        rep_event(rep, TT_RING_EV_PARKED, 0);
    } else if (rd->state == TT_RING_STATE_PARKED && !pause) {
        rd->state = TT_RING_STATE_IDLE;
    }
    if (rd->state == TT_RING_STATE_PLAYING) {
        rd->fade_in_pos = 0;
        rd->fade_in_len = TT_RING_FADE_IN_FRAMES;
    }
    publish_reader(ring, &v, r);
}

uint32_t tt_ring_playout_read(tt_ring *ring, float *dst, uint32_t frames, uint32_t resume_frames,
                              tt_ring_playout_report *_Nullable report) TT_NONBLOCKING {
    tt_ring_reader *rd = &ring->reader;
    tt_ring_playout_report local;
    tt_ring_playout_report *rep = report != NULL ? report : &local;
    *rep = (tt_ring_playout_report){ 0 };

    /* A stable request is read before the data/mark view, which therefore covers its target. */
    jump_request request;
    uint64_t jack = atomic_load_explicit(&ring->jump_ack_seq, memory_order_relaxed);
    bool pause = atomic_load_explicit(&ring->pause_req, memory_order_acquire) != 0;
    mark_view v;
    if (!load_view(ring, &request, &v)) {
        for (uint32_t i = 0; i < frames; i++) dst[i] = 0.0f;
        return frames;
    }
    uint64_t jseq = request.seq;
    uint64_t r = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    if (resume_frames == 0) resume_frames = 1;
    /* The writer can never be more than max_lead ahead, so a larger rebuffer threshold would
     * wait for an END that the lead limit keeps from being written. */
    uint32_t lead = effective_lead(ring);
    uint32_t resume_cap = lead > TT_RING_HOLD_FRAMES ? lead - TT_RING_HOLD_FRAMES : 1u;
    if (resume_frames > resume_cap) resume_frames = resume_cap;

    uint32_t out = 0;
    for (uint32_t guard = 0; out < frames && guard < 64; guard++) {
        retire_marks(ring, &v, r);

        /* A new jump request; one in progress (SEG_CUT) or behind a running fade-out waits. */
        if (jseq != jack && rd->seg_kind == SEG_NONE) {
            uint64_t word = request.word;
            uint64_t marks = request.marks;
            uint32_t kind = (uint32_t)(word & 3u);
            uint64_t target = jump_target(ring, &v, r, word);
            rd->cut_tag = rd->current_tag;
            jack = jseq;
            if (rd->state == TT_RING_STATE_PLAYING && target > r) {
                uint64_t fade_end = r + TT_RING_CUT_FADE_FRAMES;
                if (fade_end > target) fade_end = target;
                if (fade_end > v.w) fade_end = v.w;
                rd->seg_kind = SEG_CUT;
                rd->seg_start = r;
                rd->seg_end = fade_end;
                rd->seg_len = (uint32_t)(fade_end - r);
                rd->jump_kind = kind;
                rd->jump_target = target;
                rd->jump_seq = jseq;
                rd->jump_marks = marks;
            } else {
                reader_jump(ring, &v, &r, target, kind, jseq, marks, out, rep);
            }
            continue;
        }

        if (rd->seg_kind != SEG_NONE) {
            uint64_t left = rd->seg_end > r ? rd->seg_end - r : 0;
            uint32_t n = (uint32_t)(left < (uint64_t)(frames - out) ? left : (uint64_t)(frames - out));
            reader_copy(ring, &v, r, dst + out, n, true, rd->seg_kind != SEG_CUT, out, rep);
            r += n;
            out += n;
            if (r >= rd->seg_end) {
                uint32_t kind = rd->seg_kind;
                rd->seg_kind = SEG_NONE;
                rd->fade_in_len = 0;
                switch (kind) {
                case SEG_CUT:
                    refresh_cut(ring, &v, r);
                    reader_jump(ring, &v, &r, rd->jump_target, rd->jump_kind, rd->jump_seq, rd->jump_marks, out, rep);
                    rd->state = TT_RING_STATE_IDLE;
                    jseq = jack = rd->jump_seq;   /* acknowledged: not a new request */
                    break;
                case SEG_PAUSE:
                    rd->state = TT_RING_STATE_PARKED;
                    rep_event(rep, TT_RING_EV_PARKED, out);
                    break;
                case SEG_END:
                    rd->state = TT_RING_STATE_IDLE;
                    rep_event(rep, TT_RING_EV_ENDED, out);
                    break;
                default:
                    rd->state = TT_RING_STATE_UNDERRUN;
                    atomic_fetch_add_explicit(&ring->underruns, 1, memory_order_relaxed);
                    rep_event(rep, TT_RING_EV_UNDERRUN, out);
                    break;
                }
            }
            continue;
        }

        uint64_t avail = v.w - r;
        bool stop = false;
        switch (rd->state) {
        case TT_RING_STATE_PARKED:
            if (pause) stop = true;
            else rd->state = TT_RING_STATE_IDLE;
            break;
        case TT_RING_STATE_IDLE:
            if (pause) {
                rd->state = TT_RING_STATE_PARKED;
                rep_event(rep, TT_RING_EV_PARKED, out);
                stop = true;
            } else if (avail > TT_RING_HOLD_FRAMES || (avail > 0 && end_at_write(ring, &v))) {
                rd->state = TT_RING_STATE_PLAYING;
                rd->fade_in_pos = 0;
                rd->fade_in_len = TT_RING_FADE_IN_FRAMES;
            } else {
                stop = true;
            }
            break;
        case TT_RING_STATE_UNDERRUN: {
            bool end = end_at_write(ring, &v);
            if (avail == 0 && end) {
                rd->state = TT_RING_STATE_IDLE;
                rep_event(rep, TT_RING_EV_ENDED, out);
            } else if ((avail > TT_RING_HOLD_FRAMES && avail - TT_RING_HOLD_FRAMES >= resume_frames) ||
                       (avail > 0 && end)) {
                rd->state = TT_RING_STATE_PLAYING;
                rd->fade_in_pos = 0;
                rd->fade_in_len = TT_RING_FADE_IN_FRAMES;
                rep_event(rep, TT_RING_EV_RESUMED, out);
            } else {
                stop = true;
            }
            break;
        }
        default: { /* PLAYING */
            uint64_t p = 0;
            bool has_p = pause && find_start(ring, &v, r, v.w, &p);
            if (has_p && p == r) {
                rd->state = TT_RING_STATE_PARKED;
                rd->fade_in_len = 0;
                rep_event(rep, TT_RING_EV_PARKED, out);
                break;
            }
            uint64_t lim = avail > TT_RING_HOLD_FRAMES ? v.w - TT_RING_HOLD_FRAMES : r;
            uint64_t fade_start = r;
            if (has_p) {
                fade_start = p - r > TT_RING_HOLD_FRAMES ? p - TT_RING_HOLD_FRAMES : r;
                if (fade_start < lim) lim = fade_start;
            }
            if (lim > r) {
                uint64_t left = lim - r;
                uint32_t n = (uint32_t)(left < (uint64_t)(frames - out) ? left : (uint64_t)(frames - out));
                reader_copy(ring, &v, r, dst + out, n, false, true, out, rep);
                r += n;
                out += n;
                break;
            }
            if (has_p) {
                rd->seg_kind = SEG_PAUSE;
                rd->seg_start = r;
                rd->seg_end = p;
                rd->seg_len = (uint32_t)(p - r);
                break;
            }
            /* Only the hold-back is left: fade it out. */
            bool end = end_at_write(ring, &v);
            if (avail == 0) {
                if (end) {
                    rd->state = TT_RING_STATE_IDLE;
                    rep_event(rep, TT_RING_EV_ENDED, out);
                } else {
                    rd->state = TT_RING_STATE_UNDERRUN;
                    atomic_fetch_add_explicit(&ring->underruns, 1, memory_order_relaxed);
                    rep_event(rep, TT_RING_EV_UNDERRUN, out);
                }
                break;
            }
            rd->seg_kind = end ? SEG_END : SEG_UNDERRUN;
            rd->seg_start = r;
            rd->seg_end = v.w;
            rd->seg_len = (uint32_t)avail;
            break;
        }
        }
        if (stop) break;
    }
    for (; out < frames; out++) dst[out] = 0.0f;
    retire_marks(ring, &v, r);
    publish_reader(ring, &v, r);
    return frames;
}
