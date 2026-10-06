// vision-cast v0: a launcher window and a mixed immersive space in which one m3d
// character (the lamp robot) stands on the real table and is kept alive by
// AliveSystem (look-at through a spring, breath, idle breaks, tap-to-wave, chirps).
import SwiftUI
import RealityKit

@main
struct VisionCastApp: App {
    @State private var immersion: ImmersionStyle = .mixed

    init() {
        AliveComponent.registerComponent()
        CharacterComponent.registerComponent()
        AliveSystem.registerSystem()
    }

    var body: some SwiftUI.Scene {
        WindowGroup(id: "launcher") {
            LauncherView()
        }
        .defaultSize(width: 560, height: 620)

        ImmersiveSpace(id: "stage") {
            StageView()
        }
        .immersionStyle(selection: $immersion, in: .mixed)
    }
}

/// Debug state shared between the System (writer) and the launcher window (reader).
@Observable @MainActor
final class AppModel {
    static let shared = AppModel()
    var isPlaced = false
    var state = "—"
    var distance: Float?
    /// nil while searching, true on a table anchor, false after the fallback placement.
    var tableFound: Bool?
    var headTracking = false
    var lastEvent = ""
    var placementMode = "—"
    var hand = "—"
    var clip = "—"
    var waveRequested = false
    var handDebug = ""
    let placer = Placer()
}

struct LauncherView: View {
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    private var model = AppModel.shared

    /// Env VC_AUTO_PLACE=1 (SIMCTL_CHILD_VC_AUTO_PLACE in the simulator) opens the space on
    /// launch, so a scripted run needs no tap.
    private var autoPlace: Bool { ProcessInfo.processInfo.environment["VC_AUTO_PLACE"] == "1" }

    var body: some View {
        content.task {
            if autoPlace, !model.isPlaced { await place() }
            // VC_AUTO_WAVE=<seconds>: press "Wave" that long after launch (scripted simulator check).
            if let s = ProcessInfo.processInfo.environment["VC_AUTO_WAVE"].flatMap({ Double($0) }) {
                try? await Task.sleep(for: .seconds(s))
                model.waveRequested = true
            }
        }
    }

    private func place() async {
        model.tableFound = nil
        model.state = "placing"
        switch await openSpace(id: "stage") {
        case .opened: model.isPlaced = true
        default: model.state = "space did not open"
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("vision-cast").font(.largeTitle)
            Text("One lamp robot from the m3d pipeline, standing on your table.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Place the lamp") {
                    Task { await place() }
                }
                .disabled(model.isPlaced)
                Button("Wave") {
                    model.waveRequested = true
                }
                .disabled(!model.isPlaced)
                Button("Re-place") {
                    model.placer.unlock()
                    model.lastEvent = "re-placing"
                }
                .disabled(!model.isPlaced || model.placer.actor == nil)
                Button("Stop", role: .destructive) {
                    Task {
                        await dismissSpace()
                        model.isPlaced = false
                        model.state = "—"
                        model.distance = nil
                        model.tableFound = nil
                    }
                }
                .disabled(!model.isPlaced)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("state").foregroundStyle(.secondary); Text(model.state) }
                GridRow { Text("clip").foregroundStyle(.secondary); Text(model.clip) }
                GridRow {
                    Text("distance").foregroundStyle(.secondary)
                    Text(model.distance.map { String(format: "%.2f m", $0) } ?? "—")
                }
                GridRow {
                    Text("table").foregroundStyle(.secondary)
                    Text(model.tableFound.map { $0 ? "found" : "not found → floor fallback" } ?? "searching")
                }
                GridRow { Text("mode").foregroundStyle(.secondary); Text(model.placementMode) }
                GridRow { Text("chosen").foregroundStyle(.secondary); Text(model.placer.reason) }
                GridRow {
                    Text("head").foregroundStyle(.secondary)
                    Text(model.headTracking ? "tracking" : "no pose")
                }
                GridRow { Text("hand").foregroundStyle(.secondary); Text(model.hand) }
                GridRow { Text("hands").foregroundStyle(.secondary); Text(model.handDebug).font(.caption.monospaced()) }
                GridRow { Text("last").foregroundStyle(.secondary); Text(model.lastEvent) }
            }
            .font(.callout.monospaced())
            if !model.placer.hint.isEmpty {
                Label(model.placer.hint, systemImage: "eye").foregroundStyle(.orange)
            }
            if !model.placer.rows.isEmpty {
                Divider()
                Text("horizontal planes (class, height above floor, size, distance)")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.placer.rows, id: \.self) { Text($0) }
                    }
                }
                .font(.caption.monospaced())
            }
            Spacer()
        }
        .padding(28)
    }
}
