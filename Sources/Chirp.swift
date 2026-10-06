// The character's voice: three tiny synthesized chirps (0.15 s sine with a pitch slide
// under a raised-cosine envelope), built in code as AVAudioPCMBuffers and wrapped in
// AudioBufferResources so they play spatially from the head emitter. No audio files.
import AVFAudio
import RealityKit

enum Chirp {
    /// (start Hz, end Hz) per variant; a rising, a falling and a two-note "huh?".
    static let variants: [(Float, Float)] = [(880, 1480), (1320, 920), (1040, 1040)]
    /// The "hello!" for waving back: a longer, brighter two-step rise.
    static let hello: (Float, Float) = (660, 1760)

    @MainActor
    static func makeHello() -> AudioResource? {
        guard let b = buffer(from: hello.0, to: hello.1, wobble: true, seconds: 0.28) else { return nil }
        return try? AudioBufferResource(buffer: b, configuration: .init(shouldLoop: false))
    }

    @MainActor
    static func makeResources() -> [AudioResource] {
        variants.enumerated().compactMap { i, v in
            guard let buffer = buffer(from: v.0, to: v.1, wobble: i == 2) else { return nil }
            return try? AudioBufferResource(buffer: buffer, configuration: .init(shouldLoop: false))
        }
    }

    static func buffer(from f0: Float, to f1: Float, wobble: Bool, seconds: Float = 0.15,
                       sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let n = AVAudioFrameCount(seconds * Float(sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = n
        var phase: Float = 0
        for i in 0..<Int(n) {
            let t = Float(i) / Float(n)                       // 0…1 through the chirp
            var f = f0 + (f1 - f0) * t
            if wobble { f *= 1 + 0.08 * sin(2 * .pi * 18 * t) } // a quick trill
            phase += 2 * .pi * f / Float(sampleRate)
            let env = 0.5 * (1 - cos(2 * .pi * t))            // Hann: no clicks
            out[i] = 0.35 * env * (sin(phase) + 0.25 * sin(2 * phase))
        }
        return buf
    }
}
