// WaveDetector: a pure function over a short ring buffer of hand samples. No ARKit or
// RealityKit here so it also builds as a SwiftPM target on macOS for `swift test`.
//
// A wave is: the wrist above shoulder height (wrist y > head y − 0.35 m) AND the palm
// facing the character (palm normal · direction from wrist to the lamp > 0.3; a wave at
// something has the palm toward it, away from your own face) AND the wrist's lateral
// position (projected on the head's right vector) crossing its running mean at least
// 3 times within 1.2 s with a peak-to-peak amplitude ≥ 6 cm. One detection per 4 s.
import Foundation
import simd

struct HandSample {
    var t: Float               // seconds, monotonic
    var wrist: SIMD3<Float>    // world
    var palmNormal: SIMD3<Float>
    var head: SIMD3<Float>
    var headRight: SIMD3<Float>
    var target: SIMD3<Float>   // the character; the palm must face it
}

struct WaveDetector {
    enum State: String { case none, raised, waving }

    static let window: Float = 1.5           // seconds of history kept
    static let crossingWindow: Float = 1.2   // seconds in which the crossings must happen
    static let minCrossings = 3
    static let minAmplitude: Float = 0.06    // metres, peak to peak
    static let shoulderDrop: Float = 0.35    // wrist must be above head y − this
    static let minPalmDot: Float = 0.3
    static let debounce: Float = 4

    private(set) var state: State = .none
    private(set) var crossings = 0
    private(set) var amplitude: Float = 0
    private(set) var wristHeight: Float = 0  // relative to the head
    private(set) var palmDot: Float = 0      // palm normal · direction to the character
    private var samples: [(t: Float, lateral: Float, raised: Bool)] = []
    private var lastFired: Float = -100

    /// Feeds one sample; returns true once per wave (debounced).
    mutating func update(_ s: HandSample) -> Bool {
        wristHeight = s.wrist.y - s.head.y
        let toTarget = s.target - s.wrist
        palmDot = simd_length(toTarget) > 0.01 ? simd_dot(simd_normalize(s.palmNormal), simd_normalize(toTarget)) : 0
        let raised = wristHeight > -Self.shoulderDrop && palmDot > Self.minPalmDot
        samples.append((s.t, simd_dot(s.wrist, s.headRight), raised))
        samples.removeAll { s.t - $0.t > Self.window }

        let recent = samples.filter { s.t - $0.t <= Self.crossingWindow }
        crossings = 0
        amplitude = 0
        if recent.count >= 4 {
            let mean = recent.map(\.lateral).reduce(0, +) / Float(recent.count)
            amplitude = recent.map(\.lateral).max()! - recent.map(\.lateral).min()!
            var side = recent[0].lateral >= mean
            for r in recent.dropFirst() {
                let now = r.lateral >= mean
                if now != side { crossings += 1; side = now }
            }
        }
        let allRaised = recent.allSatisfy(\.raised) && !recent.isEmpty
        let waving = raised && allRaised && crossings >= Self.minCrossings && amplitude >= Self.minAmplitude
        state = waving ? .waving : (raised ? .raised : .none)
        guard waving, s.t - lastFired > Self.debounce else { return false }
        lastFired = s.t
        return true
    }

    /// Called when the hand is not tracked this frame.
    mutating func lost() {
        state = .none
        crossings = 0
        amplitude = 0
        samples.removeAll()
    }
}
