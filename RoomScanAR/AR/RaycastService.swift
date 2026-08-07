import ARKit
import RealityKit
import simd

/// Marcação de pontos por raycast a partir do centro da tela.
///
/// Sem LiDAR não existe malha do ambiente. A única superfície contra a qual o
/// ARKit sabe lançar raios é o plano horizontal que ele detecta por odometria
/// visual-inercial — e esse plano cobre apenas a região já varrida pelo usuário.
///
/// Uma vez que o piso está travado, porém, deixamos de depender disso: a
/// interseção do raio da câmera com o plano infinito `y = floorY` é calculada
/// analiticamente, e vale para qualquer direção que aponte para baixo.
///
/// `@MainActor` porque `ARView` é isolada ao MainActor no SDK — não é escolha
/// nossa. É também onde o loop por frame roda, então não há custo de hop.
@MainActor
struct RaycastService {

    // `nonisolated` porque `Hit.isPrecise` — struct aninhada, fora do MainActor —
    // precisa lê-las.

    /// Distância máxima aceita para uma interseção com o piso.
    /// Além disso o erro angular vira erro de posição grande demais.
    nonisolated static let maxFloorDistance: Float = 15.0

    /// Além desta distância a marcação continua possível, mas a mira avisa que
    /// a precisão caiu: um erro de 1° na pose da câmera vira ~10 cm a 6 m.
    nonisolated static let preciseFloorDistance: Float = 6.0

    /// Tolerância vertical para aceitar um acerto de plano como sendo o piso.
    /// Serve para descartar mesas e camas que estejam no caminho do raio.
    nonisolated private static let floorLevelTolerance: Float = 0.15

    struct Hit: Equatable {
        enum Source: Equatable {
            /// Geometria de plano efetivamente detectada — a fonte mais confiável.
            case planeGeometry
            /// Plano estimado a partir de feature points.
            case estimatedPlane
            /// Interseção analítica com o plano do piso já travado.
            case lockedFloorPlane
        }

        let position: SIMD3<Float>
        let source: Source
        /// Distância da câmera até o ponto, em metros.
        let distance: Float

        var isPrecise: Bool {
            switch source {
            case .planeGeometry:    true
            case .estimatedPlane:   false
            case .lockedFloorPlane: distance <= RaycastService.preciseFloorDistance
            }
        }
    }

    /// Ponto do piso sob a mira.
    ///
    /// - Parameter lockedFloorY: altura do piso, se já confirmada. Quando presente,
    ///   habilita a interseção analítica e o descarte de planos fora do nível do piso.
    func floorHit(in view: ARView, lockedFloorY: Float?) -> Hit? {
        guard let cameraPosition = cameraRay(in: view)?.origin else { return nil }

        // 1. Geometria de plano detectada: a fonte mais confiável quando existe.
        if let point = planeGeometryHit(in: view) {
            if let lockedFloorY {
                // Um plano de mesa no caminho do raio seria marcado como canto.
                // Só aceita o acerto se ele estiver no nível do piso.
                if abs(point.y - lockedFloorY) <= Self.floorLevelTolerance {
                    return Hit(
                        position: point,
                        source: .planeGeometry,
                        distance: simd_distance(cameraPosition, point)
                    )
                }
            } else {
                return Hit(
                    position: point,
                    source: .planeGeometry,
                    distance: simd_distance(cameraPosition, point)
                )
            }
        }

        // 2. Piso travado: interseção analítica, independente de o plano detectado
        //    alcançar ou não a região sob a mira.
        if let lockedFloorY, let hit = lockedFloorIntersection(in: view, floorY: lockedFloorY) {
            return hit
        }

        // 3. Antes de travar o piso ainda não há plano de referência; resta o
        //    plano estimado por feature points.
        if lockedFloorY == nil, let point = estimatedPlaneHit(in: view) {
            return Hit(
                position: point,
                source: .estimatedPlane,
                distance: simd_distance(cameraPosition, point)
            )
        }

        return nil
    }

    /// Interseção do raio da câmera com o plano horizontal infinito `y = floorY`.
    ///
    /// Com origem O, direção D e o plano em `floorY`:
    ///     t = (floorY − O.y) / D.y
    ///     ponto = O + t·D
    /// Como D é unitário, `t` já é a distância em metros.
    func lockedFloorIntersection(in view: ARView, floorY: Float) -> Hit? {
        guard let ray = cameraRay(in: view) else { return nil }

        // Raio paralelo ao piso (celular na vertical) ou apontando para cima:
        // não existe interseção à frente da câmera.
        guard ray.direction.y < -1e-3 else { return nil }

        let t = (floorY - ray.origin.y) / ray.direction.y
        // t negativo significa piso atrás da câmera — acontece se a câmera
        // estiver abaixo do nível do piso travado.
        guard t > 0, t <= Self.maxFloorDistance else { return nil }

        return Hit(
            position: ray.origin + t * ray.direction,
            source: .lockedFloorPlane,
            distance: t
        )
    }

    /// Raio da câmera no instante atual: origem e direção unitária, em coordenadas de mundo.
    func cameraRay(in view: ARView) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let frame = view.session.currentFrame else { return nil }
        let transform = frame.camera.transform
        // Em ARKit a câmera olha para -Z no seu próprio espaço.
        let forward = -SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        return (transform.translation, simd_normalize(forward))
    }

    // MARK: - Consultas ao ARKit

    private func planeGeometryHit(in view: ARView) -> SIMD3<Float>? {
        raycast(in: view, allowing: .existingPlaneGeometry)
    }

    private func estimatedPlaneHit(in view: ARView) -> SIMD3<Float>? {
        raycast(in: view, allowing: .estimatedPlane)
    }

    private func raycast(in view: ARView, allowing target: ARRaycastQuery.Target) -> SIMD3<Float>? {
        // ATENÇÃO: `UIView.center` é o centro do frame no espaço da *superview*,
        // não o centro da própria view. Com a ARView em tela cheia dentro de uma
        // ZStack os dois divergem, e o raio sai deslocado. O ponto correto é o
        // meio de `bounds`.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let screenCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

        guard let query = view.makeRaycastQuery(
            from: screenCenter,
            allowing: target,
            alignment: .horizontal
        ), let result = view.session.raycast(query).first else { return nil }

        return result.worldTransform.translation
    }
}
