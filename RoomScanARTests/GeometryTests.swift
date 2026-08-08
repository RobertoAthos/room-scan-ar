import Testing
import SwiftUI
import simd
@testable import RoomScanAR

/// Testes do módulo `Geometry/`, que é puro: entra array de pontos, sai número.
/// Como não importa ARKit, este bundle roda no Simulator mesmo com o app sendo
/// exclusivo de dispositivo físico.

/// Tolerância de comparação. Folgada o bastante para ruído de `Float`, apertada
/// o bastante para pegar erro de fórmula.
private let epsilon: Float = 1e-4

private func expectClose(
    _ actual: Float,
    _ expected: Float,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) < epsilon,
        comment ?? "esperado \(expected), obtido \(actual)",
        sourceLocation: sourceLocation
    )
}

private func p(_ x: Float, _ z: Float) -> SIMD2<Float> { SIMD2<Float>(x, z) }

@Suite("Área pelo shoelace")
struct ShoelaceTests {

    @Test("Quadrado de 1 m de lado tem 1 m²")
    func unitSquare() {
        let square = [p(0, 0), p(1, 0), p(1, 1), p(0, 1)]
        expectClose(PolygonMath.area(square), 1.0)
    }

    @Test("Polígono em L de área conhecida")
    func lShaped() {
        // Retângulo 3×1 com um quadrado 1×1 acrescido no canto superior esquerdo.
        // Área geométrica: 3 + 1 = 4 m².
        let shape = [p(0, 0), p(3, 0), p(3, 1), p(1, 1), p(1, 2), p(0, 2)]
        expectClose(PolygonMath.area(shape), 4.0)
    }

    @Test("A área é positiva nos dois sentidos de percurso")
    func windingIndependence() {
        let counterClockwise = [p(0, 0), p(2, 0), p(2, 3), p(0, 3)]
        let clockwise = Array(counterClockwise.reversed())

        expectClose(PolygonMath.area(counterClockwise), 6.0)
        expectClose(PolygonMath.area(clockwise), 6.0)

        // A área com sinal, ao contrário, distingue os dois — é dela que a
        // planta baixa e o snap ortogonal tiram a orientação.
        #expect(PolygonMath.signedArea(counterClockwise) * PolygonMath.signedArea(clockwise) < 0)
    }

    @Test("Longe da origem da sessão a precisão se mantém")
    func farFromOrigin() {
        // Uma sessão AR longa afasta os cantos dezenas de metros da origem.
        // Sem transladar antes de somar, o shoelace em Float perde dígitos aqui.
        let offset = p(850, -1240)
        let square = [p(0, 0), p(1, 0), p(1, 1), p(0, 1)].map { $0 + offset }
        expectClose(PolygonMath.area(square), 1.0)
    }

    @Test("Menos de três cantos não têm área")
    func degenerate() {
        expectClose(PolygonMath.area([SIMD2<Float>]()), 0)
        expectClose(PolygonMath.area([p(0, 0)]), 0)
        expectClose(PolygonMath.area([p(0, 0), p(1, 0)]), 0)
    }

    @Test("Cantos colineares dão área zero")
    func collinear() {
        expectClose(PolygonMath.area([p(0, 0), p(1, 0), p(2, 0)]), 0)
    }
}

@Suite("Ponto dentro do polígono")
struct ContainsTests {

    private let square = [p(0, 0), p(4, 0), p(4, 3), p(0, 3)]

    @Test("O centro está dentro")
    func center() {
        #expect(PolygonMath.contains(p(2, 1.5), polygon: square))
    }

    @Test("Pontos fora, nos quatro lados")
    func outside() {
        #expect(!PolygonMath.contains(p(-1, 1.5), polygon: square))
        #expect(!PolygonMath.contains(p(5, 1.5), polygon: square))
        #expect(!PolygonMath.contains(p(2, -1), polygon: square))
        #expect(!PolygonMath.contains(p(2, 4), polygon: square))
    }

    @Test("O resultado independe do sentido de percurso")
    func windingIndependent() {
        let reversed = Array(square.reversed())
        #expect(PolygonMath.contains(p(2, 1.5), polygon: reversed))
        #expect(!PolygonMath.contains(p(5, 1.5), polygon: reversed))
    }

    @Test("A reentrância de um L fica de fora")
    func concave() {
        let shape = [p(0, 0), p(3, 0), p(3, 1), p(1, 1), p(1, 2), p(0, 2)]
        #expect(PolygonMath.contains(p(0.5, 1.5), polygon: shape))
        // Este ponto está dentro do retângulo envolvente, mas fora do L.
        #expect(!PolygonMath.contains(p(2.5, 1.8), polygon: shape))
    }

    @Test("Sonda deslocada da parede escolhe o lado de fora")
    func probeDetectsOutside() {
        // É exatamente o que a planta baixa faz para orientar as cotas: desloca
        // 5 cm do meio da parede e testa se caiu dentro.
        // Parede de baixo do quadrado, de (0,0) a (4,0): o lado de fora é y < 0.
        #expect(!PolygonMath.contains(p(2, -0.05), polygon: square))
        #expect(PolygonMath.contains(p(2, 0.05), polygon: square))
    }

    @Test("Num cômodo estreito a sonda não atravessa para o outro lado")
    func narrowRoom() {
        // O caso da tela: 4,28 × 0,87 m. Uma sonda de 5 cm tem que ficar dentro
        // e não sair pela parede oposta.
        let narrow = [p(0, 0), p(4.28, 0), p(4.28, 0.87), p(0, 0.87)]
        #expect(PolygonMath.contains(p(2.14, 0.05), polygon: narrow))
        #expect(!PolygonMath.contains(p(2.14, -0.05), polygon: narrow))
        #expect(PolygonMath.contains(p(2.14, 0.82), polygon: narrow))
        #expect(!PolygonMath.contains(p(2.14, 0.92), polygon: narrow))
    }

    @Test("Menos de três pontos não contêm nada")
    func degenerate() {
        #expect(!PolygonMath.contains(p(0, 0), polygon: [p(0, 0), p(1, 1)]))
    }
}

@Suite("Tipos de abertura")
struct OpeningTypeTests {

    @Test("Só a janela tem peitoril")
    func sill() {
        #expect(!OpeningType.door.hasSill)
        #expect(!OpeningType.slidingDoor.hasSill)
        #expect(!OpeningType.openGap.hasSill)
        #expect(OpeningType.window.hasSill)
    }

    @Test("Vão estreito sugere porta de giro; vão largo, porta de correr")
    func suggestion() {
        #expect(OpeningType.suggested(forWidth: 0.80) == .door)
        #expect(OpeningType.suggested(forWidth: 1.19) == .door)
        #expect(OpeningType.suggested(forWidth: 1.20) == .slidingDoor)
        #expect(OpeningType.suggested(forWidth: 2.40) == .slidingDoor)
    }

    @Test("Portas e vãos descem até o piso")
    func defaults() {
        for type in [OpeningType.door, .slidingDoor, .openGap] {
            expectClose(type.defaultSillHeight, 0)
            expectClose(type.defaultHeight, 2.10)
        }
        expectClose(OpeningType.window.defaultSillHeight, 1.10)
        expectClose(OpeningType.window.defaultHeight, 1.20)
    }

    @Test("Vão aberto gera os mesmos painéis que uma porta")
    func openGapPanels() {
        // Sem peitoril: a diferença entre vão aberto e porta é só simbólica,
        // na planta 2D e na cor da moldura — a parede é recortada igual.
        let panels = WallMeshBuilder.panels(
            from: SIMD3<Float>(0, 0, 0), to: SIMD3<Float>(4, 0, 0),
            ceilingHeight: 2.60,
            cutouts: [.init(distance: 1.0, width: 1.60, sill: 0, top: 2.10)]
        )
        #expect(panels.count == 3)
        #expect(!panels.contains { $0.bottom < 1e-4 && $0.top < 2.0 })
    }
}

@Suite("Perímetro")
struct PerimeterTests {

    @Test("Retângulo 3×4 fechado tem perímetro 14 m")
    func rectangle() {
        let rectangle = [p(0, 0), p(3, 0), p(3, 4), p(0, 4)]
        expectClose(PolygonMath.perimeter(rectangle, closed: true), 14.0)
    }

    @Test("Aberto, o retângulo 3×4 não conta o segmento de fechamento")
    func openRectangle() {
        let rectangle = [p(0, 0), p(3, 0), p(3, 4), p(0, 4)]
        // 3 + 4 + 3 = 10; falta o lado de 4 que fecharia o polígono.
        expectClose(PolygonMath.perimeter(rectangle, closed: false), 10.0)
    }

    @Test("Comprimentos individuais saem na ordem dos cantos")
    func segments() {
        let rectangle = [p(0, 0), p(3, 0), p(3, 4), p(0, 4)]
        let lengths = PolygonMath.segmentLengths(rectangle, closed: true)
        #expect(lengths.count == 4)
        expectClose(lengths[0], 3)
        expectClose(lengths[1], 4)
        expectClose(lengths[2], 3)
        expectClose(lengths[3], 4)
    }

    @Test("Um canto sozinho não tem segmentos")
    func singleCorner() {
        #expect(PolygonMath.segmentLengths([p(0, 0)], closed: false).isEmpty)
    }
}

@Suite("Centroide")
struct CentroidTests {

    @Test("O centroide de um quadrado é o seu centro")
    func square() {
        let square = [p(0, 0), p(2, 0), p(2, 2), p(0, 2)]
        let center = PolygonMath.centroid(square)
        expectClose(center.x, 1.0)
        expectClose(center.y, 1.0)
    }

    @Test("Num L, o centro de massa difere da média dos vértices")
    func lShaped() {
        let shape = [p(0, 0), p(3, 0), p(3, 1), p(1, 1), p(1, 2), p(0, 2)]
        let center = PolygonMath.centroid(shape)
        let vertexMean = shape.reduce(SIMD2<Float>.zero, +) / Float(shape.count)

        // Centro de massa de duas partes: retângulo 3×1 (área 3, centro (1,5; 0,5))
        // e quadrado 1×1 (área 1, centro (0,5; 1,5)).
        // x = (3·1,5 + 1·0,5) / 4 = 1,25    y = (3·0,5 + 1·1,5) / 4 = 0,75
        expectClose(center.x, 1.25)
        expectClose(center.y, 0.75)
        #expect(abs(center.x - vertexMean.x) > 0.01 || abs(center.y - vertexMean.y) > 0.01)
    }

    @Test("Cantos colineares caem para a média dos vértices")
    func collinearFallback() {
        let line = [p(0, 0), p(1, 0), p(2, 0)]
        let center = PolygonMath.centroid(line)
        expectClose(center.x, 1.0)
        expectClose(center.y, 0.0)
    }
}

@Suite("Área de parede")
struct WallAreaTests {

    @Test("Área líquida desconta os vãos")
    func netArea() {
        // 14 m de perímetro × 2,60 m = 36,40 m²; menos 1,68 m² de vãos.
        expectClose(
            PolygonMath.netWallArea(perimeter: 14, ceilingHeight: 2.60, openingsArea: 1.68),
            34.72
        )
    }

    @Test("Vãos maiores que a parede não geram área negativa")
    func clampedAtZero() {
        expectClose(
            PolygonMath.netWallArea(perimeter: 1, ceilingHeight: 2.60, openingsArea: 100),
            0
        )
    }
}

@Suite("Snap ortogonal")
struct OrthogonalSnapTests {

    /// Ângulo entre segmentos consecutivos, em graus.
    private func turnAngles(_ points: [SIMD2<Float>]) -> [Float] {
        (0..<points.count).map { index in
            let a = points[(index + 1) % points.count] - points[index]
            let b = points[(index + 2) % points.count] - points[(index + 1) % points.count]
            let cosine = simd_dot(simd_normalize(a), simd_normalize(b))
            return acos(min(max(cosine, -1), 1)) * 180 / .pi
        }
    }

    @Test("Quadrado levemente torto converge para 90°")
    func crookedSquare() {
        // Quadrado de 3 m com os cantos deslocados alguns centímetros, que é o
        // que uma marcação real produz.
        let crooked = [
            p(0.00, 0.00),
            p(3.04, 0.07),
            p(2.96, 3.05),
            p(-0.05, 2.98),
        ]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("o snap deveria ter sido aplicado")
            return
        }

        #expect(result.corners.count == 4)
        for angle in turnAngles(result.corners) {
            expectClose(angle, 90, "ângulo de \(angle)° deveria ser reto")
        }
    }

    @Test("Depois do snap, o polígono fecha exatamente")
    func closesExactly() {
        let crooked = [p(0, 0), p(4.03, 0.05), p(3.98, 2.51), p(-0.04, 2.47)]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("o snap deveria ter sido aplicado")
            return
        }

        // Caminhar por todos os segmentos tem que voltar ao ponto de partida.
        var walk = SIMD2<Float>.zero
        for index in result.corners.indices {
            walk += result.corners[(index + 1) % result.corners.count] - result.corners[index]
        }
        expectClose(simd_length(walk), 0, "erro de fechamento residual de \(simd_length(walk)) m")
    }

    @Test("O snap preserva o primeiro canto")
    func preservesFirstCorner() {
        let crooked = [p(1, 2), p(4.03, 2.05), p(3.98, 4.51), p(0.96, 4.47)]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("o snap deveria ter sido aplicado")
            return
        }
        expectClose(result.corners[0].x, 1)
        expectClose(result.corners[0].y, 2)
    }

    @Test("A área quase não muda num quadrado levemente torto")
    func areaIsPreserved() {
        let crooked = [p(0, 0), p(3.04, 0.07), p(2.96, 3.05), p(-0.05, 2.98)]
        let before = PolygonMath.area(crooked)

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("o snap deveria ter sido aplicado")
            return
        }
        let after = PolygonMath.area(result.corners)
        #expect(abs(after - before) / before < 0.05, "área variou de \(before) para \(after)")
    }

    @Test("Polígono muito irregular é rejeitado")
    func rejectsIrregular() {
        // Um triângulo não tem como virar retangular: os 60° arredondam para 90°
        // e o erro de fechamento estoura o limite.
        let triangle = [p(0, 0), p(4, 0), p(2, 3.46)]

        guard case .failure(let failure) = OrthogonalSnap.snap(triangle) else {
            Issue.record("o snap deveria ter sido rejeitado")
            return
        }
        // Rejeitado por erro residual ou por eixo desequilibrado — ambos são
        // recusas legítimas para esta forma.
        #expect(failure != .notEnoughCorners)
    }

    @Test("Menos de três cantos é rejeitado")
    func rejectsTooFewCorners() {
        guard case .failure(let failure) = OrthogonalSnap.snap([p(0, 0), p(1, 0)]) else {
            Issue.record("deveria ter sido rejeitado")
            return
        }
        #expect(failure == .notEnoughCorners)
    }

    @Test("Um cômodo em L levemente torto também converge")
    func crookedLShape() {
        let crooked = [
            p(0.00, 0.00),
            p(3.03, 0.04),
            p(2.98, 1.02),
            p(1.01, 0.99),
            p(0.97, 2.03),
            p(-0.03, 1.98),
        ]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("o snap deveria ter sido aplicado")
            return
        }
        for angle in turnAngles(result.corners) {
            expectClose(angle, 90, "ângulo de \(angle)° deveria ser reto")
        }
    }
}

@Suite("Painéis de parede")
struct WallPanelTests {

    private let start = SIMD3<Float>(0, 0, 0)
    private let end = SIMD3<Float>(4, 0, 0)
    private let ceiling: Float = 2.60

    @Test("Parede sem aberturas é um único painel de altura cheia")
    func solidWall() {
        let panels = WallMeshBuilder.panels(from: start, to: end, ceilingHeight: ceiling)
        #expect(panels.count == 1)
        expectClose(panels[0].bottom, 0)
        expectClose(panels[0].top, ceiling)
    }

    @Test("Porta gera painel esquerdo, painel direito e verga")
    func door() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 1.0, width: 0.80, sill: 0, top: 2.10)]
        )
        // Sem peitoril: esquerdo (0→1), verga (1→1,8 acima de 2,10), direito (1,8→4).
        #expect(panels.count == 3)
        // Nenhum painel cobre o vão em altura de passagem.
        let atDoorHeight = panels.filter { $0.bottom < 1.0 && $0.top > 1.0 }
        for panel in atDoorHeight {
            let coversGap = panel.start.x < 1.79 && panel.end.x > 1.01
            #expect(!coversGap, "um painel fecha o vão da porta")
        }
    }

    @Test("Janela gera peitoril além da verga")
    func window() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 1.5, width: 1.20, sill: 1.10, top: 2.30)]
        )
        // Esquerdo, peitoril, verga, direito.
        #expect(panels.count == 4)
        #expect(panels.contains { abs($0.bottom - 0) < 1e-4 && abs($0.top - 1.10) < 1e-4 })
        #expect(panels.contains { abs($0.bottom - 2.30) < 1e-4 && abs($0.top - ceiling) < 1e-4 })
    }

    @Test("Vão que encosta no teto não gera verga")
    func openingUpToCeiling() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 1.0, width: 1.0, sill: 0, top: ceiling)]
        )
        #expect(panels.count == 2)
    }

    @Test("Vão maior que a parede é recortado, sem painel de comprimento negativo")
    func oversizedOpening() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 3.5, width: 10, sill: 0, top: 2.10)]
        )
        for panel in panels {
            let length = simd_distance(panel.start, panel.end)
            #expect(length > 0, "painel com comprimento \(length)")
            #expect(panel.top >= panel.bottom)
        }
    }

    @Test("Dois vãos na mesma parede geram o trecho cheio entre eles")
    func twoOpenings() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [
                .init(distance: 2.4, width: 0.9, sill: 1.10, top: 2.30),
                .init(distance: 0.5, width: 0.8, sill: 0, top: 2.10),
            ]
        )
        // Os vãos entram fora de ordem de propósito: o algoritmo tem que ordenar.
        let fullHeight = panels.filter { $0.bottom < 1e-4 && $0.top > ceiling - 1e-4 }
        // Trechos cheios: antes do primeiro vão, entre os dois, e depois do segundo.
        #expect(fullHeight.count == 3)
    }
}

@Suite("Geometria de parede")
struct WallGeometryTests {

    @Test("Projeção sobre a parede devolve a distância do canto inicial")
    func projection() {
        let start = SIMD3<Float>(0, 0, 0)
        let end = SIMD3<Float>(4, 0, 0)
        // Um ponto fora da parede projeta na perpendicular.
        let distance = WallGeometry.project(SIMD3<Float>(1.5, 0, 0.6), onto: start, end)
        expectClose(distance ?? -1, 1.5)
    }

    @Test("O raio encontra a parede que está sendo mirada")
    func aimedWall() {
        // Cômodo 4×3, câmera no meio olhando para a parede 0 (z = 0).
        let corners = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(4, 0, 0),
            SIMD3<Float>(4, 0, 3),
            SIMD3<Float>(0, 0, 3),
        ]
        let aimed = WallGeometry.aimedWall(
            rayOrigin: SIMD3<Float>(2, 1.5, 1.5),
            rayDirection: simd_normalize(SIMD3<Float>(0, 0.4, -1)),
            corners: corners,
            closed: true
        )
        #expect(aimed?.index == 0)
    }

    @Test("Interseção com o plano da parede dá a altura do teto")
    func ceilingIntersection() {
        let start = SIMD3<Float>(0, 0, 0)
        let end = SIMD3<Float>(4, 0, 0)
        // Da posição (2; 1,5; 2), mirando na parede com inclinação para cima.
        // A parede está 2 m à frente; subindo 0,55 por metro chega a 1,5 + 1,1 = 2,6.
        let hit = WallGeometry.intersectVerticalPlane(
            rayOrigin: SIMD3<Float>(2, 1.5, 2),
            rayDirection: simd_normalize(SIMD3<Float>(0, 0.55, -1)),
            wallStart: start,
            wallEnd: end
        )
        expectClose(hit?.point.y ?? -1, 2.6)
    }

    @Test("Raio paralelo ao plano da parede não intersecta")
    func parallelRay() {
        let hit = WallGeometry.intersectVerticalPlane(
            rayOrigin: SIMD3<Float>(2, 1.5, 2),
            rayDirection: SIMD3<Float>(1, 0, 0),
            wallStart: SIMD3<Float>(0, 0, 0),
            wallEnd: SIMD3<Float>(4, 0, 0)
        )
        #expect(hit == nil)
    }
}

@Suite("Rotação da planta")
struct PlanRotationTests {

    private func degrees(_ value: Double) -> Angle { .degrees(value) }

    @Test("Ângulo quase reto encosta no múltiplo de 90°")
    func snapsWhenClose() {
        #expect(PlanTransform.snapRotation(degrees(87)).degrees == 90)
        #expect(PlanTransform.snapRotation(degrees(93)).degrees == 90)
        #expect(PlanTransform.snapRotation(degrees(-4)).degrees == 0)
        #expect(PlanTransform.snapRotation(degrees(184)).degrees == 180)
    }

    @Test("Ângulo oblíquo intencional é preservado")
    func keepsDeliberateAngle() {
        // A tolerância precisa ser estreita o bastante para não sequestrar uma
        // orientação escolhida de propósito.
        #expect(PlanTransform.snapRotation(degrees(45)).degrees == 45)
        #expect(PlanTransform.snapRotation(degrees(80)).degrees == 80)
    }

    @Test("Voltas completas são normalizadas")
    func normalizesFullTurns() {
        // Girar quatro vezes 90° pelo botão acumularia 360° sem isto.
        #expect(PlanTransform.snapRotation(degrees(360)).degrees == 0)
        #expect(PlanTransform.snapRotation(degrees(450)).degrees == 90)
        #expect(PlanTransform.snapRotation(degrees(-270)).degrees == 90)
    }

    @Test("180 e −180 convergem para a forma positiva")
    func canonicalHalfTurn() {
        #expect(PlanTransform.snapRotation(degrees(-180)).degrees == 180)
        #expect(PlanTransform.snapRotation(degrees(180)).degrees == 180)
    }

    @Test("Quatro giros de 90° voltam ao ponto de partida")
    func fourQuarterTurns() {
        var angle = Angle.zero
        for _ in 0..<4 {
            angle = PlanTransform.snapRotation(angle + .degrees(90))
        }
        #expect(angle.degrees == 0)
    }
}

@Suite("Medidas do RoomScan")
struct RoomScanMeasurementTests {

    /// Constrói um cômodo retangular de 3×4 m, na altura de piso informada.
    private func rectangularScan(floorY: Float = 0, closed: Bool = true) -> RoomScan {
        var scan = RoomScan()
        scan.floorY = floorY
        scan.corners = [
            SIMD3<Float>(0, floorY, 0),
            SIMD3<Float>(3, floorY, 0),
            SIMD3<Float>(3, floorY, 4),
            SIMD3<Float>(0, floorY, 4),
        ]
        scan.isClosed = closed
        return scan
    }

    @Test("Área e perímetro de um cômodo 3×4")
    func rectangle() {
        let scan = rectangularScan()
        expectClose(scan.floorArea, 12.0)
        expectClose(scan.perimeter, 14.0)
        #expect(scan.wallCount == 4)
    }

    @Test("A altura do piso não interfere na área, que é medida em XZ")
    func floorHeightIsIrrelevant() {
        expectClose(rectangularScan(floorY: -1.85).floorArea, 12.0)
    }

    @Test("Com o polígono aberto, a área é prévia mas o perímetro exclui o fechamento")
    func openPolygon() {
        let scan = rectangularScan(closed: false)
        // O shoelace fecha implicitamente: a prévia de área continua correta.
        expectClose(scan.floorArea, 12.0)
        expectClose(scan.perimeter, 10.0)
        #expect(scan.wallCount == 3)
    }

    @Test("Área líquida de parede desconta porta e janela")
    func netWallArea() {
        var scan = rectangularScan()
        scan.ceilingHeight = 2.60
        scan.openings = [
            Opening(wallIndex: 0, distanceFromStart: 1, width: 0.80, height: 2.10, sillHeight: 0, type: .door),
            Opening(wallIndex: 1, distanceFromStart: 1, width: 1.20, height: 1.20, sillHeight: 1.10, type: .window),
        ]
        // 14 × 2,60 = 36,40; vãos 1,68 + 1,44 = 3,12.
        expectClose(scan.openingsArea, 3.12)
        expectClose(scan.netWallArea, 33.28)
    }
}
