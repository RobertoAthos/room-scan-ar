import simd

/// Estimativa de pé-direito a partir da nuvem esparsa de feature points.
///
/// Puro: entra array de pontos, sai estatística. Não conhece ARKit.
///
/// Sem LiDAR não existe malha do teto, mas o ARKit rastreia feature points 3D
/// enquanto o usuário varre o cômodo. Filtrando os que estão altos e longe das
/// paredes, a distribuição de alturas descreve o teto — inclusive quando ele é
/// inclinado, caso em que um número único não representaria nada.
enum CeilingEstimator {

    struct Summary: Equatable {
        let sampleCount: Int
        /// Percentil 10 — a parte mais baixa do teto.
        let low: Float
        let median: Float
        /// Percentil 90 — a parte mais alta.
        let high: Float

        /// Diferença entre as pontas. Acima de ~30 cm o teto não é plano.
        var spread: Float { high - low }
    }

    /// Alturas dos pontos que podem pertencer ao teto.
    ///
    /// Três filtros, nesta ordem:
    /// 1. altura dentro da faixa plausível de pé-direito;
    /// 2. dentro do polígono do cômodo — descarta o que está em outro ambiente;
    /// 3. longe das paredes — descarta os pontos das próprias paredes, que são
    ///    altos e passariam pelos dois primeiros.
    static func ceilingHeights(
        from points: [SIMD3<Float>],
        floorY: Float,
        polygon: [SIMD2<Float>],
        minimumHeight: Float,
        maximumHeight: Float,
        wallMargin: Float
    ) -> [Float] {
        guard polygon.count >= 3 else { return [] }

        return points.compactMap { point in
            let height = point.y - floorY
            guard height >= minimumHeight, height <= maximumHeight else { return nil }

            let planar = point.xz
            guard PolygonMath.contains(planar, polygon: polygon) else { return nil }
            guard PolygonMath.distanceToBoundary(planar, polygon: polygon) >= wallMargin else { return nil }

            return height
        }
    }

    /// Alturas dos pontos que estão sobre o **encontro parede-teto**.
    ///
    /// É o inverso de `ceilingHeights`: em vez de descartar o que está perto da
    /// parede, fica só com isso.
    ///
    /// Serve para o caso em que a face do teto não tem textura — laje branca
    /// lisa não gera feature point nenhum, e a varredura do interior volta
    /// vazia. A quina onde parede e teto se encontram, porém, é uma
    /// descontinuidade de sombreamento entre duas superfícies, e existe mesmo no
    /// teto mais liso. Paredes também carregam muito mais textura que tetos:
    /// rodapé, tomada, quadro, móvel encostado.
    ///
    /// Os pontos colhidos ficam sobre a parede, em alturas variadas. O teto é o
    /// **topo** dessa distribuição — daí `junctionCeilingHeight` usar um
    /// percentil alto em vez da mediana.
    static func junctionHeights(
        from points: [SIMD3<Float>],
        floorY: Float,
        polygon: [SIMD2<Float>],
        minimumHeight: Float,
        maximumHeight: Float,
        maxWallDistance: Float
    ) -> [Float] {
        guard polygon.count >= 3 else { return [] }

        return points.compactMap { point in
            let height = point.y - floorY
            guard height >= minimumHeight, height <= maximumHeight else { return nil }

            // Sem teste de contenção: a quina fica sobre a linha do polígono, e
            // pontos ligeiramente para fora dela são igualmente válidos — o
            // traçado dos cantos passa pela face interna da parede, que tem
            // espessura. Só a distância até a aresta importa.
            let planar = point.xz
            guard PolygonMath.distanceToBoundary(planar, polygon: polygon) <= maxWallDistance else { return nil }

            return height
        }
    }

    /// Altura do teto a partir das amostras da junção.
    ///
    /// Percentil 92, e não o máximo: o topo bruto pegaria um ponto isolado numa
    /// viga, num trilho de cortina ou já do outro lado da parede.
    static func junctionCeilingHeight(_ heights: [Float], minimumSamples: Int = 12) -> Float? {
        guard heights.count >= minimumSamples else { return nil }
        return percentile(heights.sorted(), 0.92)
    }

    /// Resumo por percentis.
    ///
    /// Percentis, e não mínimo e máximo brutos: a nuvem é ruidosa, e um único
    /// ponto num lustre ou numa viga solta deslocaria o extremo inteiro. O
    /// décimo e o nonagésimo percentil descrevem o teto, não os acidentes.
    static func summarize(_ heights: [Float], minimumSamples: Int = 12) -> Summary? {
        guard heights.count >= minimumSamples else { return nil }

        let sorted = heights.sorted()
        return Summary(
            sampleCount: sorted.count,
            low: percentile(sorted, 0.10),
            median: percentile(sorted, 0.50),
            high: percentile(sorted, 0.90)
        )
    }

    /// Percentil com interpolação linear entre as duas amostras vizinhas.
    static func percentile(_ sorted: [Float], _ fraction: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }

        let position = min(max(fraction, 0), 1) * Float(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Float(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
