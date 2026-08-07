import simd

/// Geometria de uma parede tratada como plano vertical infinito.
///
/// Puro: não conhece ARKit. Sem LiDAR não há malha do teto nem das paredes contra
/// a qual fazer raycast, então tanto a medição de pé-direito quanto a seleção de
/// parede por toque são resolvidas analiticamente aqui.
enum WallGeometry {

    /// Direção unitária horizontal da parede, do canto inicial para o final.
    static func direction(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD3<Float>? {
        let delta = SIMD3<Float>(end.x - start.x, 0, end.z - start.z)
        let length = simd_length(delta)
        guard length > 1e-5 else { return nil }
        return delta / length
    }

    /// Normal horizontal da parede. Perpendicular à direção, no plano do piso.
    static func normal(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD3<Float>? {
        guard let direction = direction(from: start, to: end) else { return nil }
        return SIMD3<Float>(direction.z, 0, -direction.x)
    }

    static func length(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Float {
        simd_length(SIMD3<Float>(end.x - start.x, 0, end.z - start.z))
    }

    /// Distância, ao longo da parede, do canto inicial até a projeção de `point`.
    ///
    /// É o parâmetro que posiciona portas e janelas: guardar a abertura assim, e
    /// não em coordenadas absolutas, faz com que ela acompanhe a parede se os
    /// cantos forem ajustados depois — pelo snap ortogonal, por exemplo.
    static func project(
        _ point: SIMD3<Float>,
        onto start: SIMD3<Float>,
        _ end: SIMD3<Float>
    ) -> Float? {
        guard let direction = direction(from: start, to: end) else { return nil }
        let offset = SIMD3<Float>(point.x - start.x, 0, point.z - start.z)
        return simd_dot(offset, direction)
    }

    /// Ponto sobre a parede, a uma distância do canto inicial e a uma altura.
    static func point(
        onWallFrom start: SIMD3<Float>,
        to end: SIMD3<Float>,
        distance: Float,
        height: Float
    ) -> SIMD3<Float> {
        guard let direction = direction(from: start, to: end) else {
            return start.with(y: start.y + height)
        }
        let base = start + direction * distance
        return base.with(y: start.y + height)
    }

    /// Interseção de um raio com o plano vertical infinito que contém a parede.
    ///
    /// Com ponto P na parede, normal horizontal N, origem O e direção D:
    ///     t = ((P − O) · N) / (D · N)
    ///     interseção = O + t·D
    ///
    /// Devolve `nil` quando o raio é paralelo ao plano ou o atinge atrás da câmera.
    static func intersectVerticalPlane(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        wallStart: SIMD3<Float>,
        wallEnd: SIMD3<Float>
    ) -> (point: SIMD3<Float>, distance: Float)? {
        guard let normal = normal(from: wallStart, to: wallEnd) else { return nil }

        let denominator = simd_dot(rayDirection, normal)
        guard abs(denominator) > 1e-4 else { return nil }

        let t = simd_dot(wallStart - rayOrigin, normal) / denominator
        guard t > 0 else { return nil }

        return (rayOrigin + t * rayDirection, t)
    }

    /// Índice da parede que o raio está mirando.
    ///
    /// Considera apenas as paredes cujo plano é atingido **dentro do trecho** do
    /// segmento — o plano é infinito, mas a parede não. Entre as candidatas,
    /// escolhe a mais próxima da câmera.
    ///
    /// - Parameter tolerance: folga nas extremidades, em metros, para que mirar
    ///   exatamente num canto não deixe as duas paredes de fora.
    static func aimedWall(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        corners: [SIMD3<Float>],
        closed: Bool,
        tolerance: Float = 0.15
    ) -> (index: Int, point: SIMD3<Float>)? {
        guard corners.count >= 2 else { return nil }
        let segmentCount = closed ? corners.count : corners.count - 1

        var best: (index: Int, point: SIMD3<Float>, distance: Float)?

        for index in 0..<segmentCount {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]

            guard let hit = intersectVerticalPlane(
                rayOrigin: rayOrigin,
                rayDirection: rayDirection,
                wallStart: start,
                wallEnd: end
            ) else { continue }

            guard let distanceAlong = project(hit.point, onto: start, end) else { continue }
            let wallLength = length(from: start, to: end)
            guard distanceAlong >= -tolerance, distanceAlong <= wallLength + tolerance else { continue }

            if best == nil || hit.distance < best!.distance {
                best = (index, hit.point, hit.distance)
            }
        }

        guard let best else { return nil }
        return (best.index, best.point)
    }
}
