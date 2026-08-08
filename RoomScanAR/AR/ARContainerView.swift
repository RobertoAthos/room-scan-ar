import ARKit
import RealityKit
import SwiftUI

/// Bridge between RealityKit's `ARView` and SwiftUI.
struct ARContainerView: UIViewRepresentable {
    let manager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        // `automaticallyConfigureSession: false` is essential: with the `true`
        // default, RealityKit overwrites our configuration (and goes as far as
        // enabling sceneReconstruction on LiDAR devices). We want full control.
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

        // Without LiDAR there is no environment mesh, so occlusion and physics
        // against the real world are unavailable. `sceneUnderstanding` is left
        // untouched, empty.
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
