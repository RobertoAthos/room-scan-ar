import simd

/// Geometria pura do polígono do cômodo.
///
/// Não importa ARKit nem RealityKit: entra array de pontos, sai número. É o que
/// permite testar a matemática no Simulator, sem dispositivo físico.
///
/// Tudo é calculado no plano XZ — a "planta" —, já que todos os cantos
/// compartilham a mesma altura por construção. Nas `SIMD2` usadas aqui,
/// `x` é o X do mundo e `y` é o **Z** do mundo.
enum PolygonMath {

    // MARK: - Área

    /// Área com sinal, pela fórmula do *shoelace*.
    ///
    /// O sinal indica o sentido de percurso dos vértices, o que interessa para
    /// orientar a planta baixa e para o snap ortogonal. Para exibir medidas
    /// use `area`, que é sempre positiva.
    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }

        // Translada para o primeiro vértice antes de somar. Os cantos chegam em
        // coordenadas de mundo, que podem estar a dezenas de metros da origem da
        // sessão AR; multiplicar coordenadas grandes e depois subtrair valores
        // próximos consome a precisão do Float justamente onde ela importa.
        // O acúmulo em Double é reforço barato.
        let origin = points[0]
        var sum = 0.0
        for index in points.indices {
            let a = points[index] - origin
            let b = points[(index + 1) % points.count] - origin
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return Float(sum / 2)
    }

    /// Área do piso, sempre positiva — independe de os cantos terem sido
    /// marcados em sentido horário ou anti-horário.
    static func area(_ points: [SIMD2<Float>]) -> Float {
        abs(signedArea(points))
    }

    // MARK: - Comprimentos

    /// Comprimento de cada segmento, na ordem dos cantos.
    static func segmentLengths(_ points: [SIMD2<Float>], closed: Bool) -> [Float] {
        guard points.count >= 2 else { return [] }
        let count = closed ? points.count : points.count - 1
        return (0..<count).map { index in
            simd_distance(points[index], points[(index + 1) % points.count])
        }
    }

    static func perimeter(_ points: [SIMD2<Float>], closed: Bool) -> Float {
        segmentLengths(points, closed: closed).reduce(0, +)
    }

    // MARK: - Centroide

    /// Centroide da **área** do polígono, não a média dos vértices.
    ///
    /// A média dos vértices é enviesada por cantos próximos entre si — num
    /// cômodo em L ela pode até cair fora do polígono. Para posicionar o rótulo
    /// de área na planta baixa queremos o centro de massa.
    static func centroid(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !points.isEmpty else { return .zero }
        guard points.count >= 3 else { return vertexMean(points) }

        let origin = points[0]
        var doubleArea = 0.0
        var accumulatedX = 0.0
        var accumulatedY = 0.0

        for index in points.indices {
            let a = points[index] - origin
            let b = points[(index + 1) % points.count] - origin
            let cross = Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
            doubleArea += cross
            accumulatedX += (Double(a.x) + Double(b.x)) * cross
            accumulatedY += (Double(a.y) + Double(b.y)) * cross
        }

        // Polígono degenerado (cantos colineares): não há centro de massa
        // definido, cai para a média dos vértices.
        guard abs(doubleArea) > 1e-9 else { return vertexMean(points) }

        // Cx = Σ(xᵢ + xᵢ₊₁)·cross / (6A), e doubleArea = 2A, logo 6A = 3·doubleArea.
        let factor = 1.0 / (3.0 * doubleArea)
        return origin + SIMD2<Float>(
            Float(accumulatedX * factor),
            Float(accumulatedY * factor)
        )
    }

    private static func vertexMean(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        points.reduce(.zero, +) / Float(points.count)
    }

    // MARK: - Dentro ou fora

    /// Se o ponto está dentro do polígono, por lançamento de raio.
    ///
    /// Conta quantas arestas um raio horizontal partindo do ponto atravessa:
    /// ímpar significa dentro. Funciona para qualquer polígono simples, côncavo
    /// inclusive, e **independe do sentido de percurso** dos vértices.
    ///
    /// É o que permite orientar as cotas da planta baixa sem deduzir handedness
    /// do sinal da área — dedução que erra quando o sistema de coordenadas de
    /// destino inverte um eixo, como a tela, cujo Y cresce para baixo.
    static func contains(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var isInside = false
        var previous = polygon.count - 1

        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]

            // A aresta cruza a horizontal que passa pelo ponto?
            let straddles = (a.y > point.y) != (b.y > point.y)
            if straddles {
                // X do cruzamento, por interpolação linear na aresta.
                let crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossingX { isInside.toggle() }
            }
            previous = current
        }

        return isInside
    }

    // MARK: - Paredes

    /// Área líquida de parede: perímetro × pé-direito, menos os vãos.
    static func netWallArea(perimeter: Float, ceilingHeight: Float, openingsArea: Float) -> Float {
        max(0, perimeter * ceilingHeight - openingsArea)
    }
}

// MARK: - Conveniências em 3D

/// Sobrecargas que projetam cantos 3D em XZ. Mantêm as funções acima puramente
/// bidimensionais, que é como elas são testadas.
extension PolygonMath {
    static func signedArea(_ corners: [SIMD3<Float>]) -> Float {
        signedArea(corners.map(\.xz))
    }

    static func area(_ corners: [SIMD3<Float>]) -> Float {
        area(corners.map(\.xz))
    }

    static func segmentLengths(_ corners: [SIMD3<Float>], closed: Bool) -> [Float] {
        segmentLengths(corners.map(\.xz), closed: closed)
    }

    static func perimeter(_ corners: [SIMD3<Float>], closed: Bool) -> Float {
        perimeter(corners.map(\.xz), closed: closed)
    }

    static func centroid(_ corners: [SIMD3<Float>]) -> SIMD2<Float> {
        centroid(corners.map(\.xz))
    }
}
