// Holden's critically damped spring (theorangeduck.com/page/spring-roll-call,
// "spring_damper_exact" with damping ratio 1): velocity-continuous smoothing with
// two knobs. Every pose target in AliveSystem goes through one of these.
import Foundation

struct Spring {
    var x: Float
    var v: Float = 0
    /// Natural frequency in Hz; ~2 Hz reads as a head turning, not a servo.
    var frequency: Float = 2

    init(_ x: Float, frequency: Float = 2) {
        self.x = x
        self.frequency = frequency
    }

    mutating func step(target: Float, dt: Float) {
        let w = 2 * Float.pi * frequency
        let j0 = x - target
        let j1 = v + j0 * w
        let e = exp(-w * dt)
        x = e * (j0 + j1 * dt) + target
        v = e * (v - j1 * w * dt)
    }

    /// Angles: pulls the target into the half-turn nearest to the current value first.
    mutating func stepAngle(target: Float, dt: Float) {
        step(target: x + wrapAngle(target - x), dt: dt)
    }
}

/// Wraps an angle into [-π, π].
func wrapAngle(_ a: Float) -> Float {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r > .pi { r -= 2 * .pi }
    if r < -.pi { r += 2 * .pi }
    return r
}
