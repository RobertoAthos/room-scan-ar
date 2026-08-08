import SwiftUI

/// Main screen: the AR camera with the HUD on top.
struct ScannerView: View {
    @StateObject private var manager = ARSessionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if manager.isSupported {
                ARContainerView(manager: manager)
                    .ignoresSafeArea()
                    // Tap-to-select a wall, only during the openings phase.
                    // Outside it the gesture would fight the HUD's buttons.
                    .gesture(wallSelectionGesture, isEnabled: manager.phase == .markingOpenings)
            } else {
                UnsupportedARView()
            }

            ReticleView(state: manager.reticleState)

            HUDView(manager: manager)
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: resultsBinding) {
            ResultsView(scan: manager.scan) { manager.backToScanning() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The AR session has to stop in the background — ARKit doesn't keep
            // tracking with the app suspended, and resuming without re-running
            // the configuration leaves the scene frozen.
            switch newPhase {
            case .active:     manager.runSession(resetting: false)
            case .background: manager.pause()
            default:          break
            }
        }
    }

    private var wallSelectionGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                manager.selectWall(atScreenPoint: value.location)
            }
    }

    private var resultsBinding: Binding<Bool> {
        Binding(
            get: { manager.phase == .results },
            set: { if !$0 { manager.backToScanning() } }
        )
    }
}

/// Notice shown when the app runs where AR isn't supported — in practice, the
/// Simulator. It exists so the app *launches* there, which is where the geometry
/// tests run.
private struct UnsupportedARView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "arkit")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("Realidade aumentada indisponível")
                    .font(.headline)
                Text("Este app precisa de um iPhone físico com suporte a ARKit. O Simulator não fornece câmera nem rastreamento.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}
