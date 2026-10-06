// Behaviour chooser: a tiny utility scorer (Dave Mark, GDC 2015) over {idle, glance,
// wave} with cooldown curves and noise, so idle breaks have legible intent but never
// a fixed rhythm. Called only when the idle-break timer fires, never per frame.
import Foundation

enum Act: String {
    case idle, glance, wave
}

struct Chooser {
    var lastGlance: Float = -100
    var lastWave: Float = -100
    /// Unprompted waves are rare so that a wave from him means "I saw you": the next one
    /// is allowed only after a randomized 3–5 min, re-rolled after each.
    var waveCooldown: Float = Float.random(in: 180...300)

    /// `now` is the actor's own clock (s); `distance` the head distance in m, if known.
    mutating func choose(now: Float, distance: Float?) -> Act {
        let near = distance.map { max(0, min(1, (2.5 - $0) / 2)) } ?? 0.3 // 1 at ≤0.5 m, 0 at ≥2.5 m
        var scores: [(Act, Float)] = [
            (.idle, 0.35 + noise()),
            (.glance, 0.6 * cooldown(now - lastGlance, 6) + noise()),
            (.wave, now - lastWave < waveCooldown ? 0 : (0.25 + 0.5 * near) + noise()),
        ]
        scores.sort { $0.1 > $1.1 }
        let pick = scores[0].0
        switch pick {
        case .glance: lastGlance = now
        case .wave:
            lastWave = now
            waveCooldown = Float.random(in: 180...300)
        case .idle: break
        }
        return pick
    }

    /// 0 right after the act, back to 1 after `period` seconds (eased).
    private func cooldown(_ since: Float, _ period: Float) -> Float {
        let t = max(0, min(1, since / period))
        return t * t * (3 - 2 * t)
    }

    private func noise() -> Float { Float.random(in: 0..<0.15) }
}
