import RealityKit
import UIKit
import simd

/// Constrói e mantém o conteúdo 3D da marcação: esferas nos cantos, linhas entre
/// cantos consecutivos, linha elástica até a mira e rótulos de comprimento.
///
/// Materiais são todos `UnlitMaterial`: sem LiDAR a estimativa de iluminação do
/// ARKit varia bastante, e um material iluminado deixa os marcadores escuros e
/// ilegíveis em vídeo. Unlit mantém a cor constante.
@MainActor
final class RoomSceneRenderer {

    /// Raio das esferas de canto — 2 cm, conforme especificação.
    private static let cornerRadius: Float = 0.02
    /// Espessura das linhas.
    private static let lineThickness: Float = 0.012
    /// Altura da fonte dos rótulos flutuantes, em metros.
    private static let labelFontSize: CGFloat = 0.08
    /// Elevação dos rótulos acima do piso, para não brigarem em Z com as linhas.
    private static let labelLift: Float = 0.06
    /// Regenerar malha de texto custa tesselação de fonte. Um rótulo atualizado
    /// a 10 Hz é perfeitamente legível e custa 6× menos que a cada frame.
    private static let labelUpdateFrameInterval = 6

    private let root: Entity

    /// Malhas reaproveitadas por todas as instâncias — geometria idêntica,
    /// só a transformação muda.
    private let sphereMesh: MeshResource
    private let unitLineMesh: MeshResource

    private var cornerNodes: [Entity] = []
    private var edgeNodes: [Entity] = []
    private var labelNodes: [Entity] = []

    private var elasticNode: ModelEntity?
    private var elasticLabelNode: Entity?
    private var elasticLabelCentimeters: Int?
    private var elasticIsStale: Bool?
    private var framesSinceLabelUpdate = 0

    init(root: Entity) {
        self.root = root
        sphereMesh = .generateSphere(radius: Self.cornerRadius)
        // Linha unitária: 1 m ao longo do eixo Z local. Escalar só em Z estica o
        // comprimento sem engrossar a linha.
        unitLineMesh = .generateBox(
            width: Self.lineThickness,
            height: Self.lineThickness,
            depth: 1.0
        )
    }

    // MARK: - Cantos e arestas confirmados

    /// Reconstrói toda a geometria confirmada.
    ///
    /// Recriar tudo em vez de fazer diff é intencional: são poucos cantos e isto
    /// só roda ao marcar ou desfazer, nunca por frame.
    func syncCorners(_ corners: [SIMD3<Float>], closed: Bool) {
        for node in cornerNodes + edgeNodes + labelNodes { node.removeFromParent() }
        cornerNodes.removeAll()
        edgeNodes.removeAll()
        labelNodes.removeAll()

        for corner in corners {
            let marker = ModelEntity(mesh: sphereMesh, materials: [Self.material(.systemYellow)])
            marker.position = corner
            root.addChild(marker)
            cornerNodes.append(marker)
        }

        let segmentCount = closed ? corners.count : corners.count - 1
        guard segmentCount > 0 else { return }

        for index in 0..<segmentCount {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]

            let line = ModelEntity(mesh: unitLineMesh, materials: [Self.material(.systemGreen)])
            Self.place(line, from: start, to: end)
            root.addChild(line)
            edgeNodes.append(line)

            let label = makeLabelContainer(
                text: Format.meters(simd_distance(start, end)),
                at: (start + end) / 2,
                color: .white
            )
            root.addChild(label)
            labelNodes.append(label)
        }
    }

    // MARK: - Linha elástica

    /// Linha do último canto marcado até a posição atual da mira, com o
    /// comprimento em construção rotulado no meio.
    ///
    /// - Parameter isStale: o destino é o último ponto válido, não o do frame
    ///   atual. Renderizada em cinza para deixar claro que parou de acompanhar.
    func updateElastic(from start: SIMD3<Float>?, to end: SIMD3<Float>?, isStale: Bool) {
        guard let start, let end else {
            hideElastic()
            return
        }

        let line: ModelEntity
        if let elasticNode {
            line = elasticNode
        } else {
            let entity = ModelEntity(mesh: unitLineMesh, materials: [Self.material(.white)])
            root.addChild(entity)
            elasticNode = entity
            line = entity
        }
        line.isEnabled = true
        Self.place(line, from: start, to: end)

        // Trocar material é custoso; só quando o estado realmente muda.
        if elasticIsStale != isStale {
            elasticIsStale = isStale
            line.model?.materials = [Self.material(Self.elasticColor(isStale: isStale))]
            // Força o rótulo a ser regerado na cor nova.
            elasticLabelCentimeters = nil
            framesSinceLabelUpdate = Self.labelUpdateFrameInterval
        }

        updateElasticLabel(length: simd_distance(start, end), at: (start + end) / 2, isStale: isStale)
    }

    private static func elasticColor(isStale: Bool) -> UIColor {
        isStale ? .systemGray : .white
    }

    func hideElastic() {
        elasticNode?.isEnabled = false
        elasticLabelNode?.isEnabled = false
    }

    private func updateElasticLabel(length: Float, at position: SIMD3<Float>, isStale: Bool) {
        let container: Entity
        if let elasticLabelNode {
            container = elasticLabelNode
        } else {
            let entity = Entity()
            root.addChild(entity)
            elasticLabelNode = entity
            container = entity
        }
        container.isEnabled = true
        // A posição acompanha a mira a cada frame; só o *texto* é limitado.
        container.position = position + SIMD3<Float>(0, Self.labelLift, 0)

        framesSinceLabelUpdate += 1
        guard framesSinceLabelUpdate >= Self.labelUpdateFrameInterval else { return }
        framesSinceLabelUpdate = 0

        let centimeters = Int((length * 100).rounded())
        guard centimeters != elasticLabelCentimeters else { return }
        elasticLabelCentimeters = centimeters

        while let child = container.children.first { child.removeFromParent() }
        container.addChild(makeTextModel(Format.meters(length), color: Self.elasticColor(isStale: isStale)))
    }

    // MARK: - Orientação dos rótulos

    /// Gira os rótulos para encarar a câmera, em torno de Y.
    ///
    /// Billboard só no eixo vertical (e não completo): o texto fica sempre em pé,
    /// que é como uma cota de planta é lida.
    func faceCamera(from cameraPosition: SIMD3<Float>) {
        for node in labelNodes {
            Self.yaw(node, toward: cameraPosition)
        }
        if let elasticLabelNode, elasticLabelNode.isEnabled {
            Self.yaw(elasticLabelNode, toward: cameraPosition)
        }
    }

    // MARK: - Limpeza

    func clear() {
        for node in cornerNodes + edgeNodes + labelNodes { node.removeFromParent() }
        cornerNodes.removeAll()
        edgeNodes.removeAll()
        labelNodes.removeAll()
        elasticNode?.removeFromParent()
        elasticNode = nil
        elasticLabelNode?.removeFromParent()
        elasticLabelNode = nil
        elasticLabelCentimeters = nil
        elasticIsStale = nil
    }

    // MARK: - Fábricas

    private func makeLabelContainer(text: String, at position: SIMD3<Float>, color: UIColor) -> Entity {
        let container = Entity()
        container.position = position + SIMD3<Float>(0, Self.labelLift, 0)
        container.addChild(makeTextModel(text, color: color))
        return container
    }

    private func makeTextModel(_ text: String, color: UIColor) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: Self.labelFontSize, weight: .semibold),
            alignment: .center
        )
        let model = ModelEntity(mesh: mesh, materials: [Self.material(color)])
        // O texto nasce com a origem no canto inferior esquerdo; recentraliza para
        // que o container possa ser posicionado no meio do segmento.
        model.position = -mesh.bounds.center
        return model
    }

    private static func material(_ color: UIColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }

    // MARK: - Matemática de posicionamento

    /// Posiciona, gira e estica a linha unitária para ligar dois pontos.
    private static func place(_ entity: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let delta = end - start
        entity.position = (start + end) / 2
        entity.scale = SIMD3<Float>(1, 1, max(simd_length(delta), 0.0001))
        // Gira o eixo +Z local até a direção do segmento. Como todos os cantos
        // compartilham o mesmo Y, uma rotação em torno de Y basta:
        // girar (0,0,1) por θ resulta em (sen θ, 0, cos θ), logo θ = atan2(dx, dz).
        entity.orientation = Self.yawQuaternion(dx: delta.x, dz: delta.z)
    }

    private static func yaw(_ entity: Entity, toward target: SIMD3<Float>) {
        let delta = target - entity.position
        guard abs(delta.x) > 1e-5 || abs(delta.z) > 1e-5 else { return }
        entity.orientation = Self.yawQuaternion(dx: delta.x, dz: delta.z)
    }

    private static func yawQuaternion(dx: Float, dz: Float) -> simd_quatf {
        simd_quatf(angle: atan2(dx, dz), axis: SIMD3<Float>(0, 1, 0))
    }
}
