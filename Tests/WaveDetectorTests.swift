import XCTest
import simd
@testable import VisionCastCore

final class WaveDetectorTests: XCTestCase {
    let head = SIMD3<Float>(0, 1.5, 0)
    let right = SIMD3<Float>(1, 0, 0)
    let lamp = SIMD3<Float>(0, 0.9, -1.2)   // on a table in front of the user

    /// Feeds `seconds` of a hand at 60 Hz; `lateral(t)` gives the x offset of the wrist.
    func run(_ d: inout WaveDetector, seconds: Float, wristY: Float, palmTowardLamp: Bool = true,
             lateral: (Float) -> Float) -> Int {
        var fired = 0
        var t: Float = 0
        while t < seconds {
            let wrist = SIMD3<Float>(0.3 + lateral(t), wristY, -0.4)
            let toLamp = simd_normalize(lamp - wrist)
            // Palm toward the lamp (a wave at it); the mirror case is the palm toward one's own face.
            let s = HandSample(t: t, wrist: wrist, palmNormal: palmTowardLamp ? toLamp : -toLamp,
                               head: head, headRight: right, target: lamp)
            if d.update(s) { fired += 1 }
            t += 1 / 60
        }
        return fired
    }

    func testWaveAboveShoulderFires() {
        var d = WaveDetector()
        // ±8 cm at 2 Hz: 4 mean crossings per second, well over 3 in 1.2 s.
        let fired = run(&d, seconds: 3, wristY: 1.35) { 0.08 * sin(2 * .pi * 2 * $0) }
        XCTAssertEqual(fired, 1, "one debounced detection in 3 s")
        XCTAssertEqual(d.state, .waving)
        XCTAssertGreaterThanOrEqual(d.crossings, 3)
        XCTAssertGreaterThanOrEqual(d.amplitude, 0.06)
    }

    func testDebounceAllowsSecondWaveAfterFourSeconds() {
        var d = WaveDetector()
        let fired = run(&d, seconds: 9, wristY: 1.35) { 0.08 * sin(2 * .pi * 2 * $0) }
        XCTAssertEqual(fired, 3, "t≈0.6, ≈4.6, ≈8.6 s")
    }

    func testStaticRaisedHandIsRaisedNotWaving() {
        var d = WaveDetector()
        let fired = run(&d, seconds: 3, wristY: 1.35) { _ in 0 }
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(d.state, .raised)
    }

    func testLowHandDoesNotCount() {
        var d = WaveDetector()
        let fired = run(&d, seconds: 3, wristY: 0.9) { 0.08 * sin(2 * .pi * 2 * $0) }
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(d.state, .none)
    }

    func testPalmTowardOwnFaceDoesNotCount() {
        var d = WaveDetector()
        let fired = run(&d, seconds: 3, wristY: 1.35, palmTowardLamp: false) { 0.08 * sin(2 * .pi * 2 * $0) }
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(d.state, .none)
    }

    func testSmallJitterDoesNotCount() {
        var d = WaveDetector()
        // 2 cm peak to peak: crosses the mean often but is under the 6 cm amplitude floor.
        let fired = run(&d, seconds: 3, wristY: 1.35) { 0.01 * sin(2 * .pi * 3 * $0) }
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(d.state, .raised)
    }

    func testSlowSingleSwingDoesNotCount() {
        var d = WaveDetector()
        // One swing across in 1.2 s: a single crossing.
        let fired = run(&d, seconds: 1.3, wristY: 1.35) { 0.1 * sin(2 * .pi * 0.4 * $0) }
        XCTAssertEqual(fired, 0)
    }

    func testSpringSettlesCritically() {
        var s = Spring(0, frequency: 2)
        var overshoot: Float = 0
        for _ in 0..<240 {
            s.step(target: 1, dt: 1 / 60)
            overshoot = max(overshoot, s.x - 1)
        }
        XCTAssertEqual(s.x, 1, accuracy: 0.001)
        XCTAssertEqual(overshoot, 0, accuracy: 0.0001, "critical damping never overshoots")
    }
}
