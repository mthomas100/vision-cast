// What the app knows about the room: the head pose (WorldTrackingProvider, no prompt)
// and, when the user grants world sensing, every horizontal plane ARKit detects
// (PlaneDetectionProvider). Both run in one ARKitSession, which needs a Full Space
// (the mixed ImmersiveSpace qualifies).
import ARKit
import Foundation
import QuartzCore
import simd

/// One detected horizontal plane, in world space.
struct PlaneInfo: Identifiable {
    var id: UUID
    var classification: PlaneAnchor.Classification
    var originFromAnchor: simd_float4x4
    var anchorFromExtent: simd_float4x4
    var width: Float      // extent along the plane's X
    var depth: Float      // extent along the plane's Z (ARKit calls it height)

    var center: SIMD3<Float> {
        let m = originFromAnchor * anchorFromExtent
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
    var minExtent: Float { min(width, depth) }
    var isTable: Bool { classification == .table }
    var label: String {
        switch classification {
        case .table: "table"
        case .floor: "floor"
        case .seat: "seat"
        case .ceiling: "ceiling"
        case .wall: "wall"
        case .window: "window"
        case .door: "door"
        default: "unknown"
        }
    }
}

@MainActor
final class SpaceTracker {
    static let shared = SpaceTracker()

    private let session = ARKitSession()
    private let world = WorldTrackingProvider()
    private var planeProvider: PlaneDetectionProvider?
    private var handProvider: HandTrackingProvider?
    private var planeTask: Task<Void, Never>?
    private var started = false

    /// nil until asked; false when the user declined world sensing (AnchorEntity fallback).
    private(set) var worldSensingAllowed: Bool?
    private(set) var handTrackingAllowed: Bool?
    private(set) var authorizationNote = ""

    private(set) var planes: [UUID: PlaneInfo] = [:]
    /// Bumped on every plane change so observers can poll cheaply.
    private(set) var planeRevision = 0

    func start() async {
        guard !started, WorldTrackingProvider.isSupported else { return }
        started = true
        var providers: [any DataProvider] = [world]
        var wanted: [ARKitSession.AuthorizationType] = []
        if PlaneDetectionProvider.isSupported { wanted.append(.worldSensing) }
        if HandTrackingProvider.isSupported { wanted.append(.handTracking) }
        let auth = wanted.isEmpty ? [:] : await session.requestAuthorization(for: wanted)
        if HandTrackingProvider.isSupported {
            handTrackingAllowed = auth[.handTracking] == .allowed
            if handTrackingAllowed == true {
                let h = HandTrackingProvider()
                handProvider = h
                providers.append(h)
            }
        } else {
            handTrackingAllowed = false
        }
        if PlaneDetectionProvider.isSupported {
            worldSensingAllowed = auth[.worldSensing] == .allowed
            authorizationNote = "worldSensing: \(auth[.worldSensing].map { "\($0)" } ?? "nil")"
            print("vision-cast: \(authorizationNote); handTracking: \(auth[.handTracking].map { "\($0)" } ?? "nil")")
            if worldSensingAllowed == true {
                let p = PlaneDetectionProvider(alignments: [.horizontal])
                planeProvider = p
                providers.append(p)
            }
        } else if ProcessInfo.processInfo.environment["VC_FAKE_PLANE"] == "1" {
            // Simulator aid: PlaneDetectionProvider is unsupported there, so fake a floor and a
            // table 1 m ahead at 0.75 m, which exercises Placer, the colliders and the overlay.
            worldSensingAllowed = true
            authorizationNote = "fake planes (VC_FAKE_PLANE)"
            print("vision-cast: \(authorizationNote)")
            fakePlanes()
        } else {
            worldSensingAllowed = false
            authorizationNote = "plane detection unsupported here"
            print("vision-cast: \(authorizationNote)")
        }
        do {
            try await session.run(providers)
        } catch {
            print("vision-cast: ARKit session failed: \(error)")
            started = false
            return
        }
        if let p = planeProvider {
            planeTask = Task { [weak self] in
                for await update in p.anchorUpdates {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(update)
                }
            }
        }
    }

    private func apply(_ update: AnchorUpdate<PlaneAnchor>) {
        let a = update.anchor
        switch update.event {
        case .removed:
            planes[a.id] = nil
        case .added, .updated:
            guard a.alignment == .horizontal else { return }
            let e = a.geometry.extent
            planes[a.id] = PlaneInfo(id: a.id, classification: a.classification,
                                     originFromAnchor: a.originFromAnchorTransform,
                                     anchorFromExtent: e.anchorFromExtentTransform,
                                     width: e.width, depth: e.height)
        }
        planeRevision += 1
    }

    private func fakePlanes() {
        func plane(_ c: PlaneAnchor.Classification, at p: SIMD3<Float>, _ w: Float, _ d: Float) -> PlaneInfo {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(p.x, p.y, p.z, 1)
            return PlaneInfo(id: UUID(), classification: c, originFromAnchor: m,
                             anchorFromExtent: matrix_identity_float4x4, width: w, depth: d)
        }
        for p in [plane(.floor, at: [0, 0, -1], 3, 3), plane(.table, at: [0, 0.75, -1.2], 0.8, 0.6),
                  plane(.seat, at: [1, 0.45, -1], 0.5, 0.5)] {
            planes[p.id] = p
        }
        planeRevision += 1
    }

    func stop() {
        planeTask?.cancel()
        planeTask = nil
        session.stop()
        planes = [:]
        planeProvider = nil
        handProvider = nil
        started = false
    }

    var isRunning: Bool { world.state == .running }

    /// The tracked hands this frame, as WaveDetector samples (nil entries: not tracked).
    /// Palm normal = cross(index metacarpal − wrist, little metacarpal − wrist), which points
    /// out of the palm for the right hand; mirrored for the left.
    func hands(head: simd_float4x4, target: SIMD3<Float>, t: Float) -> (left: HandSample?, right: HandSample?) {
        guard let hp = handProvider, hp.state == .running else { return (nil, nil) }
        let anchors = hp.latestAnchors
        let headPos = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let headRight = simd_normalize(SIMD3(head.columns.0.x, 0, head.columns.0.z))
        func sample(_ a: HandAnchor?) -> HandSample? {
            guard let a, a.isTracked, let sk = a.handSkeleton else { return nil }
            func world(_ j: HandSkeleton.JointName) -> SIMD3<Float> {
                let m = a.originFromAnchorTransform * sk.joint(j).anchorFromJointTransform
                return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            }
            let wrist = world(.wrist)
            var n = simd_cross(world(.indexFingerMetacarpal) - wrist, world(.littleFingerMetacarpal) - wrist)
            if a.chirality == .left { n = -n }
            guard simd_length(n) > 1e-6 else { return nil }
            return HandSample(t: t, wrist: wrist, palmNormal: simd_normalize(n), head: headPos, headRight: headRight, target: target)
        }
        return (sample(anchors.leftHand), sample(anchors.rightHand))
    }

    /// The device (head) transform in world space, or nil before tracking is up.
    func headTransform() -> simd_float4x4? {
        guard isRunning else { return nil }
        return world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }

    func headPosition() -> SIMD3<Float>? {
        headTransform().map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
    }
}
