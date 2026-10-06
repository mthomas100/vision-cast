// Drives the app's own Spring.swift and Behaviour.swift (compiled alongside) to dump
// chart data: spring step responses and the idle-break picks over simulated hours.
// From the repo root (writes the CSVs into docs/data):
//   swiftc -O Sources/Spring.swift Sources/Behaviour.swift docs/sim/main.swift -o /tmp/vc-sim
//   (cd docs/data && /tmp/vc-sim)
// The Chooser is random, so a rerun gives slightly different numbers.
import Foundation

// 1. Spring step responses: yaw spring (2 Hz) 0 → 1 rad, squash spring (6 Hz) 1 → 0.9.
var out = "t,yaw_2hz,squash_6hz\n"
var yaw = Spring(0, frequency: 2)
var sq = Spring(1, frequency: 6)
let dt: Float = 1.0 / 90
var t: Float = 0
while t <= 1.0 {
    out += String(format: "%.4f,%.5f,%.5f\n", t, yaw.x, sq.x)
    yaw.step(target: 1, dt: dt)
    sq.step(target: 0.9, dt: dt)
    t += dt
}
try! out.write(toFile: "spring.csv", atomically: true, encoding: .utf8)

// 2. Idle breaks as AliveSystem runs them: a timer re-rolled in 8–20 s while idle; a
// look or wave plays its 2 s clip before idle resumes. User standing 1.0 m away, no taps.
var ev = "run,t_s,pick\n"
for run in 0..<100 {
    var c = Chooser()
    var now: Float = 0
    while now < 3600 {
        now += Float.random(in: 8...20)
        let pick = c.choose(now: now, distance: 1.0)
        ev += "\(run),\(String(format: "%.2f", now)),\(pick.rawValue)\n"
        if pick != .idle { now += 2 }
    }
}
try! ev.write(toFile: "breaks.csv", atomically: true, encoding: .utf8)

// 3. Unprompted waves per hour against the user's distance (50 simulated hours each).
var sweep = "distance_m,waves_per_hour,looks_per_hour,stays_per_hour\n"
for d in stride(from: Float(0.5), through: 3.0, by: 0.25) {
    var n: [Act: Int] = [:]
    for _ in 0..<50 {
        var c = Chooser()
        var now: Float = 0
        while now < 3600 {
            now += Float.random(in: 8...20)
            let pick = c.choose(now: now, distance: d)
            n[pick, default: 0] += 1
            if pick != .idle { now += 2 }
        }
    }
    sweep += String(format: "%.2f,%.2f,%.2f,%.2f\n", d, Float(n[.wave] ?? 0) / 50, Float(n[.glance] ?? 0) / 50, Float(n[.idle] ?? 0) / 50)
}
try! sweep.write(toFile: "distance.csv", atomically: true, encoding: .utf8)
