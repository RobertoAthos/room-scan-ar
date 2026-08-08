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

    /// Duração da animação de subida das paredes.
    private static let wallRiseDuration: TimeInterval = 0.8

    private var wallsRoot: Entity?
    private var wallNodes: [ModelEntity] = []

    private var elasticNode: ModelEntity?
    private var elasticLabelNode: Entity?
    private var elasticLabelCentimeters: Int?
    private var elasticIsStale: Bool?
    private var framesSinceLabelUpdate = 0

    private var previewLines: [ModelEntity] = []
    private var previewWidthLabel: Entity?
    private var previewHeightLabel: Entity?
    private var previewWidthCentimeters: Int?
    private var previewHeightCentimeters: Int?

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

    // MARK: - Paredes 3D

    /// Levanta uma parede por segmento do polígono.
    ///
    /// Todas as paredes ficam sob um container posicionado no nível do piso —
    /// é o pivô da animação de subida.
    func buildWalls(scan: RoomScan, highlighted: Int?, animated: Bool) {
        removeWalls()

        let segmentCount = scan.wallCount
        guard segmentCount > 0, scan.ceilingHeight > 0 else { return }

        let container = Entity()
        container.position = SIMD3<Float>(0, scan.floorY, 0)
        root.addChild(container)
        wallsRoot = container

        // Uma entidade por parede, e não uma malha única: cada parede é
        // reconstruída sozinha ao ganhar uma porta ou janela, e o destaque de
        // seleção troca só o material dela.
        for index in 0..<segmentCount {
            guard let wall = scan.wall(at: index) else { continue }

            // As alturas dos painéis são relativas ao container, que já está no
            // piso — daí a base em 0.
            let start = wall.start.with(y: 0)
            let end = wall.end.with(y: 0)

            let cutouts = scan.openings
                .filter { $0.wallIndex == index }
                .map {
                    WallMeshBuilder.Cutout(
                        distance: $0.distanceFromStart,
                        width: $0.width,
                        sill: $0.sillHeight,
                        top: $0.topHeight
                    )
                }

            let panels = WallMeshBuilder.panels(
                from: start,
                to: end,
                ceilingHeight: scan.ceilingHeight,
                cutouts: cutouts
            )
            guard let mesh = WallMeshBuilder.mesh(for: panels) else { continue }

            let material = index == highlighted ? Self.highlightMaterial() : Self.wallMaterial()
            let entity = ModelEntity(mesh: mesh, materials: [material])
            container.addChild(entity)
            wallNodes.append(entity)

            // Moldura contrastante em volta de cada vão, para o recorte ficar
            // legível em vídeo — as paredes translúcidas sozinhas não marcam
            // bem a borda da abertura.
            for opening in scan.openings where opening.wallIndex == index {
                addOpeningFrame(opening, wallStart: start, wallEnd: end, to: container)
            }
        }

        if animated { animateWallRise() }
    }

    private func addOpeningFrame(
        _ opening: Opening,
        wallStart: SIMD3<Float>,
        wallEnd: SIMD3<Float>,
        to container: Entity
    ) {
        let left = opening.distanceFromStart
        let right = opening.distanceFromStart + opening.width
        let bottom = opening.sillHeight
        let top = opening.topHeight

        let corners = [
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: left, height: bottom),
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: right, height: bottom),
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: right, height: top),
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: left, height: top),
        ]

        let color = Self.frameColor(for: opening.type)
        for index in 0..<4 {
            let line = ModelEntity(mesh: unitLineMesh, materials: [Self.material(color)])
            Self.placeInSpace(line, from: corners[index], to: corners[(index + 1) % 4])
            container.addChild(line)
            wallNodes.append(line)
        }
    }

    /// Anima a subida das paredes, de rente ao chão até a altura cheia.
    ///
    /// A malha é construída já na altura final e o que se anima é a **escala em Y**
    /// do container, cujo pivô está no piso. Animar os vértices exigiria regerar a
    /// malha a cada frame; o resultado visual é o mesmo.
    func animateWallRise() {
        guard let wallsRoot else { return }

        let target = wallsRoot.transform
        var flattened = target
        // Zero exato degenera a matriz de transformação; rente ao chão basta.
        flattened.scale.y = 0.001
        wallsRoot.transform = flattened

        _ = wallsRoot.move(
            to: target,
            relativeTo: wallsRoot.parent,
            duration: Self.wallRiseDuration,
            timingFunction: .easeOut
        )
    }

    func removeWalls() {
        wallsRoot?.removeFromParent()
        wallsRoot = nil
        wallNodes.removeAll()
    }

    /// Material das paredes: claro e translúcido, para o cômodo real continuar
    /// visível por trás.
    ///
    /// `PhysicallyBasedMaterial` em vez de `SimpleMaterial` porque aqui a
    /// transparência é **declarada** (`blending`), e não inferida do canal alfa
    /// de uma cor — comportamento que varia entre versões do RealityKit.
    /// `UnlitMaterial`, e não `PhysicallyBasedMaterial`: com PBR o
    /// `environmentTexturing` ilumina a parede, e um cômodo claro **lava** a cor
    /// definida aqui — foi o motivo de as paredes saírem mais claras do que o
    /// tint pedia. Unlit entrega exatamente a cor escrita, em qualquer ambiente.
    private static func wallMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: Self.wallTint)
        // A geometria é de dupla face, então cada pixel de parede é composto duas
        // vezes: 0,22 por face resulta em ~0,39 percebidos, perto dos 0,35 pedidos.
        material.blending = .transparent(opacity: .init(floatLiteral: Self.wallOpacityPerFace))
        return material
    }

    /// Azul profundo, bem saturado: contrasta com paredes brancas — que é o
    /// cômodo típico — sem virar preto chapado.
    private static let wallTint = UIColor(red: 0.05, green: 0.16, blue: 0.48, alpha: 1)

    /// Opacidade **por face**. A malha é de dupla face, então o alfa compõe duas
    /// vezes: 0,32 por face resulta em ~0,54 percebido. Este é o número a mexer
    /// se as paredes ficarem escuras ou claras demais no vídeo.
    private static let wallOpacityPerFace: Float = 0.32

    /// Parede selecionada para receber uma abertura.
    private static func highlightMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: UIColor.systemYellow)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.42))
        return material
    }

    /// Posiciona a linha unitária entre dois pontos quaisquer no espaço.
    ///
    /// Diferente de `place`, que só gira em torno de Y por saber que os cantos
    /// são coplanares: as molduras das aberturas têm arestas verticais.
    private static func placeInSpace(_ entity: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 1e-5 else { return }
        entity.position = (start + end) / 2
        entity.scale = SIMD3<Float>(1, 1, length)
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: delta / length)
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

    // MARK: - Prévia do vão em construção

    /// Retângulo do vão sendo marcado, com largura e altura rotuladas.
    ///
    /// Mesmo papel da linha elástica na marcação de cantos: mostrar a medida
    /// **antes** de confirmar. Sem isso o usuário só descobre o tamanho do vão
    /// depois de adicioná-lo.
    func updateOpeningPreview(
        wallStart: SIMD3<Float>,
        wallEnd: SIMD3<Float>,
        fromDistance: Float,
        toDistance: Float,
        sill: Float,
        top: Float,
        color: UIColor
    ) {
        let left = min(fromDistance, toDistance)
        let right = max(fromDistance, toDistance)
        let width = right - left
        let height = max(top - sill, 0)

        func corner(_ distance: Float, _ elevation: Float) -> SIMD3<Float> {
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: distance, height: elevation)
        }

        let outline = [
            corner(left, sill), corner(right, sill),
            corner(right, top), corner(left, top),
        ]

        if previewLines.isEmpty {
            for _ in 0..<4 {
                let line = ModelEntity(mesh: unitLineMesh, materials: [Self.material(color)])
                root.addChild(line)
                previewLines.append(line)
            }
        }
        for index in previewLines.indices {
            previewLines[index].isEnabled = true
            previewLines[index].model?.materials = [Self.material(color)]
            Self.placeInSpace(previewLines[index], from: outline[index], to: outline[(index + 1) % 4])
        }

        // Largura embaixo, altura na lateral — as duas cotas que o usuário
        // está de fato ajustando.
        placePreviewLabel(
            &previewWidthLabel,
            text: Format.meters(width),
            at: corner((left + right) / 2, sill) + SIMD3<Float>(0, -Self.labelLift, 0),
            color: color,
            cache: &previewWidthCentimeters,
            value: width
        )
        placePreviewLabel(
            &previewHeightLabel,
            text: Format.meters(height),
            at: corner(right, (sill + top) / 2),
            color: color,
            cache: &previewHeightCentimeters,
            value: height
        )
    }

    func hideOpeningPreview() {
        for line in previewLines { line.isEnabled = false }
        previewWidthLabel?.isEnabled = false
        previewHeightLabel?.isEnabled = false
    }

    private func placePreviewLabel(
        _ container: inout Entity?,
        text: String,
        at position: SIMD3<Float>,
        color: UIColor,
        cache: inout Int?,
        value: Float
    ) {
        let entity: Entity
        if let container {
            entity = container
        } else {
            let created = Entity()
            root.addChild(created)
            container = created
            entity = created
        }
        entity.isEnabled = true
        entity.position = position

        // Mesma economia da linha elástica: regenerar malha de texto é caro,
        // e o valor só muda de verdade na casa do centímetro.
        let centimeters = Int((value * 100).rounded())
        guard centimeters != cache else { return }
        cache = centimeters

        while let child = entity.children.first { child.removeFromParent() }
        entity.addChild(makeTextModel(text, color: color))
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
        for label in [previewWidthLabel, previewHeightLabel] {
            if let label, label.isEnabled { Self.yaw(label, toward: cameraPosition) }
        }
    }

    // MARK: - Limpeza

    func clear() {
        removeWalls()
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

        for line in previewLines { line.removeFromParent() }
        previewLines.removeAll()
        previewWidthLabel?.removeFromParent()
        previewWidthLabel = nil
        previewHeightLabel?.removeFromParent()
        previewHeightLabel = nil
        previewWidthCentimeters = nil
        previewHeightCentimeters = nil
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

    /// Cor da moldura por tipo de abertura. Contra a parede escura, cores
    /// saturadas distinguem os tipos de relance em vídeo.
    private static func frameColor(for type: OpeningType) -> UIColor {
        switch type {
        case .door:        .systemOrange
        case .slidingDoor: .systemPurple
        case .openGap:     .white
        case .window:      .systemTeal
        }
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
