import ARKit
import RealityKit
import simd

/// Marcação de pontos por raycast a partir do centro da tela.
///
/// Sem LiDAR não existe malha do ambiente, então a única superfície contra a qual
/// podemos lançar raios é o plano horizontal detectado pelo ARKit por odometria
/// visual-inercial. Toda a geometria do cômodo é derivada daí.
///
/// `@MainActor` porque `ARView` é isolada ao MainActor no SDK — não é uma escolha
/// nossa. É também onde o loop por frame roda, então não há custo de hop.
@MainActor
struct RaycastService {

    /// Resultado de uma tentativa de raycast, incluindo a qualidade da origem.
    enum Hit: Equatable {
        /// Atingiu geometria de plano já detectada — posição confiável.
        case existingPlane(SIMD3<Float>)
        /// Atingiu um plano apenas estimado — usável, mas menos preciso.
        case estimatedPlane(SIMD3<Float>)

        var position: SIMD3<Float> {
            switch self {
            case .existingPlane(let p), .estimatedPlane(let p): p
            }
        }

        var isPrecise: Bool {
            if case .existingPlane = self { return true }
            return false
        }
    }

    /// Lança um raio do centro da tela contra planos horizontais.
    ///
    /// Tenta primeiro a geometria de plano já detectada; se o plano ainda não cobre
    /// a região sob a mira (comum perto dos rodapés, onde a detecção é fraca),
    /// cai para o plano estimado.
    func horizontalHit(in view: ARView) -> Hit? {
        // ATENÇÃO: `UIView.center` é o centro do frame no espaço da *superview*,
        // não o centro da própria view. Com a ARView em tela cheia dentro de uma
        // ZStack os dois divergem, e o raio sai deslocado. O ponto correto é o
        // meio de `bounds`.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let screenCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let session = view.session

        if let query = view.makeRaycastQuery(
            from: screenCenter,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        ), let result = session.raycast(query).first {
            return .existingPlane(result.worldTransform.translation)
        }

        if let query = view.makeRaycastQuery(
            from: screenCenter,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ), let result = session.raycast(query).first {
            return .estimatedPlane(result.worldTransform.translation)
        }

        return nil
    }

    /// Raio da câmera no instante atual: origem e direção unitária, em coordenadas de mundo.
    ///
    /// Usado na medição de pé-direito, onde intersectamos esse raio com um plano
    /// vertical construído a partir da parede — não há superfície detectada no teto
    /// contra a qual fazer raycast.
    func cameraRay(in view: ARView) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let frame = view.session.currentFrame else { return nil }
        let transform = frame.camera.transform
        let origin = transform.translation
        // Em ARKit a câmera olha para -Z no seu próprio espaço.
        let forward = -SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        return (origin, simd_normalize(forward))
    }
}
