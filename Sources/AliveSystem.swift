// AliveSystem: the per-frame layer that keeps the character from ever looking frozen.
//   look-at   yaw toward the head through a critically damped spring, with glances
//             (a random offset re-rolled every 2–5 s and a dwell) and a ±70° clamp
//   micro     breath as a ±2 % Y scale at 0.25 Hz, sway ±1.5° at 0.1 Hz, on the actor
//   breaks    a randomized idle-break timer (8–20 s) → Chooser → glance or wave
//   reactions tap → anticipation squash (80 ms through the spring) → wave + chirp;
//             "noticed you" when the head comes within 1.2 m after being farther
import RealityKit
import simd

struct AliveComponent: Component {
    enum State: Equatable {
        case idle
        case anticipate(remaining: Float)   // squash, then wave
        case crouch(remaining: Float)       // squash, then hop (after a placement)
        case wave(remaining: Float)
        case waveBack(remaining: Float)     // the user waved: face the hand, wave, hello chirp
        case hop(remaining: Float)
        case glance(remaining: Float)       // the "look" clip for one loop
    }

    var t: Float = 0
    var state: State = .idle
    var placed = false
    var baseYaw: Float = 0
    var yaw = Spring(0, frequency: 2)
    var squash = Spring(1, frequency: 6)
    var glanceOffset: Float = 0
    var glanceTimer: Float = 2
    var breakTimer: Float = Float.random(in: 8...20)
    var chooser = Chooser()
    var pokeRequested = false
    var hopRequested = false            // set by Placer after a move: squash, then the hop clip
    var leftWave = WaveDetector()
    var rightWave = WaveDetector()
    var lookAt: SIMD3<Float>?           // world point that overrides the head as look target…
    var lookAtUntil: Float = -1         // …until this actor time
    var wasFar = false   // set once the head has been > 1.5 m away; the first approach then waves
    var lastNoticed: Float = -100
    var debugTimer: Float = 0
}

@MainActor
struct AliveSystem: System {
    static let query = EntityQuery(where: .has(AliveComponent.self) && .has(CharacterComponent.self))

    static let maxYaw: Float = 70 * .pi / 180
    static let noticeDistance: Float = 1.2
    static let noticeCooldown: Float = 20

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(min(context.deltaTime, 0.1))
        let headTransform = SpaceTracker.shared.headTransform()
        let head = headTransform.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        for actor in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var a = actor.components[AliveComponent.self] else { continue }
            a.t += dt
            if let headTransform { watchHands(&a, actor: actor, head: headTransform) }
            step(&a, actor: actor, head: head, dt: dt)
            actor.components.set(a)
        }
    }

    /// Feeds both hands to their WaveDetectors; a detected wave starts the wave-back.
    private func watchHands(_ a: inout AliveComponent, actor: Entity, head: simd_float4x4) {
        let lamp = actor.position(relativeTo: nil) + SIMD3(0, Character.height * 0.6, 0)
        let hands = SpaceTracker.shared.hands(head: head, target: lamp, t: a.t)
        var waved: (String, SIMD3<Float>)?
        if let s = hands.left { if a.leftWave.update(s) { waved = ("left", s.wrist) } } else { a.leftWave.lost() }
        if let s = hands.right { if a.rightWave.update(s) { waved = ("right", s.wrist) } } else { a.rightWave.lost() }
        if let (which, wrist) = waved {
            startWaveBack(&a, actor: actor, at: wrist, event: "you waved (\(which)) → waving back")
        }
        let model = AppModel.shared
        let states = [a.leftWave.state, a.rightWave.state]
        model.hand = states.contains(.waving) ? "waving" : (states.contains(.raised) ? "raised" : "none")
        if hands.left == nil && hands.right == nil { model.hand = "none (no hands tracked)" }
        func line(_ d: WaveDetector, _ tracked: Bool) -> String {
            tracked ? String(format: "wrist %+.2f m palm %+.2f ×%d %.0f cm", d.wristHeight, d.palmDot, d.crossings, d.amplitude * 100) : "—"
        }
        model.handDebug = "L " + line(a.leftWave, hands.left != nil) + "  R " + line(a.rightWave, hands.right != nil)
    }

    private func step(_ a: inout AliveComponent, actor: Entity, head: SIMD3<Float>?, dt: Float) {
        // --- look-at ---------------------------------------------------------------
        var distance: Float?
        var yawToHead: Float?
        if let head, let parent = actor.parent {
            let local = parent.convert(position: head, from: nil) - actor.position
            distance = simd_length(local)
            yawToHead = atan2(local.x, local.z)
        }
        if a.t < a.lookAtUntil, let p = a.lookAt, let parent = actor.parent {
            // Looking at the waving hand instead of the head for a moment.
            let local = parent.convert(position: p, from: nil) - actor.position
            yawToHead = atan2(local.x, local.z)
        }
        if !a.placed, let y = yawToHead {
            // The placed orientation: facing wherever the user stood when the lamp appeared.
            a.baseYaw = y
            a.yaw = Spring(y, frequency: 2)
            a.placed = true
        }
        a.glanceTimer -= dt
        if a.glanceTimer <= 0 {
            // Dwell: most re-rolls look straight at you; the rest drift a little.
            a.glanceOffset = Float.random(in: 0..<1) < 0.6 ? 0 : Float.random(in: -0.2...0.2)
            a.glanceTimer = Float.random(in: 2...5)
        }
        let target = (yawToHead ?? a.baseYaw) + a.glanceOffset
        let clamped = a.baseYaw + max(-Self.maxYaw, min(Self.maxYaw, wrapAngle(target - a.baseYaw)))
        a.yaw.stepAngle(target: clamped, dt: dt)

        // --- reactions ------------------------------------------------------------
        if let d = distance {
            if d > Self.noticeDistance + 0.3 { a.wasFar = true }
            if d < Self.noticeDistance, a.wasFar, a.t - a.lastNoticed > Self.noticeCooldown, a.state == .idle {
                a.wasFar = false
                a.lastNoticed = a.t
                a.chooser.lastWave = a.t
                startWave(&a, actor: actor, event: "noticed you")
            }
        }
        if AppModel.shared.waveRequested {
            AppModel.shared.waveRequested = false
            startWaveBack(&a, actor: actor, at: nil, event: "Wave button → waving")
        }
        if a.hopRequested {
            a.hopRequested = false
            a.state = .crouch(remaining: 0.08)
        }
        if a.pokeRequested {
            a.pokeRequested = false
            if a.state == .idle {
                a.state = .anticipate(remaining: 0.08)
                a.chooser.lastWave = a.t
                AppModel.shared.lastEvent = "tapped"
            }
        }

        // --- state machine ----------------------------------------------------------
        var squashTarget: Float = 1
        switch a.state {
        case .idle:
            a.breakTimer -= dt
            if a.breakTimer <= 0 {
                a.breakTimer = Float.random(in: 8...20)
                switch a.chooser.choose(now: a.t, distance: distance) {
                case .wave: startWave(&a, actor: actor, event: "idle break: wave")
                case .glance:
                    a.state = .glance(remaining: duration(.look, actor) ?? 2)
                    Character.show(.look, on: actor)
                    AppModel.shared.lastEvent = "idle break: look around"
                case .idle: AppModel.shared.lastEvent = "idle break: stay"
                }
            }
        case .anticipate(let remaining):
            squashTarget = 0.9
            if remaining - dt <= 0 {
                startWave(&a, actor: actor, event: "wave")
            } else {
                a.state = .anticipate(remaining: remaining - dt)
            }
        case .crouch(let remaining):
            squashTarget = 0.85
            if remaining - dt <= 0 {
                a.state = .hop(remaining: duration(.hop, actor) ?? 2)
                Character.show(.hop, on: actor)
                Character.chirp(actor)
                AppModel.shared.lastEvent = "placed: hop"
            } else {
                a.state = .crouch(remaining: remaining - dt)
            }
        case .wave(let remaining):
            if remaining - dt <= 0 { backToIdle(&a, actor: actor) } else { a.state = .wave(remaining: remaining - dt) }
        case .hop(let remaining):
            if remaining - dt <= 0 { backToIdle(&a, actor: actor) } else { a.state = .hop(remaining: remaining - dt) }
        case .waveBack(let remaining):
            if remaining - dt <= 0 { backToIdle(&a, actor: actor) } else { a.state = .waveBack(remaining: remaining - dt) }
        case .glance(let remaining):
            if remaining - dt <= 0 { backToIdle(&a, actor: actor) } else { a.state = .glance(remaining: remaining - dt) }
        }
        a.squash.step(target: squashTarget, dt: dt)

        // --- compose the transform ---------------------------------------------------
        let breath = 1 + 0.02 * sin(2 * .pi * 0.25 * a.t)
        let sway = (1.5 * .pi / 180) * sin(2 * .pi * 0.1 * a.t)
        // While a wave clip plays the arm does the work; the body only leans 4° toward you.
        var lean: Float = 0
        if let (remaining, total) = waveProgress(a) {
            let elapsed = total - remaining
            lean = (4 * .pi / 180) * min(1, elapsed / 0.3) * min(1, remaining / 0.4)
        }
        actor.scale = [1, breath * a.squash.x, 1]
        actor.orientation = simd_quatf(angle: a.yaw.x, axis: [0, 1, 0])
            * simd_quatf(angle: lean, axis: [1, 0, 0])
            * simd_quatf(angle: sway, axis: [0, 0, 1])

        // --- debug overlay (5 Hz) -----------------------------------------------------
        a.debugTimer -= dt
        if a.debugTimer <= 0 {
            a.debugTimer = 0.2
            let model = AppModel.shared
            model.state = describe(a.state)
            model.clip = Character.clipStatus(actor)
            model.distance = distance
            model.headTracking = head != nil
        }
    }

    static let waveBackLoops: Float = 2   // the user's wave earns two loops; tap/idle break one

    /// (remaining, total) while a wave clip is the live one.
    private func waveProgress(_ a: AliveComponent) -> (Float, Float)? {
        switch a.state {
        case .wave(let r): return (r, 2)
        case .waveBack(let r): return (r, 2 * Self.waveBackLoops)
        default: return nil
        }
    }

    /// The wave-back: look at `point` (or the head), the wave clip twice, the hello chirp.
    /// Allowed from idle and from a glance; a wave already playing is left alone.
    private func startWaveBack(_ a: inout AliveComponent, actor: Entity, at point: SIMD3<Float>?, event: String) {
        switch a.state {
        case .idle, .glance: break
        default: return
        }
        let loops = Int(Self.waveBackLoops)
        let total = max(duration(.wave, actor) ?? 2, 2) * Self.waveBackLoops
        a.lookAt = point
        a.lookAtUntil = point == nil ? -1 : a.t + total
        a.state = .waveBack(remaining: total)
        Character.show(.wave, on: actor, loops: loops)
        Character.chirp(actor, hello: true)
        AppModel.shared.lastEvent = event
    }

    private func startWave(_ a: inout AliveComponent, actor: Entity, event: String) {
        a.state = .wave(remaining: duration(.wave, actor) ?? 2)
        Character.show(.wave, on: actor)
        Character.chirp(actor)
        AppModel.shared.lastEvent = event
    }

    private func backToIdle(_ a: inout AliveComponent, actor: Entity) {
        a.state = .idle
        Character.show(.idle, on: actor)
    }

    private func duration(_ clip: Clip, _ actor: Entity) -> Float? {
        actor.components[CharacterComponent.self]?.durations[clip]
    }

    private func describe(_ s: AliveComponent.State) -> String {
        switch s {
        case .idle: "idle"
        case .anticipate, .crouch: "anticipate"
        case .wave(let r): String(format: "wave (%.1f s)", r)
        case .hop(let r): String(format: "hop (%.1f s)", r)
        case .waveBack(let r): String(format: "waving back (%.1f s)", r)
        case .glance(let r): String(format: "look around (%.1f s)", r)
        }
    }
}
