import Testing
import simd
@testable import RoomScanAR

/// Testes do módulo `Geometry/`, que é puro: entra array de pontos, sai número.
/// Como não importa ARKit, este bundle roda no Simulator mesmo com o app sendo
/// exclusivo de dispositivo físico.
///
/// Os casos da especificação (shoelace, perímetro, snap ortogonal) entram na
/// Etapa 3, junto com `PolygonMath.swift`.
@Suite("Geometria")
struct GeometryTests {

    @Test("O alvo de testes está ligado ao módulo do app")
    func moduleIsLinked() {
        var scan = RoomScan()
        scan.corners = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 0, 1),
            SIMD3<Float>(0, 0, 1),
        ]
        scan.isClosed = true
        #expect(scan.wallCount == 4)
    }
}
