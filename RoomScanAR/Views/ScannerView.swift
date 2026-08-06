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
            } else {
                UnsupportedARView()
            }

            ReticleView(state: manager.reticleState)

            HUDView(manager: manager)
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
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
