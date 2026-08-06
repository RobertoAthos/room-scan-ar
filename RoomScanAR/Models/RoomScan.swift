import simd

/// Modelo de dados principal da digitalização.
///
/// Todos os valores estão em **metros**, em coordenadas de mundo do ARKit
/// (origem fixada no início da sessão). Os cantos são armazenados em ordem
/// sequencial ao redor do cômodo, todos com o mesmo Y (`floorY`).
struct RoomScan: Sendable {
    var corners: [SIMD3<Float>] = []
    var floorY: Float = 0
    var ceilingHeight: Float = 2.60
    var openings: [Opening] = []
    var isClosed: Bool = false

    /// Cantos originais, guardados antes de aplicar o snap ortogonal
    /// para que a operação seja reversível.
    var cornersBeforeSnap: [SIMD3<Float>]?

    var isSnapped: Bool { cornersBeforeSnap != nil }

    /// Número de segmentos de parede: n cantos fechados formam n paredes,
    /// n cantos abertos formam n-1.
    var wallCount: Int {
        guard corners.count >= 2 else { return 0 }
        return isClosed ? corners.count : corners.count - 1
    }

    /// Par de cantos que delimita a parede de índice `index`.
    func wall(at index: Int) -> (start: SIMD3<Float>, end: SIMD3<Float>)? {
        guard index >= 0, index < wallCount else { return nil }
        return (corners[index], corners[(index + 1) % corners.count])
    }
}
