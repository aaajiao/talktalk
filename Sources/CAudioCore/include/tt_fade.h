#ifndef TT_FADE_H
#define TT_FADE_H

/* Fade shapes shared by every ring and IOProc in CAudioCore (ARCHITECTURE.md §3.3, §3.8).
 * Linear ramps, defined exactly so tests can compare sample by sample:
 *   fade-in  over len frames: gain(i) = i / len            (first frame 0, then 1 after the ramp)
 *   fade-out over len frames: gain(i) = (len - 1 - i) / len (last frame 0, then 0 after the ramp)
 * fade_out(i, len) == fade_in(len - 1 - i, len). When two fades overlap their gains multiply. */

#include <stdint.h>
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

static inline float tt_fade_in_gain(uint32_t i, uint32_t len) TT_NONBLOCKING {
    if (len == 0 || i >= len) return 1.0f;
    return (float)i / (float)len;
}

static inline float tt_fade_out_gain(uint32_t i, uint32_t len) TT_NONBLOCKING {
    if (len == 0 || i >= len) return 0.0f;
    return (float)(len - 1u - i) / (float)len;
}

#ifdef __cplusplus
}
#endif

#endif
