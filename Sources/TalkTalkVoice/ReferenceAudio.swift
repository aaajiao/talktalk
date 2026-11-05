import AVFoundation
import Foundation

/// §9.2 step 5: turn an accepted take into `reference.wav` — leading silence trimmed to 150 ms,
/// 0.5 s of silence appended, speech RMS normalized to −20 dBFS, 24 kHz mono PCM16.
/// Internal pauses are kept as spoken (the 400 ms compression of §9.1 is for timing only).
public enum ReferenceAudio {
    public static let outputSampleRate = 24_000.0
    public static let leadSeconds = 0.15
    /// Kept after the last speech frame so the final syllable's decay is not cut.
    public static let releaseSeconds = 0.10
    public static let tailSilenceSeconds = 0.5
    public static let targetRmsDbfs = -20.0
    /// The gain is reduced if it would push the peak above this.
    public static let peakCeilingDbfs = -1.0
    static let fadeSeconds = 0.01

    public struct Output: Sendable {
        /// 24 kHz mono, ready for `WAVFile.encodePCM16`.
        public let samples: [Float]
        public let gainDb: Double
        public var durationSeconds: Double { Double(samples.count) / outputSampleRate }
    }

    public static func make(take: [Float], sampleRate: Double, segmentation seg: SpeechSegmentation) throws -> Output {
        guard let range = seg.speechSampleRange else { throw Failure.noSpeech }
        let start = max(0, range.lowerBound - Int(leadSeconds * sampleRate))
        let end = min(take.count, range.upperBound + Int(releaseSeconds * sampleRate))
        var x = Array(take[start..<end])

        // Gain: speech RMS → −20 dBFS, capped so the peak stays ≤ −1 dBFS.
        let rmsDb = Levels.dbfs(seg.speechRMS)
        let peakDb = Levels.dbfs(Levels.peak(x[...]))
        var gainDb = targetRmsDbfs - rmsDb
        if peakDb + gainDb > peakCeilingDbfs { gainDb = peakCeilingDbfs - peakDb }
        let g = Float(Levels.linear(gainDb))
        for i in x.indices { x[i] *= g }

        // Short fades so the cut points don't click.
        let fade = min(x.count / 2, Int(fadeSeconds * sampleRate))
        if fade > 0 {
            if start > 0 { for i in 0..<fade { x[i] *= Float(i) / Float(fade) } }
            for i in 0..<fade { x[x.count - 1 - i] *= Float(i) / Float(fade) }
        }

        var y = try Resampler.resample(x, from: sampleRate, to: outputSampleRate)
        y.append(contentsOf: [Float](repeating: 0, count: Int(tailSilenceSeconds * outputSampleRate)))
        return Output(samples: y, gainDb: gainDb)
    }

    public enum Failure: Error, Equatable { case noSpeech, converter }
}

public enum Resampler {
    /// Offline sample-rate conversion with AVAudioConverter at maximum quality.
    public static func resample(_ x: [Float], from: Double, to: Double) throws -> [Float] {
        if from == to || x.isEmpty { return x }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count))
        else { throw ReferenceAudio.Failure.converter }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: x.count)
        }
        let capacity = AVAudioFrameCount(Double(x.count) * to / from) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw ReferenceAudio.Failure.converter
        }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let source = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else { throw ReferenceAudio.Failure.converter }
        let n = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: n))
    }
}

/// Minimal RIFF/WAVE PCM16 mono reader and writer.
public enum WAVFile {
    public static func encodePCM16(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for v in samples {
            let clamped = max(-1, min(1, v))
            let q = Int16((clamped * 32767).rounded())
            u16(UInt16(bitPattern: q))
        }
        return data
    }

    public struct Decoded: Sendable, Equatable {
        public let samples: [Float]
        public let sampleRate: Int
    }

    public static func decodePCM16(_ data: Data) -> Decoded? {
        let b = [UInt8](data)
        guard b.count >= 44, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        var offset = 12
        var rate = 0
        var ok = false
        while offset + 8 <= b.count {
            let id = String(decoding: b[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard u16(body) == 1, u16(body + 2) == 1, u16(body + 14) == 16 else { return nil }
                rate = Int(u32(body + 4))
                ok = true
            } else if id == "data", ok {
                let end = min(b.count, body + size)
                var out = [Float]()
                out.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    out.append(Float(Int16(bitPattern: u16(i))) / 32767)
                    i += 2
                }
                return Decoded(samples: out, sampleRate: rate)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
