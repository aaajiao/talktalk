#include "tt_envelope.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define POINT_MASK (TT_ENVELOPE_POINTS - 1u)
_Static_assert((TT_ENVELOPE_POINTS & (TT_ENVELOPE_POINTS - 1)) == 0, "points: power of two");

/* One history slot with its own sequence lock: tag = 2 * seq + 1 while the producer writes it,
 * 2 * seq + 2 once point `seq` is complete. */
typedef struct env_slot {
    _Atomic uint64_t tag;
    _Atomic uint64_t host;
    _Atomic uint32_t rms_bits;
    _Atomic uint32_t peak_bits;
} env_slot;

struct tt_envelope {
    uint32_t window;
    double tpf;
    /* producer-private accumulator */
    double acc_sq;
    float acc_peak;
    uint32_t acc_n;
    uint64_t acc_host;
    uint64_t next_host;     /* expected host time of the next pushed frame */
    uint32_t have_next;
    _Alignas(128) _Atomic uint64_t count;   /* points published */
    _Alignas(128) _Atomic uint64_t lost;
    env_slot slots[TT_ENVELOPE_POINTS];
};

static inline uint32_t f2u(float f) TT_NONBLOCKING {
    union { float f; uint32_t u; } x = { .f = f };
    return x.u;
}

static inline float u2f(uint32_t u) TT_NONBLOCKING {
    union { float f; uint32_t u; } x = { .u = u };
    return x.f;
}

tt_envelope *_Nullable tt_envelope_create(uint32_t window_frames, double host_ticks_per_frame) {
    if (window_frames == 0 || !(host_ticks_per_frame > 0.0)) return NULL;
    tt_envelope *env = NULL;
    if (posix_memalign((void **)&env, 128, sizeof(tt_envelope)) != 0 || env == NULL) return NULL;
    memset(env, 0, sizeof(*env));
    env->window = window_frames;
    env->tpf = host_ticks_per_frame;
    atomic_init(&env->count, 0);
    atomic_init(&env->lost, 0);
    for (uint32_t i = 0; i < TT_ENVELOPE_POINTS; i++) {
        atomic_init(&env->slots[i].tag, 0);
        atomic_init(&env->slots[i].host, 0);
        atomic_init(&env->slots[i].rms_bits, 0);
        atomic_init(&env->slots[i].peak_bits, 0);
    }
    return env;
}

void tt_envelope_destroy(tt_envelope *_Nullable env) { free(env); }

static void publish_point(tt_envelope *env) TT_NONBLOCKING {
    uint64_t seq = atomic_load_explicit(&env->count, memory_order_relaxed);
    env_slot *slot = &env->slots[seq & POINT_MASK];
    float rms = (float)__builtin_sqrt(env->acc_sq / (double)env->window);
    atomic_store_explicit(&slot->tag, 2 * seq + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&slot->host, env->acc_host, memory_order_relaxed);
    atomic_store_explicit(&slot->rms_bits, f2u(rms), memory_order_relaxed);
    atomic_store_explicit(&slot->peak_bits, f2u(env->acc_peak), memory_order_relaxed);
    atomic_store_explicit(&slot->tag, 2 * seq + 2, memory_order_release);
    atomic_store_explicit(&env->count, seq + 1, memory_order_release);
}

void tt_envelope_push(tt_envelope *env, const float *_Nullable src, uint32_t frames, uint32_t stride,
                      uint64_t host_ticks) TT_NONBLOCKING {
    if (frames == 0) return;
    if (stride == 0) stride = 1;
    if (env->have_next && env->acc_n > 0) {
        uint64_t d = host_ticks > env->next_host ? host_ticks - env->next_host : env->next_host - host_ticks;
        if ((double)d > 0.5 * (double)env->window * env->tpf) env->acc_n = 0;   /* time jump */
    }
    for (uint32_t i = 0; i < frames; i++) {
        if (env->acc_n == 0) {
            env->acc_sq = 0.0;
            env->acc_peak = 0.0f;
            env->acc_host = host_ticks + (uint64_t)((double)i * env->tpf + 0.5);
        }
        float x = src != NULL ? src[(size_t)i * stride] : 0.0f;
        env->acc_sq += (double)x * (double)x;
        float ax = x < 0.0f ? -x : x;
        if (ax > env->acc_peak) env->acc_peak = ax;
        if (++env->acc_n == env->window) {
            publish_point(env);
            env->acc_n = 0;
        }
    }
    env->next_host = host_ticks + (uint64_t)((double)frames * env->tpf + 0.5);
    env->have_next = 1;
}

uint64_t tt_envelope_count(const tt_envelope *env) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_envelope *)env)->count, memory_order_acquire);
}

uint64_t tt_envelope_lost_points(const tt_envelope *env) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_envelope *)env)->lost, memory_order_relaxed);
}

/* Reads point `seq` if its slot still holds it. */
static bool read_point(tt_envelope *env, uint64_t seq, tt_envelope_point *dst) TT_NONBLOCKING {
    env_slot *slot = &env->slots[seq & POINT_MASK];
    uint64_t t1 = atomic_load_explicit(&slot->tag, memory_order_acquire);
    if (t1 != 2 * seq + 2) return false;
    uint64_t host = atomic_load_explicit(&slot->host, memory_order_relaxed);
    uint32_t rms = atomic_load_explicit(&slot->rms_bits, memory_order_relaxed);
    uint32_t peak = atomic_load_explicit(&slot->peak_bits, memory_order_relaxed);
    atomic_thread_fence(memory_order_acquire);
    uint64_t t2 = atomic_load_explicit(&slot->tag, memory_order_relaxed);
    if (t2 != t1) return false;
    *dst = (tt_envelope_point){ .seq = seq, .host_ticks = host, .rms = u2f(rms), .peak = u2f(peak) };
    return true;
}

/* Oldest point that is safe to read: the producer may be overwriting count - POINTS. */
static inline uint64_t oldest_readable(uint64_t count) TT_NONBLOCKING {
    return count > TT_ENVELOPE_POINTS - 1 ? count - (TT_ENVELOPE_POINTS - 1) : 0;
}

uint32_t tt_envelope_read(tt_envelope *env, uint64_t *cursor, tt_envelope_point *dst, uint32_t max) TT_NONBLOCKING {
    uint64_t count = atomic_load_explicit(&env->count, memory_order_acquire);
    uint64_t oldest = oldest_readable(count);
    uint64_t c = *cursor;
    uint64_t lost = 0;
    if (c < oldest) {
        lost += oldest - c;
        c = oldest;
    }
    uint32_t n = 0;
    while (n < max && c < count) {
        if (read_point(env, c, &dst[n])) n++;
        else lost++;   /* overwritten while we copied */
        c++;
    }
    *cursor = c;
    if (lost) atomic_fetch_add_explicit(&env->lost, lost, memory_order_relaxed);
    return n;
}

uint32_t tt_envelope_read_recent(tt_envelope *env, tt_envelope_point *dst, uint32_t max) TT_NONBLOCKING {
    uint64_t count = atomic_load_explicit(&env->count, memory_order_acquire);
    uint64_t oldest = oldest_readable(count);
    uint64_t start = count - (count - oldest < max ? count - oldest : max);
    uint32_t n = 0;
    for (uint64_t c = start; c < count; c++) {
        if (read_point(env, c, &dst[n])) n++;
    }
    return n;
}
