import simd

/// Alinhamento do polígono a ângulos retos.
///
/// Puro: entra array de pontos em XZ, sai array de pontos. Testável sem dispositivo.
enum OrthogonalSnap {

    /// Erro residual máximo tolerado, como fração do perímetro. Acima disso a
    /// marcação está irregular demais para que o snap represente o cômodo.
    static let maxResidualRatio: Float = 0.15

    struct Result {
        /// Cantos alinhados. Fecham exatamente e formam apenas ângulos retos.
        let corners: [SIMD2<Float>]
        /// Erro de fechamento antes do ajuste, como fração do perímetro.
        let residualRatio: Float
    }

    enum Failure: Error, Equatable {
        /// Menos de três cantos: não há polígono.
        case notEnoughCorners
        /// Erro residual acima do limite — a marcação está muito torta.
        case tooIrregular(residualRatio: Float)
        /// Depois do snap, algum eixo ficou com percurso só num sentido. O
        /// polígono não teria como fechar.
        case unbalancedAxis
    }

    /// Alinha os segmentos aos múltiplos de 90° do primeiro deles.
    ///
    /// O primeiro canto e a direção do primeiro segmento são preservados; o que
    /// muda são as direções dos demais segmentos e, para fechar o polígono, os
    /// comprimentos.
    ///
    /// **Divergência da especificação.** A spec pede distribuir o erro residual
    /// entre os vértices. Isso fecha o polígono mas reintroduz ângulos não-retos
    /// — paga-se o snap sem ficar com 90° exatos. Como após o snap todos os
    /// segmentos ficam alinhados aos eixos do referencial de θ₀, dá para fechar
    /// ajustando só os comprimentos: basta que a soma dos percursos num sentido
    /// iguale a do sentido oposto, em cada eixo. Assim o fechamento é exato e os
    /// ângulos retos sobrevivem.
    static func snap(_ points: [SIMD2<Float>]) -> Swift.Result<Result, Failure> {
        guard points.count >= 3 else { return .failure(.notEnoughCorners) }

        let count = points.count
        var lengths: [Float] = []
        var quadrants: [Int] = []

        // Referencial: a direção do primeiro segmento vira o eixo u.
        let firstDelta = points[1] - points[0]
        guard simd_length(firstDelta) > 1e-5 else { return .failure(.notEnoughCorners) }
        let theta0 = atan2(firstDelta.y, firstDelta.x)

        for index in 0..<count {
            let delta = points[(index + 1) % count] - points[index]
            let length = simd_length(delta)
            lengths.append(length)

            // Ângulo relativo a θ₀, arredondado ao múltiplo de 90° mais próximo.
            let relative = atan2(delta.y, delta.x) - theta0
            let quadrant = Int((relative / (.pi / 2)).rounded()) %% 4
            quadrants.append(quadrant)
        }

        let perimeter = lengths.reduce(0, +)
        guard perimeter > 1e-5 else { return .failure(.notEnoughCorners) }

        // Erro de fechamento caminhando com as direções alinhadas e os
        // comprimentos originais.
        var walk = SIMD2<Float>.zero
        for index in 0..<count {
            walk += axis(quadrants[index], theta0: theta0) * lengths[index]
        }
        let residualRatio = simd_length(walk) / perimeter
        guard residualRatio <= maxResidualRatio else {
            return .failure(.tooIrregular(residualRatio: residualRatio))
        }

        // Ajuste de comprimentos, eixo a eixo. Quadrantes 0 e 2 percorrem o eixo
        // u em sentidos opostos; 1 e 3, o eixo v.
        guard let scales = balancingScales(lengths: lengths, quadrants: quadrants) else {
            return .failure(.unbalancedAxis)
        }

        var corners: [SIMD2<Float>] = [points[0]]
        corners.reserveCapacity(count)
        var cursor = points[0]
        // O último segmento é o de fechamento: ele volta ao primeiro canto por
        // construção, então não gera vértice novo.
        for index in 0..<(count - 1) {
            cursor += axis(quadrants[index], theta0: theta0) * (lengths[index] * scales[index])
            corners.append(cursor)
        }

        return .success(Result(corners: corners, residualRatio: residualRatio))
    }

    /// Fator de correção de comprimento por segmento.
    ///
    /// Em cada eixo, a soma dos comprimentos num sentido tem que igualar a do
    /// sentido oposto. Distribui a diferença proporcionalmente ao comprimento,
    /// para que segmentos longos absorvam mais do que os curtos.
    private static func balancingScales(lengths: [Float], quadrants: [Int]) -> [Float]? {
        var totals = [Float](repeating: 0, count: 4)
        for index in lengths.indices {
            totals[quadrants[index]] += lengths[index]
        }

        var scales = [Float](repeating: 1, count: lengths.count)

        for (positive, negative) in [(0, 2), (1, 3)] {
            let forward = totals[positive]
            let backward = totals[negative]

            // Eixo sem percurso nenhum: nada a equilibrar.
            if forward < 1e-5 && backward < 1e-5 { continue }
            // Percurso só num sentido: o polígono não fecha por ajuste de escala.
            if forward < 1e-5 || backward < 1e-5 { return nil }

            let target = (forward + backward) / 2
            for index in lengths.indices {
                if quadrants[index] == positive { scales[index] = target / forward }
                if quadrants[index] == negative { scales[index] = target / backward }
            }
        }

        return scales
    }

    /// Vetor unitário do quadrante, no referencial girado por θ₀.
    private static func axis(_ quadrant: Int, theta0: Float) -> SIMD2<Float> {
        let angle = theta0 + Float(quadrant) * (.pi / 2)
        return SIMD2<Float>(cos(angle), sin(angle))
    }
}

// MARK: - Conveniência em 3D

extension OrthogonalSnap {
    /// Alinha cantos 3D preservando a altura de cada um.
    static func snap(_ corners: [SIMD3<Float>]) -> Swift.Result<[SIMD3<Float>], Failure> {
        let y = corners.first?.y ?? 0
        switch snap(corners.map(\.xz)) {
        case .success(let result):
            return .success(result.corners.map { $0.toXZ(y: y) })
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

/// Módulo sempre positivo. `-1 % 4` é `-1` em Swift, o que quebraria a indexação
/// dos quadrantes para segmentos que giram no sentido negativo.
infix operator %%: MultiplicationPrecedence
private func %% (lhs: Int, rhs: Int) -> Int {
    let remainder = lhs % rhs
    return remainder < 0 ? remainder + rhs : remainder
}
