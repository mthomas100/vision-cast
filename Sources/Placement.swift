// Placement: picks a surface for the lamp from the detected planes and keeps an
// invisible tappable collider per plane so the user can point at where it should stand.
//
// Auto rule: prefer a plane classified .table; else any horizontal plane 0.25–1.2 m
// above the floor (the lowest .floor plane, or head height − 1.6 m before one is seen)
// with both extents ≥ 0.25 m; nearest to the user wins. The lamp stands at the plane's
// centre pushed toward the user by up to 0.25 m, facing them. Auto-placement re-evaluates
// for 10 s (planes grow as the user looks around), then locks until "Re-place".
import Foundation
import RealityKit
import simd

struct Candidate {
    var plane: PlaneInfo
    var distance: Float
    var heightAboveFloor: Float
}

@Observable @MainActor
final class Placer {
    static let window: Float = 10       // seconds of auto re-evaluation
    static let fallbackAfter: Float = 3 // seconds before the floor fallback

    var actor: Entity?
    var world: Entity?
    var planeColliders: [UUID: Entity] = [:]

    var locked = false
    var chosen: UUID?
    var reason = "—"
    var placedOnFloor = false
    var elapsed: Float = 0
    var rows: [String] = []
    var hint = ""
    private var lastRevision = -1

    func unlock() {
        locked = false
        chosen = nil
        placedOnFloor = false
        elapsed = 0
        reason = "re-placing"
    }

    /// Called every tick (~0.25 s) while the space is open.
    func tick(dt: Float) {
        elapsed += dt
        let tracker = SpaceTracker.shared
        let head = tracker.headPosition()
        syncColliders(tracker.planes)
        let candidates = evaluate(planes: Array(tracker.planes.values), head: head)
        rows = describe(planes: Array(tracker.planes.values), head: head)
        hint = candidates.isEmpty && !locked ? "look around the table for a few seconds" : ""
        guard !locked, let actor, let world else { return }

        if let best = candidates.first {
            if chosen != best.plane.id || !placedOnFloor && elapsed < Self.window {
                let pos = standPoint(on: best.plane, toward: head)
                place(actor, at: pos, in: world, hop: chosen != best.plane.id)
                chosen = best.plane.id
                placedOnFloor = false
                reason = String(format: "%@ %.2f m up, %.1f m away%@", best.plane.label,
                                best.heightAboveFloor, best.distance,
                                best.plane.isTable ? "" : " (not a table, but table height)")
                AppModel.shared.tableFound = true
            }
            if elapsed >= Self.window {
                locked = true
                reason += " · locked"
            }
        } else if !placedOnFloor, elapsed >= Self.fallbackAfter {
            // Nothing qualifies yet: the floor fallback, still updating.
            var pos = SIMD3<Float>(0, 0, -1)
            if let h = tracker.headTransform() {
                let forward = -SIMD3(h.columns.2.x, 0, h.columns.2.z)
                let dir = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, -1)
                pos = SIMD3(h.columns.3.x, Self.fallbackY(), h.columns.3.z) + dir
            }
            place(actor, at: pos, in: world, hop: false)
            placedOnFloor = true
            chosen = nil
            reason = "no table-height plane yet → floor, 1 m ahead"
            AppModel.shared.tableFound = false
        }
    }

    /// A tap on a plane collider: stand there, facing the user, and lock.
    func placeByTap(at scenePoint: SIMD3<Float>, on planeEntity: Entity) {
        guard let actor, let world else { return }
        place(actor, at: scenePoint, in: world, hop: true)
        locked = true
        placedOnFloor = false
        chosen = planeColliders.first { $0.value == planeEntity }?.key
        reason = "tapped · locked"
        AppModel.shared.tableFound = true
        AppModel.shared.lastEvent = String(format: "placed by tap at %.2f, %.2f, %.2f", scenePoint.x, scenePoint.y, scenePoint.z)
    }

    // MARK: - rules

    func evaluate(planes: [PlaneInfo], head: SIMD3<Float>?) -> [Candidate] {
        let floorY = planes.filter { $0.classification == .floor }.map(\.center.y).min()
            ?? (head.map { $0.y - 1.6 } ?? 0)
        var out: [Candidate] = []
        for p in planes {
            let h = p.center.y - floorY
            guard p.minExtent >= 0.25, h >= 0.25, h <= 1.2 else { continue }
            let d = head.map { simd_length(p.center - $0) } ?? 99
            out.append(Candidate(plane: p, distance: d, heightAboveFloor: h))
        }
        out.sort {
            if $0.plane.isTable != $1.plane.isTable { return $0.plane.isTable }
            return $0.distance < $1.distance
        }
        return out
    }

    /// The plane centre pushed toward the head by up to 0.25 m, kept 5 cm inside the extent.
    func standPoint(on p: PlaneInfo, toward head: SIMD3<Float>?) -> SIMD3<Float> {
        let c = p.center
        guard let head else { return c }
        var toHead = SIMD3(head.x - c.x, 0, head.z - c.z)
        guard simd_length(toHead) > 0.01 else { return c }
        toHead = simd_normalize(toHead)
        // The plane's local axes in world space, to clamp the push inside the extent.
        let m = p.originFromAnchor * p.anchorFromExtent
        let ax = simd_normalize(SIMD3(m.columns.0.x, 0, m.columns.0.z))
        let az = simd_normalize(SIMD3(m.columns.2.x, 0, m.columns.2.z))
        let halfX = max(0, p.width / 2 - 0.05), halfZ = max(0, p.depth / 2 - 0.05)
        let dx = abs(simd_dot(toHead, ax)), dz = abs(simd_dot(toHead, az))
        var limit: Float = 0.25
        if dx > 0.001 { limit = min(limit, halfX / dx) }
        if dz > 0.001 { limit = min(limit, halfZ / dz) }
        return c + toHead * limit
    }

    private func place(_ actor: Entity, at pos: SIMD3<Float>, in world: Entity, hop: Bool) {
        if actor.parent !== world {
            actor.removeFromParent()
            world.addChild(actor)
        } else if simd_length(actor.position - pos) < 0.02, !hop {
            return                        // a growing plane nudged the centre by < 2 cm: stay put
        }
        actor.position = pos
        if var alive = actor.components[AliveComponent.self] {
            alive.placed = false          // re-face the user from the new spot
            if hop { alive.hopRequested = true }
            actor.components.set(alive)
        }
    }

    // MARK: - colliders and overlay

    private func syncColliders(_ planes: [UUID: PlaneInfo]) {
        guard let world, SpaceTracker.shared.planeRevision != lastRevision else { return }
        lastRevision = SpaceTracker.shared.planeRevision
        for (id, e) in planeColliders where planes[id] == nil {
            e.removeFromParent()
            planeColliders[id] = nil
        }
        for (id, p) in planes {
            let e = planeColliders[id] ?? {
                let e = Entity()
                e.name = "plane.\(id.uuidString)"
                e.components.set(InputTargetComponent())
                world.addChild(e)
                planeColliders[id] = e
                return e
            }()
            e.setTransformMatrix(p.originFromAnchor, relativeTo: world)
            let box = ShapeResource.generateBox(size: [p.width, 0.01, p.depth])
            let ext = Transform(matrix: p.anchorFromExtent)
            e.components.set(CollisionComponent(shapes: [box.offsetBy(rotation: ext.rotation, translation: ext.translation)]))
        }
    }

    private func describe(planes: [PlaneInfo], head: SIMD3<Float>?) -> [String] {
        let floorY = planes.filter { $0.classification == .floor }.map(\.center.y).min()
            ?? (head.map { $0.y - 1.6 } ?? 0)
        return planes.sorted { $0.center.y > $1.center.y }.map { p in
            let d = head.map { simd_length(p.center - $0) }
            let mark = p.id == chosen ? "▶ " : "  "
            return String(format: "%@%-7@ %+.2f m  %.2f×%.2f m  %@", mark, p.label, p.center.y - floorY,
                          p.width, p.depth, d.map { String(format: "%.1f m", $0) } ?? "")
        }
    }

    static func fallbackY() -> Float {
        Float(ProcessInfo.processInfo.environment["VC_FALLBACK_Y"] ?? "0") ?? 0
    }
}
