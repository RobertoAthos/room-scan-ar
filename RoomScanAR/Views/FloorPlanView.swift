import SwiftUI
import simd

/// Planta baixa desenhada com `Canvas`.
///
/// Estética de desenho técnico: fundo branco, traço preto, sem sombra nem cor
/// decorativa. É o que vai para o PDF, então precisa ler bem impresso.
struct FloorPlanView: View {
    let scan: RoomScan

    /// Espessura da parede no desenho, em pontos.
    private let wallWidth: CGFloat = 8
    /// Margem ao redor do desenho, para as cotas caberem.
    private let margin: CGFloat = 56

    var body: some View {
        Canvas { context, size in
            guard scan.corners.count >= 2,
                  let transform = PlanTransform(
                      scan: scan,
                      viewport: size,
                      margin: margin
                  ) else { return }

            drawWalls(in: &context, transform: transform)
            drawOpenings(in: &context, transform: transform)
            drawDimensions(in: &context, transform: transform)
            drawAreaLabel(in: &context, transform: transform)
        }
        .background(.white)
    }

    // MARK: - Paredes

    private func drawWalls(in context: inout GraphicsContext, transform: PlanTransform) {
        var path = Path()
        let points = scan.corners.map { transform.point($0) }
        path.addLines(points)
        if scan.isClosed { path.closeSubpath() }

        context.stroke(
            path,
            with: .color(.black),
            style: StrokeStyle(lineWidth: wallWidth, lineCap: .square, lineJoin: .miter)
        )
    }

    // MARK: - Portas, janelas e vãos

    private func drawOpenings(in context: inout GraphicsContext, transform: PlanTransform) {
        for opening in scan.openings {
            guard let wall = scan.wall(at: opening.wallIndex),
                  let direction = WallGeometry.direction(from: wall.start, to: wall.end) else { continue }

            let wallLength = WallGeometry.length(from: wall.start, to: wall.end)
            let start = min(max(opening.distanceFromStart, 0), wallLength)
            let end = min(start + opening.width, wallLength)
            guard end > start else { continue }

            let a = transform.point(wall.start + direction * start)
            let b = transform.point(wall.start + direction * end)

            // Abre o vão apagando o trecho da parede com a cor do fundo, em vez
            // de desenhar a parede em pedaços. Mais simples e o resultado é o mesmo.
            var gap = Path()
            gap.move(to: a)
            gap.addLine(to: b)
            context.stroke(
                gap,
                with: .color(.white),
                style: StrokeStyle(lineWidth: wallWidth + 1, lineCap: .butt)
            )

            drawJambs(in: &context, at: a, and: b, along: b - a)

            switch opening.type {
            case .door:
                drawSwingDoor(
                    in: &context, from: a, to: b,
                    inwardNormal: transform.inwardNormal(ofWall: opening.wallIndex, in: scan)
                )
            case .slidingDoor:
                drawSlidingDoor(
                    in: &context, from: a, to: b,
                    inwardNormal: transform.inwardNormal(ofWall: opening.wallIndex, in: scan)
                )
            case .openGap:
                // Um vão aberto é só a ausência de parede: as ombreiras bastam.
                break
            case .window:
                drawWindow(in: &context, from: a, to: b)
            }
        }
    }

    /// Ombreiras: os traços que fecham as laterais do vão.
    private func drawJambs(in context: inout GraphicsContext, at a: CGPoint, and b: CGPoint, along delta: CGPoint) {
        let length = hypot(delta.x, delta.y)
        guard length > 0.5 else { return }
        let normal = CGVector(dx: -delta.y / length, dy: delta.x / length)
        let half = wallWidth / 2

        var path = Path()
        for point in [a, b] {
            path.move(to: CGPoint(x: point.x + normal.dx * half, y: point.y + normal.dy * half))
            path.addLine(to: CGPoint(x: point.x - normal.dx * half, y: point.y - normal.dy * half))
        }
        context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1.5))
    }

    /// Porta de giro: folha aberta a 90° e arco de varredura.
    private func drawSwingDoor(
        in context: inout GraphicsContext,
        from a: CGPoint,
        to b: CGPoint,
        inwardNormal: CGVector
    ) {
        let width = hypot(b.x - a.x, b.y - a.y)
        guard width > 0.5 else { return }

        let leafEnd = CGPoint(
            x: a.x + inwardNormal.dx * width,
            y: a.y + inwardNormal.dy * width
        )
        var leaf = Path()
        leaf.move(to: a)
        leaf.addLine(to: leafEnd)
        context.stroke(leaf, with: .color(.black), style: StrokeStyle(lineWidth: 2))

        let startAngle = atan2(b.y - a.y, b.x - a.x)
        let endAngle = atan2(leafEnd.y - a.y, leafEnd.x - a.x)
        var arc = Path()
        arc.addArc(
            center: a,
            radius: width,
            startAngle: .radians(startAngle),
            endAngle: .radians(endAngle),
            clockwise: shortestSweepIsClockwise(from: startAngle, to: endAngle)
        )
        context.stroke(
            arc,
            with: .color(.black.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    }

    /// Porta de correr: folha deslocada para dentro, paralela à parede, com a
    /// seta indicando o sentido de deslizamento.
    private func drawSlidingDoor(
        in context: inout GraphicsContext,
        from a: CGPoint,
        to b: CGPoint,
        inwardNormal: CGVector
    ) {
        let width = hypot(b.x - a.x, b.y - a.y)
        guard width > 0.5 else { return }

        let offset = wallWidth * 0.9
        let leafA = CGPoint(x: a.x + inwardNormal.dx * offset, y: a.y + inwardNormal.dy * offset)
        let leafB = CGPoint(x: b.x + inwardNormal.dx * offset, y: b.y + inwardNormal.dy * offset)

        var leaf = Path()
        leaf.move(to: leafA)
        leaf.addLine(to: leafB)
        context.stroke(leaf, with: .color(.black), style: StrokeStyle(lineWidth: 3, lineCap: .butt))

        // Seta ao longo da folha, do batente para o vão.
        let direction = CGVector(dx: (b.x - a.x) / width, dy: (b.y - a.y) / width)
        let headBase = CGPoint(
            x: leafB.x - direction.dx * width * 0.28,
            y: leafB.y - direction.dy * width * 0.28
        )
        let wing = CGVector(dx: -direction.dy, dy: direction.dx)
        let wingLength = min(width * 0.12, 6)

        var arrow = Path()
        arrow.move(to: leafB)
        arrow.addLine(to: CGPoint(x: headBase.x + wing.dx * wingLength, y: headBase.y + wing.dy * wingLength))
        arrow.move(to: leafB)
        arrow.addLine(to: CGPoint(x: headBase.x - wing.dx * wingLength, y: headBase.y - wing.dy * wingLength))
        context.stroke(arrow, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2))
    }

    /// Janela: linha dupla fina atravessando o vão.
    private func drawWindow(in context: inout GraphicsContext, from a: CGPoint, to b: CGPoint) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }

        let normal = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
        let offset = wallWidth / 4

        for sign in [-1.0, 1.0] {
            var line = Path()
            line.move(to: CGPoint(x: a.x + normal.dx * offset * sign, y: a.y + normal.dy * offset * sign))
            line.addLine(to: CGPoint(x: b.x + normal.dx * offset * sign, y: b.y + normal.dy * offset * sign))
            context.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: 1.2))
        }
    }

    // MARK: - Cotas

    private func drawDimensions(in context: inout GraphicsContext, transform: PlanTransform) {
        for index in 0..<scan.wallCount {
            guard let wall = scan.wall(at: index) else { continue }

            let a = transform.point(wall.start)
            let b = transform.point(wall.end)
            let length = WallGeometry.length(from: wall.start, to: wall.end)

            let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let outward = transform.outwardNormal(ofWall: index, in: scan)
            // Afasta o suficiente para limpar a espessura da parede.
            let offset = wallWidth / 2 + 18
            let anchor = CGPoint(
                x: midpoint.x + outward.dx * offset,
                y: midpoint.y + outward.dy * offset
            )

            // Texto paralelo ao segmento. Se ficar de cabeça para baixo, gira
            // meia volta — cota de planta se lê da esquerda para a direita.
            var angle = atan2(b.y - a.y, b.x - a.x)
            if angle > .pi / 2 || angle < -.pi / 2 { angle += .pi }

            context.drawLayer { layer in
                layer.translateBy(x: anchor.x, y: anchor.y)
                layer.rotate(by: .radians(angle))
                drawLabel(
                    in: &layer,
                    text: Format.meters(length),
                    at: .zero,
                    font: .system(size: 12, weight: .medium)
                )
            }
        }
    }

    private func drawAreaLabel(in context: inout GraphicsContext, transform: PlanTransform) {
        guard scan.corners.count >= 3 else { return }
        let center = transform.point(scan.centroidXZ)

        drawLabel(
            in: &context,
            text: Format.squareMeters(scan.floorArea),
            at: center,
            font: .system(size: 19, weight: .semibold)
        )
        drawLabel(
            in: &context,
            text: "perímetro \(Format.meters(scan.perimeter))",
            at: CGPoint(x: center.x, y: center.y + 21),
            font: .system(size: 11),
            color: .black.opacity(0.7)
        )
    }

    /// Desenha texto sobre um retângulo branco opaco.
    ///
    /// É a convenção de desenho técnico: a cota "quebra" o que estiver embaixo em
    /// vez de se misturar com ele. Num cômodo estreito os rótulos inevitavelmente
    /// se aproximam, e sem isso viram um amontoado ilegível.
    private func drawLabel(
        in context: inout GraphicsContext,
        text: String,
        at position: CGPoint,
        font: Font,
        color: Color = .black
    ) {
        let resolved = context.resolve(Text(text).font(font).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 400, height: 100))

        let padding: CGFloat = 3
        let backdrop = CGRect(
            x: position.x - size.width / 2 - padding,
            y: position.y - size.height / 2 - padding,
            width: size.width + 2 * padding,
            height: size.height + 2 * padding
        )
        context.fill(Path(backdrop), with: .color(.white))
        context.draw(resolved, at: position, anchor: .center)
    }

    /// Menor caminho angular entre dois ângulos, para o arco da porta não dar
    /// a volta de 270°.
    private func shortestSweepIsClockwise(from start: Double, to end: Double) -> Bool {
        var delta = end - start
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta < 0
    }
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

/// Mapeia coordenadas do cômodo (metros, plano XZ) para pontos da viewport.
///
/// Faz três coisas, nesta ordem: **gira** para alinhar a parede mais longa à
/// horizontal, **escala** preservando a proporção e **centraliza**.
struct PlanTransform {
    private let rotation: Float
    private let scale: CGFloat
    private let offset: CGPoint
    private let origin: SIMD2<Float>
    private let polygon: [SIMD2<Float>]

    init?(scan: RoomScan, viewport: CGSize, margin: CGFloat) {
        let raw = scan.corners.map(\.xz)
        guard raw.count >= 2 else { return nil }

        // A origem do mundo do ARKit tem heading arbitrário — depende de para
        // onde o celular apontava quando a sessão começou. Desenhar em XZ cru
        // deixa o cômodo torto na folha. Girar pela parede mais longa dá um
        // referencial estável e aproveita melhor o espaço da página.
        //
        // Calculado numa constante local: ler a propriedade dentro do closure do
        // `map` capturaria `self` antes de estar inicializado.
        let angle = -Self.dominantAngle(of: raw, closed: scan.isClosed)
        rotation = angle

        let rotated = raw.map { Self.rotate($0, by: angle) }
        polygon = rotated

        let minimum = rotated.reduce(rotated[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
        let maximum = rotated.reduce(rotated[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
        let span = maximum - minimum
        guard span.x > 1e-4 || span.y > 1e-4 else { return nil }

        let availableWidth = max(viewport.width - 2 * margin, 1)
        let availableHeight = max(viewport.height - 2 * margin, 1)
        let scaleX = span.x > 1e-4 ? availableWidth / CGFloat(span.x) : .greatestFiniteMagnitude
        let scaleY = span.y > 1e-4 ? availableHeight / CGFloat(span.y) : .greatestFiniteMagnitude
        scale = min(scaleX, scaleY)

        origin = minimum
        offset = CGPoint(
            x: (viewport.width - CGFloat(span.x) * scale) / 2,
            y: (viewport.height - CGFloat(span.y) * scale) / 2
        )
    }

    /// Ângulo da parede mais longa. É a referência que fica horizontal.
    private static func dominantAngle(of points: [SIMD2<Float>], closed: Bool) -> Float {
        let count = closed ? points.count : points.count - 1
        guard count > 0 else { return 0 }

        var bestAngle: Float = 0
        var bestLength: Float = 0
        for index in 0..<count {
            let delta = points[(index + 1) % points.count] - points[index]
            let length = simd_length(delta)
            if length > bestLength {
                bestLength = length
                bestAngle = atan2(delta.y, delta.x)
            }
        }
        return bestAngle
    }

    private static func rotate(_ point: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2<Float>(point.x * c - point.y * s, point.x * s + point.y * c)
    }

    func point(_ corner: SIMD3<Float>) -> CGPoint { point(corner.xz) }

    /// Vista de cima: X do mundo (já girado) vai para a direita, Z para baixo.
    func point(_ planar: SIMD2<Float>) -> CGPoint {
        let rotated = Self.rotate(planar, by: rotation)
        return CGPoint(
            x: offset.x + CGFloat(rotated.x - origin.x) * scale,
            y: offset.y + CGFloat(rotated.y - origin.y) * scale
        )
    }

    /// Normal da parede apontando para **fora** do polígono, em coordenadas de tela.
    ///
    /// Decide o lado testando se um ponto deslocado cai dentro do polígono, em vez
    /// de deduzir do sinal da área. A dedução por sinal erra: a área é calculada na
    /// convenção matemática (Y para cima) e aplicada na tela, cujo Y cresce para
    /// baixo — a inversão troca o handedness e joga todas as cotas para dentro.
    func outwardNormal(ofWall index: Int, in scan: RoomScan) -> CGVector {
        guard let wall = scan.wall(at: index) else { return CGVector(dx: 0, dy: -1) }

        let startPlanar = Self.rotate(wall.start.xz, by: rotation)
        let endPlanar = Self.rotate(wall.end.xz, by: rotation)
        let delta = endPlanar - startPlanar
        let length = simd_length(delta)
        guard length > 1e-5 else { return CGVector(dx: 0, dy: -1) }

        let normal = SIMD2<Float>(-delta.y / length, delta.x / length)
        let midpoint = (startPlanar + endPlanar) / 2
        // Amostra a poucos centímetros da parede: perto o suficiente para não
        // atravessar o cômodo e cair fora pelo outro lado.
        let probe = midpoint + normal * 0.05

        let pointsOutward = !PolygonMath.contains(probe, polygon: polygon)
        let sign: Float = pointsOutward ? 1 : -1

        // Os eixos da tela acompanham os do plano girado, então a normal
        // transporta diretamente.
        return CGVector(dx: CGFloat(normal.x * sign), dy: CGFloat(normal.y * sign))
    }

    func inwardNormal(ofWall index: Int, in scan: RoomScan) -> CGVector {
        let outward = outwardNormal(ofWall: index, in: scan)
        return CGVector(dx: -outward.dx, dy: -outward.dy)
    }
}
