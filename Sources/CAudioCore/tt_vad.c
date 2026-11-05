#include "tt_vad.h"

#include "third_party/libfvad/include/fvad.h"

#include <math.h>
#include <stdlib.h>

struct tt_vad {
    Fvad *fvad;
    int mode;
    int rate;
    int16_t buf[TT_VAD_MAX_FRAME];
};

tt_vad *_Nullable tt_vad_create(int mode, int sample_rate) {
    /* libfvad's 48 kHz path looks only at the first 10 ms of each frame (tt_vad.h). */
    if (sample_rate != 8000 && sample_rate != 16000 && sample_rate != 32000) return NULL;
    tt_vad *vad = calloc(1, sizeof(tt_vad));
    if (vad == NULL) return NULL;
    vad->fvad = fvad_new();
    if (vad->fvad == NULL || fvad_set_mode(vad->fvad, mode) != 0 ||
        fvad_set_sample_rate(vad->fvad, sample_rate) != 0) {
        if (vad->fvad != NULL) fvad_free(vad->fvad);
        free(vad);
        return NULL;
    }
    vad->mode = mode;
    vad->rate = sample_rate;
    return vad;
}

void tt_vad_destroy(tt_vad *_Nullable vad) {
    if (vad == NULL) return;
    fvad_free(vad->fvad);
    free(vad);
}

int tt_vad_set_mode(tt_vad *vad, int mode) {
    if (fvad_set_mode(vad->fvad, mode) != 0) return -1;
    vad->mode = mode;
    return 0;
}

void tt_vad_reset(tt_vad *vad) {
    /* fvad_reset also resets mode and rate to their defaults; restore ours. */
    fvad_reset(vad->fvad);
    fvad_set_mode(vad->fvad, vad->mode);
    fvad_set_sample_rate(vad->fvad, vad->rate);
}

int tt_vad_sample_rate(const tt_vad *vad) { return vad->rate; }

int tt_vad_process_i16(tt_vad *vad, const int16_t *frame, size_t frames) {
    return fvad_process(vad->fvad, frame, frames);
}

int tt_vad_process_f32(tt_vad *vad, const float *frame, size_t frames) {
    if (frames > TT_VAD_MAX_FRAME) return -1;
    for (size_t i = 0; i < frames; i++) {
        float x = frame[i];
        if (!(x > -1.0f)) x = -1.0f;   /* NaN → -1 as well */
        if (x > 1.0f) x = 1.0f;
        vad->buf[i] = (int16_t)lrintf(x * 32767.0f);
    }
    return fvad_process(vad->fvad, vad->buf, frames);
}

float tt_vad_rms_dbfs(const float *frame, size_t frames) {
    if (frames == 0) return -120.0f;
    double acc = 0.0;
    for (size_t i = 0; i < frames; i++) acc += (double)frame[i] * (double)frame[i];
    if (acc <= 0.0) return -120.0f;
    double db = 10.0 * log10(acc / (double)frames);
    return db < -120.0 ? -120.0f : (float)db;
}
