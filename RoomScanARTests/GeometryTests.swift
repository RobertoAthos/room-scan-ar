import Testing
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
