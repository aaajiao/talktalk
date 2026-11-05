/* feedprobe: the driver gate's negative test (ARCHITECTURE.md §8.3 "客户端门禁", §8.4 校验 3).
 *
 * A bare Mach-O (no bundle, so the HAL reports a NULL bundle id) that tries to start IO on
 * TalkTalk Feed and write a tone. The driver must refuse it: AudioDeviceStart fails ('what' on
 * the client side, M0-T8) or no IO cycle runs. scripts/build-app.sh builds it into
 * Contents/Resources/driver/feedprobe; DriverSelfTest runs it and reads Test Mic meanwhile.
 *
 * It writes only Feed channel 2 (self-test → Test Mic); channel 1 (→ TalkTalk Mic, the
 * meeting) always gets zeros, so even a broken gate never puts the tone into a meeting.
 *
 *   feedprobe [--uid com.aaajiao.talktalk.feed] [--ms 800] [--ttmm]
 *
 * --ttmm (M2): also try to write the Feed's meeting-mode switch 'ttmm'. The probe reads the
 * current value and writes the same value back, so even a broken gate changes nothing; the
 * driver must refuse the write (the caller is not an accepted Feed client).
 *
 * Prints one JSON line: {"found":…,"createStatus":…,"startStatus":…,"ioCycles":…,"refused":…}
 * plus "ttmmRead"/"ttmmStatus" with --ttmm.
 * Exit 0 when the probe ran (refused or not; the caller judges), 2 on usage errors. */

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../../Driver/Sources/Generated/DriverPins.h" /* TT_PINS_*: from scripts/lib/versions.sh */

static _Atomic uint64_t g_cycles;

static OSStatus probe_ioproc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                             const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime,
                             void *ctx) {
    (void)dev; (void)now; (void)in; (void)inTime; (void)ctx;
    if (out == NULL || out->mNumberBuffers == 0) return noErr;
    AudioBuffer *b = &out->mBuffers[0];
    if (b->mData == NULL || b->mNumberChannels == 0) return noErr;
    const UInt32 ch = b->mNumberChannels;
    const UInt32 frames = b->mDataByteSize / (UInt32)(sizeof(float) * ch);
    float *f = (float *)b->mData;
    const double s0 = outTime->mSampleTime;
    for (UInt32 i = 0; i < frames; i++) {
        const float v = (float)(0.25 * sin(2.0 * M_PI * 997.0 * (s0 + i) / 48000.0));
        for (UInt32 k = 0; k < ch; k++) f[(size_t)i * ch + k] = (k == 1) ? v : 0.0f;
    }
    atomic_fetch_add(&g_cycles, 1);
    return noErr;
}

static AudioObjectID device_for_uid(const char *uid) {
    CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID dev = kAudioObjectUnknown;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(dev);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(s), &s, &size, &dev);
    CFRelease(s);
    return st == noErr ? dev : kAudioObjectUnknown;
}

int main(int argc, char **argv) {
    const char *uid = TT_PINS_FEED_UID;
    int ms = 800;
    int ttmm = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--uid") == 0 && i + 1 < argc) {
            uid = argv[++i];
        } else if (strcmp(argv[i], "--ms") == 0 && i + 1 < argc) {
            ms = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--ttmm") == 0) {
            ttmm = 1;
        } else {
            fprintf(stderr, "usage: feedprobe [--uid UID] [--ms N] [--ttmm]\n");
            return 2;
        }
    }
    if (ms < 100 || ms > 5000) ms = 800;
    AudioObjectID feed = device_for_uid(uid);
    OSStatus createStatus = 0, startStatus = 0;
    AudioDeviceIOProcID proc = NULL;
    if (feed != kAudioObjectUnknown) {
        createStatus = AudioDeviceCreateIOProcID(feed, probe_ioproc, NULL, &proc);
        if (createStatus == noErr) {
            startStatus = AudioDeviceStart(feed, proc);
            usleep((useconds_t)ms * 1000);
            AudioDeviceStop(feed, proc);
            AudioDeviceDestroyIOProcID(feed, proc);
        }
    }
    const uint64_t cycles = atomic_load(&g_cycles);
    const int refused = feed == kAudioObjectUnknown || createStatus != noErr || startStatus != noErr || cycles == 0;
    printf("{\"found\":%s,\"createStatus\":%d,\"startStatus\":%d,\"ioCycles\":%llu,\"refused\":%s",
           feed != kAudioObjectUnknown ? "true" : "false", (int)createStatus, (int)startStatus,
           (unsigned long long)cycles, refused ? "true" : "false");
    if (ttmm) {
        /* 'ttmm' is a CFNumber (custom properties are CFString / CFPropertyList only). */
        OSStatus readStatus = kAudioHardwareBadDeviceError, writeStatus = kAudioHardwareBadDeviceError;
        if (feed != kAudioObjectUnknown) {
            AudioObjectPropertyAddress a = {TT_PINS_MEETING_MODE_SELECTOR, kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
            CFPropertyListRef v = NULL;
            UInt32 size = sizeof(v);
            readStatus = AudioObjectGetPropertyData(feed, &a, 0, NULL, &size, &v);
            if (readStatus == noErr && v != NULL) {
                writeStatus = AudioObjectSetPropertyData(feed, &a, 0, NULL, sizeof(v), &v);
                CFRelease(v);
            }
        }
        printf(",\"ttmmRead\":%d,\"ttmmStatus\":%d", (int)readStatus, (int)writeStatus);
    }
    printf("}\n");
    return 0;
}
