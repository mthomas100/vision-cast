// The mixed immersive space. With world sensing granted, Placer puts the actor on a
// detected plane (ARKit PlaneDetectionProvider) and keeps an invisible collider per
// plane for tap-to-place. If the user declines, a table AnchorEntity with a 3 s floor
// fallback is used instead (no permission needed). Taps on the character wave.
import Foundation
import SwiftUI
import RealityKit

struct StageView: View {
    @State private var stage = Stage()
    private var placer = AppModel.shared.placer

    var body: some View {
        RealityView { content in
            await SpaceTracker.shared.start()
            do {
                let actor = try await Character.load(named: "lamp")
                let world = Entity()
                world.name = "world"
                content.add(world)
                stage.actor = actor
                stage.world = world
                if SpaceTracker.shared.worldSensingAllowed == true {
                    placer.actor = actor
                    placer.world = world
                    placer.unlock()
                    AppModel.shared.placementMode = "plane detection"
                } else {
                    let anchor = AnchorEntity(.plane(.horizontal, classification: .table, minimumBounds: [0.3, 0.3]))
                    anchor.addChild(actor)
                    content.add(anchor)
                    stage.anchor = anchor
                    stage.subscription = content.subscribe(to: SceneEvents.AnchoredStateChanged.self, on: anchor) { event in
                        if event.isAnchored {
                            AppModel.shared.tableFound = true
                            AppModel.shared.lastEvent = "table found"
                        }
                    }
                    AppModel.shared.placementMode = "table anchor (\(SpaceTracker.shared.authorizationNote))"
                }
            } catch {
                print("vision-cast: character load failed: \(error)")
                AppModel.shared.state = "load failed: \(error)"
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    if let actor = Character.actor(of: value.entity),
                       var alive = actor.components[AliveComponent.self] {
                        alive.pokeRequested = true
                        actor.components.set(alive)
                    } else if value.entity.name.hasPrefix("plane.") {
                        let p = value.convert(value.location3D, from: .local, to: .scene)
                        placer.placeByTap(at: p, on: value.entity)
                    }
                }
        )
        .task {
            // Placement loop (plane mode) or the one-shot floor fallback (anchor mode).
            var waited: Float = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 0.25
                if placer.actor != nil {
                    placer.tick(dt: 0.25)
                } else if waited >= Placer.fallbackAfter {
                    stage.fallbackIfNoTable()
                }
            }
        }
        .onDisappear {
            placer.actor = nil
            placer.world = nil
            placer.planeColliders = [:]
            SpaceTracker.shared.stop()
        }
    }
}

@Observable @MainActor
final class Stage {
    var actor: Entity?
    var anchor: AnchorEntity?
    var world: Entity?
    var subscription: EventSubscription?

    /// Anchor mode only: moves the actor off the (unfound) table anchor to 1 m in front of the head.
    func fallbackIfNoTable() {
        guard let actor, let anchor, let world, !anchor.isAnchored, AppModel.shared.tableFound != true,
              actor.parent === anchor else { return }
        let y = Placer.fallbackY()
        var position = SIMD3<Float>(0, y, -1)
        if let head = SpaceTracker.shared.headTransform() {
            let forward = -SIMD3(head.columns.2.x, 0, head.columns.2.z)
            let dir = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, -1)
            position = SIMD3(head.columns.3.x, y, head.columns.3.z) + dir
        }
        actor.removeFromParent()
        actor.position = position
        world.addChild(actor)
        anchor.removeFromParent()
        AppModel.shared.tableFound = false
        AppModel.shared.lastEvent = String(format: "no table; placed at %.1f, %.1f", position.x, position.z)
    }
}
