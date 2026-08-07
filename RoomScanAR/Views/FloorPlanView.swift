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
                      corners: scan.corners,
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

    // MARK: - Portas e janelas

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

            switch opening.type {
            case .door:  drawDoor(in: &context, from: a, to: b, inwardNormal: transform.inwardNormal(ofWall: opening.wallIndex, in: scan))
            case .window: drawWindow(in: &context, from: a, to: b)
            }
        }
    }

    /// Porta: batente, folha aberta a 90° e arco de varredura.
    private func drawDoor(
        in context: inout GraphicsContext,
        from a: CGPoint,
        to b: CGPoint,
        inwardNormal: CGVector
    ) {
        let width = hypot(b.x - a.x, b.y - a.y)
        guard width > 0.5 else { return }

        // Marca as ombreiras do vão.
        var jambs = Path()
        jambs.move(to: a)
        jambs.addLine(to: b)
        context.stroke(jambs, with: .color(.black), style: StrokeStyle(lineWidth: 1))

        // Folha da porta: perpendicular à parede, apontando para dentro.
        let leafEnd = CGPoint(
            x: a.x + inwardNormal.dx * width,
            y: a.y + inwardNormal.dy * width
        )
        var leaf = Path()
        leaf.move(to: a)
        leaf.addLine(to: leafEnd)
        context.stroke(leaf, with: .color(.black), style: StrokeStyle(lineWidth: 2))

        // Arco de 90° do batente até a folha aberta.
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

    /// Janela: linha dupla fina atravessando o vão.
    private func drawWindow(in context: inout GraphicsContext, from a: CGPoint, to b: CGPoint) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }

        // Normal unitária ao vão, para deslocar as duas linhas.
        let normal = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
        let offset = wallWidth / 4

        for sign in [-1.0, 1.0] {
            var line = Path()
            line.move(to: CGPoint(x: a.x + normal.dx * offset * sign, y: a.y + normal.dy * offset * sign))
            line.addLine(to: CGPoint(x: b.x + normal.dx * offset * sign, y: b.y + normal.dy * offset * sign))
            context.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: 1.2))
        }

        // Ombreiras.
        var jambs = Path()
        jambs.move(to: CGPoint(x: a.x + normal.dx * wallWidth / 2, y: a.y + normal.dy * wallWidth / 2))
        jambs.addLine(to: CGPoint(x: a.x - normal.dx * wallWidth / 2, y: a.y - normal.dy * wallWidth / 2))
        jambs.move(to: CGPoint(x: b.x + normal.dx * wallWidth / 2, y: b.y + normal.dy * wallWidth / 2))
        jambs.addLine(to: CGPoint(x: b.x - normal.dx * wallWidth / 2, y: b.y - normal.dy * wallWidth / 2))
        context.stroke(jambs, with: .color(.black), style: StrokeStyle(lineWidth: 1))
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
            let offset: CGFloat = 22
            let anchor = CGPoint(
                x: midpoint.x + outward.dx * offset,
                y: midpoint.y + outward.dy * offset
            )

            // Texto paralelo ao segmento. Se ficar de cabeça para baixo, gira
            // meia volta — cota de planta se lê da esquerda para a direita.
            var angle = atan2(b.y - a.y, b.x - a.x)
            if angle > .pi / 2 || angle < -.pi / 2 { angle += .pi }

            let text = Text(Format.meters(length))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black)

            context.drawLayer { layer in
                layer.translateBy(x: anchor.x, y: anchor.y)
                layer.rotate(by: .radians(angle))
                layer.draw(text, at: .zero, anchor: .center)
            }
        }
    }

    private func drawAreaLabel(in context: inout GraphicsContext, transform: PlanTransform) {
        guard scan.corners.count >= 3 else { return }
        let center = transform.point(scan.centroidXZ)

        let area = Text(Format.squareMeters(scan.floorArea))
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.black)
        context.draw(area, at: center, anchor: .center)

        let perimeter = Text("perímetro \(Format.meters(scan.perimeter))")
            .font(.system(size: 12))
            .foregroundStyle(.black.opacity(0.7))
        context.draw(perimeter, at: CGPoint(x: center.x, y: center.y + 22), anchor: .center)
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

/// Mapeia coordenadas do cômodo (metros, plano XZ) para pontos da viewport.
///
/// Preserva a proporção: escalar X e Z de forma diferente distorceria os ângulos
/// e a planta deixaria de ser uma planta.
struct PlanTransform {
    private let scale: CGFloat
    private let offset: CGPoint
    private let origin: SIMD2<Float>

    init?(corners: [SIMD3<Float>], viewport: CGSize, margin: CGFloat) {
        let points = corners.map(\.xz)
        guard !points.isEmpty else { return nil }

        let minimum = points.reduce(points[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
        let maximum = points.reduce(points[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
        let span = maximum - minimum

        let availableWidth = max(viewport.width - 2 * margin, 1)
        let availableHeight = max(viewport.height - 2 * margin, 1)
        guard span.x > 1e-4 || span.y > 1e-4 else { return nil }

        let scaleX = span.x > 1e-4 ? availableWidth / CGFloat(span.x) : .greatestFiniteMagnitude
        let scaleY = span.y > 1e-4 ? availableHeight / CGFloat(span.y) : .greatestFiniteMagnitude
        scale = min(scaleX, scaleY)

        origin = minimum
        // Centraliza o desenho na viewport.
        let drawnWidth = CGFloat(span.x) * scale
        let drawnHeight = CGFloat(span.y) * scale
        offset = CGPoint(
            x: (viewport.width - drawnWidth) / 2,
            y: (viewport.height - drawnHeight) / 2
        )
    }

    func point(_ corner: SIMD3<Float>) -> CGPoint { point(corner.xz) }

    /// Vista de cima: X do mundo vai para a direita, Z do mundo vai para baixo.
    func point(_ planar: SIMD2<Float>) -> CGPoint {
        CGPoint(
            x: offset.x + CGFloat(planar.x - origin.x) * scale,
            y: offset.y + CGFloat(planar.y - origin.y) * scale
        )
    }

    /// Normal da parede apontando para **fora** do polígono, em coordenadas de tela.
    ///
    /// Depende do sentido de percurso dos cantos, que o usuário escolhe sem saber:
    /// o sinal da área com sinal diz se a marcação foi horária ou anti-horária.
    func outwardNormal(ofWall index: Int, in scan: RoomScan) -> CGVector {
        guard let wall = scan.wall(at: index) else { return CGVector(dx: 0, dy: -1) }
        let a = point(wall.start)
        let b = point(wall.end)
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1e-4 else { return CGVector(dx: 0, dy: -1) }

        let normal = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
        let sign: CGFloat = PolygonMath.signedArea(scan.corners) > 0 ? 1 : -1
        return CGVector(dx: normal.dx * sign, dy: normal.dy * sign)
    }

    func inwardNormal(ofWall index: Int, in scan: RoomScan) -> CGVector {
        let outward = outwardNormal(ofWall: index, in: scan)
        return CGVector(dx: -outward.dx, dy: -outward.dy)
    }
}
