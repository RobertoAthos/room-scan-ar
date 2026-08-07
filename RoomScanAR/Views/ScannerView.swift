import SwiftUI

/// Tela principal: câmera AR com o HUD sobreposto.
struct ScannerView: View {
    @StateObject private var manager = ARSessionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if manager.isSupported {
                ARContainerView(manager: manager)
                    .ignoresSafeArea()
                    // Seleção de parede por toque, só na fase de aberturas. Fora
                    // dela o gesto atrapalharia os botões do HUD.
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
            // A sessão AR precisa parar em segundo plano — o ARKit não mantém
            // rastreamento com o app suspenso, e retomar sem re-executar a
            // configuração deixa a cena congelada.
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

/// Aviso exibido quando o app roda onde não há suporte a AR — na prática, o Simulator.
/// Existe para que o app *abra* no Simulator, que é onde os testes de geometria rodam.
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
