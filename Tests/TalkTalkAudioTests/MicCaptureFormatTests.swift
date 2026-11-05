import CoreAudio
import Testing
@testable import TalkTalkAudio

@Suite struct MicCaptureFormatTests {
    private var format: MicCapture.InputFormat {
        .init(streamIDs: [12], channelsPerBuffer: [1], formats: [
            AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        ])
    }

    @Test func sameFormatNotificationDoesNotInterruptCapture() {
        let initial = format
        var announced = initial
        announced.formats[0].mReserved = 99
        #expect(MicCapture.formatInterruption(previous: initial, current: announced) == nil)
    }

    @Test func actualChangesAndFailedReadsStillInterruptCapture() {
        let initial = format
        var changes: [MicCapture.InputFormat] = []
        var value = initial; value.streamIDs = [13]; changes.append(value)
        value = initial; value.channelsPerBuffer = [0, 1]; changes.append(value)
        value = initial; value.formats[0].mSampleRate = 44_100; changes.append(value)
        value = initial; value.formats[0].mFormatID = kAudioFormatAppleLossless; changes.append(value)
        value = initial; value.formats[0].mFormatFlags ^= kAudioFormatFlagIsNonInterleaved; changes.append(value)
        value = initial; value.formats[0].mBytesPerPacket = 8; changes.append(value)
        value = initial; value.formats[0].mFramesPerPacket = 2; changes.append(value)
        value = initial; value.formats[0].mBytesPerFrame = 8; changes.append(value)
        value = initial; value.formats[0].mChannelsPerFrame = 2; changes.append(value)
        value = initial; value.formats[0].mBitsPerChannel = 16; changes.append(value)
        for changed in changes {
            #expect(MicCapture.formatInterruption(previous: initial, current: changed) == .formatChanged)
        }
        #expect(MicCapture.formatInterruption(previous: initial, current: nil) == .formatChanged)
        #expect(MicCapture.formatInterruption(previous: nil, current: initial) == .formatChanged)
    }
}
