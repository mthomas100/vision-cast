// The character: an "actor" entity (yaw, breath, sway live here) → a "fit" entity
// (uniform scale to 0.3 m, feet at y = 0) → one child per clip USDZ. A clip from one
// USDZ does not drive another file's entity (local-3d viewer bench, 2026-10-02), so the
// children are swapped: exactly one is enabled, each plays its own file's clip 0.
import Foundation
import RealityKit
import simd

enum Clip: String, CaseIterable {
    case idle, look, wave, hop
    /// One-shot clips are restarted from their first frame when shown.
    var isOneShot: Bool { self == .wave || self == .hop }
}

/// Resources the System needs to swap clips and chirp; one per actor.
struct CharacterComponent: Component {
    var clips: [Clip: AnimationResource] = [:]
    var durations: [Clip: Float] = [:]
    var children: [Clip: Entity] = [:]       // direct references: no name lookup of disabled entities
    var controller: AnimationPlaybackController?  // the live clip's playback, for the overlay
    var chirps: [AudioResource] = []
    var hello: AudioResource?
    var current: Clip = .idle
}

@MainActor
enum Character {
    static let height: Float = 0.3
    /// Yaw the mesh needs so its face points down +Z (0 for glTF-forward assets).
    static let forwardYawOffset: Float = 0

    static func load(named name: String) async throws -> Entity {
        let actor = Entity()
        actor.name = "actor.\(name)"
        let fit = Entity()
        fit.name = "fit"
        actor.addChild(fit)

        var character = CharacterComponent()
        var reference: Entity?
        // VC_BASE_CLIP=<clip>: the clip shown and looped at load (default idle), a diagnostic
        // for clips that do not deform when swapped in later.
        let base = ProcessInfo.processInfo.environment["VC_BASE_CLIP"].flatMap(Clip.init(rawValue:)) ?? .idle
        character.current = base
        for clip in Clip.allCases {
            guard let url = Bundle.main.url(forResource: clip.rawValue, withExtension: "usdz",
                                            subdirectory: "Characters/\(name)") else {
                print("vision-cast: no \(clip.rawValue).usdz for \(name)")
                continue
            }
            let model = try await Entity(contentsOf: url)
            model.name = "clip.\(clip.rawValue)"
            model.orientation = simd_quatf(angle: forwardYawOffset, axis: [0, 1, 0])
            forEachModel(in: model) { $0.components.set(GroundingShadowComponent(castsShadow: true)) }
            fit.addChild(model)
            character.children[clip] = model
            if let anim = model.availableAnimations.first {
                character.clips[clip] = anim
                let d = Float(anim.definition.duration)
                character.durations[clip] = d.isFinite && d > 0.1 ? d : 2
            } else {
                print("vision-cast: \(clip.rawValue).usdz has no animation")
            }
            model.isEnabled = clip == base
            if clip == base, let anim = model.availableAnimations.first {
                character.controller = model.playAnimation(anim.repeat(duration: .infinity))
            }
            if reference == nil { reference = model }
        }
        guard let reference else { throw CharacterError.noClips }

        // Fit: 0.3 m tall, centred in x/z, feet on the anchor plane.
        let b = reference.visualBounds(relativeTo: fit)
        let s = height / max(b.extents.y, 0.001)
        fit.scale = [s, s, s]
        fit.position = [-b.center.x * s, -b.min.y * s, -b.center.z * s]

        // Tappable and gaze-highlighted: a box from the fitted bounds, in actor space.
        let fb = fit.visualBounds(relativeTo: actor)
        let box = ShapeResource.generateBox(size: fb.extents).offsetBy(translation: fb.center)
        actor.components.set(CollisionComponent(shapes: [box]))
        actor.components.set(InputTargetComponent())
        actor.components.set(HoverEffectComponent())

        // The voice sits at the head and faces forward (spatial sources emit along −Z).
        let voice = Entity()
        voice.name = "voice"
        voice.position = [0, height * 0.9, 0.03]
        voice.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        voice.components.set(SpatialAudioComponent(gain: -6))
        actor.addChild(voice)
        character.chirps = Chirp.makeResources()
        character.hello = Chirp.makeHello()

        actor.components.set(character)
        actor.components.set(AliveComponent())
        return actor
    }

    /// Shows `clip` alone and (re)starts its animation on the child that owns it, from
    /// the first frame: one loop for a one-shot clip, forever for the others.
    static func show(_ clip: Clip, on actor: Entity, loops: Int = 1) {
        guard var character = actor.components[CharacterComponent.self],
              let child = character.children[clip] else { return }
        for (c, e) in character.children { e.isEnabled = c == clip }
        if let anim = character.clips[clip] {
            let d = Double(character.durations[clip] ?? 2)
            let resource = clip.isOneShot ? (loops > 1 ? anim.repeat(duration: d * Double(loops)) : anim)
                                          : anim.repeat(duration: .infinity)
            character.controller = child.playAnimation(resource, transitionDuration: 0.15, startsPaused: false)
        }
        character.current = clip
        actor.components.set(character)
    }

    /// "clip: wave t=0.8/2.0 playing" for the overlay.
    static func clipStatus(_ actor: Entity) -> String {
        guard let c = actor.components[CharacterComponent.self] else { return "—" }
        let d = c.durations[c.current] ?? 0
        guard let ctrl = c.controller else { return "\(c.current.rawValue) (no controller)" }
        let t = d > 0 ? ctrl.time.truncatingRemainder(dividingBy: Double(d)) : ctrl.time
        return String(format: "%@ t=%.1f/%.1f %@%@", c.current.rawValue, t, d,
                      ctrl.isPlaying ? "playing" : "stopped", ctrl.isComplete ? " done" : "")
    }

    static func chirp(_ actor: Entity, hello: Bool = false) {
        guard let character = actor.components[CharacterComponent.self],
              let voice = actor.findEntity(named: "voice"),
              let sound = hello ? character.hello : character.chirps.randomElement() else { return }
        voice.playAudio(sound)
    }

    /// The actor above a tapped entity (the tap lands on a model child).
    static func actor(of entity: Entity) -> Entity? {
        var e: Entity? = entity
        while let cur = e {
            if cur.components.has(AliveComponent.self) { return cur }
            e = cur.parent
        }
        return nil
    }

    private static func forEachModel(in e: Entity, _ body: (Entity) -> Void) {
        if e.components.has(ModelComponent.self) { body(e) }
        for c in e.children { forEachModel(in: c, body) }
    }

    enum CharacterError: Error { case noClips }
}
