import ARKit
import RealityKit
import SwiftUI

/// Ponte entre a `ARView` do RealityKit e a SwiftUI.
struct ARContainerView: UIViewRepresentable {
    let manager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        // `automaticallyConfigureSession: false` é essencial: com o padrão `true`,
        // o RealityKit sobrescreve a nossa configuração (e chega a habilitar
        // sceneReconstruction em aparelhos com LiDAR). Queremos controle total.
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

        // Sem LiDAR não há malha do ambiente, então oclusão e física contra o mundo
        // real não estão disponíveis. `sceneUnderstanding` fica intocado, vazio.
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.automaticallyConfigureSession = false

        manager.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}
