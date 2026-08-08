import SwiftUI
import simd

/// Floor plan drawn with `Canvas`.
///
/// Technical-drawing style: white background, black stroke, no shadow and no
/// decorative colour. This is what goes into the PDF, so it has to read well in
/// print. User-facing copy stays in Brazilian Portuguese, as the spec requires.
struct FloorPlanView: View {
    let scan: RoomScan

    /// Extra rotation applied on top of the automatic orientation.
    ///
    /// The plan already aligns itself by the longest wall; this is the user's
    /// adjustment over that. It applies to both the screen and the PDF —
    /// rotating the view alone would be useless, since the reason to rotate is
    /// to export at the right orientation.
    var rotation: Angle = .zero

    /// Wall thickness in the drawing, in points.
    private let wallWidth: CGFloat = 8
    /// Margin around the drawing, so the dimension labels fit.
    private let margin: CGFloat = 56

    var body: some View {
        Canvas { context, size in
            guard scan.corners.count >= 2,
                  let transform = PlanTransform(
                      scan: scan,
                      viewport: size,
                      margin: margin,
                      extraRotation: rotation
                  ) else { return }

            drawWalls(in: &context, transform: transform)
            drawOpenings(in: &context, transform: transform)
            drawDimensions(in: &context, transform: transform)
            drawAreaLabel(in: &context, transform: transform)
        }
        .background(.white)
    }

    // MARK: - Walls

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

    // MARK: - Doors, windows and openings

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

            // Open the gap by erasing that stretch of wall with the background
            // colour, rather than drawing the wall in pieces. Simpler, same result.
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
                // An open passage is just the absence of wall: the jambs suffice.
                break
            case .window:
                drawWindow(in: &context, from: a, to: b)
            }
        }
    }

    /// Jambs: the strokes closing the opening's sides.
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

    /// Swing door: leaf open at 90° plus the sweep arc.
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

    /// Sliding door: the leaf drawn as a thin panel parallel to the wall,
    /// offset to the side it slides along.
    ///
    /// **No arrow.** Architectural convention represents a sliding door by the
    /// panel itself, not by an indication of movement. Wide openings get two
    /// half-width leaves, slightly offset from each other — which is how a
    /// two-leaf sliding door is drawn.
    private func drawSlidingDoor(
        in context: inout GraphicsContext,
        from a: CGPoint,
        to b: CGPoint,
        inwardNormal: CGVector
    ) {
        let width = hypot(b.x - a.x, b.y - a.y)
        guard width > 0.5 else { return }

        let direction = CGVector(dx: (b.x - a.x) / width, dy: (b.y - a.y) / width)
        let leafThickness = wallWidth * 0.42

        /// Panel spanning two fractions of the opening, offset from the wall line.
        func panel(from startFraction: CGFloat, to endFraction: CGFloat, offset: CGFloat) {
            let p1 = CGPoint(
                x: a.x + direction.dx * width * startFraction + inwardNormal.dx * offset,
                y: a.y + direction.dy * width * startFraction + inwardNormal.dy * offset
            )
            let p2 = CGPoint(
                x: a.x + direction.dx * width * endFraction + inwardNormal.dx * offset,
                y: a.y + direction.dy * width * endFraction + inwardNormal.dy * offset
            )
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(
                path,
                with: .color(.black),
                style: StrokeStyle(lineWidth: leafThickness, lineCap: .butt)
            )
        }

        if width >= twoLeafScreenWidth {
            // Two leaves: each covers half the opening, on distinct planes.
            panel(from: 0, to: 0.52, offset: leafThickness * 0.6)
            panel(from: 0.48, to: 1, offset: leafThickness * 1.7)
        } else {
            panel(from: 0, to: 1, offset: leafThickness * 1.1)
        }
    }

    /// Past this on-screen width the opening is drawn with two leaves.
    private var twoLeafScreenWidth: CGFloat { 46 }

    /// Window: thin double line across the opening.
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

    // MARK: - Dimension labels

    private func drawDimensions(in context: inout GraphicsContext, transform: PlanTransform) {
        for index in 0..<scan.wallCount {
            guard let wall = scan.wall(at: index) else { continue }

            let a = transform.point(wall.start)
            let b = transform.point(wall.end)
            let length = WallGeometry.length(from: wall.start, to: wall.end)

            let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let outward = transform.outwardNormal(ofWall: index, in: scan)
            // Offset far enough to clear the wall's thickness.
            let offset = wallWidth / 2 + 18
            let anchor = CGPoint(
                x: midpoint.x + outward.dx * offset,
                y: midpoint.y + outward.dy * offset
            )

            // Text parallel to the segment. If it ends up upside down, turn it
            // half a turn — plan dimensions read left to right.
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

    /// Area label at the centroid — but only if it fits inside the room.
    ///
    /// The label's white backdrop erases whatever is underneath. In a narrow
    /// room the text overruns the walls, and the backdrop punched holes in the
    /// stroke. Rather than dropping the backdrop (which is what keeps labels
    /// legible where they cross), the label moves out of the drawing when it
    /// doesn't fit — as a real plan does for small spaces.
    ///
    /// The perimeter left the drawing for good: it already appears in the
    /// measurements panel and the PDF header, and in the centre it only competed
    /// for space with the area.
    private func drawAreaLabel(in context: inout GraphicsContext, transform: PlanTransform) {
        guard scan.corners.count >= 3 else { return }

        let font = Font.system(size: 19, weight: .semibold)
        let text = Format.squareMeters(scan.floorArea)
        let resolved = context.resolve(Text(text).font(font).foregroundStyle(Color.black))
        let size = resolved.measure(in: CGSize(width: 400, height: 100))

        let center = transform.point(scan.centroidXZ)
        let padding: CGFloat = 4
        let halfWidth = size.width / 2 + padding
        let halfHeight = size.height / 2 + padding

        // Does the label's rectangle fit inside the polygon, clear of the wall stroke?
        let clearance = wallWidth / 2 + 2
        let fits = [
            CGPoint(x: center.x - halfWidth - clearance, y: center.y - halfHeight - clearance),
            CGPoint(x: center.x + halfWidth + clearance, y: center.y - halfHeight - clearance),
            CGPoint(x: center.x + halfWidth + clearance, y: center.y + halfHeight + clearance),
            CGPoint(x: center.x - halfWidth - clearance, y: center.y + halfHeight + clearance),
        ].allSatisfy { transform.containsScreenPoint($0, in: scan) }

        let anchor = fits
            ? center
            : CGPoint(x: transform.drawingBounds.midX, y: transform.drawingBounds.minY - halfHeight - 26)

        drawLabel(in: &context, text: text, at: anchor, font: font)
    }

    /// Draws text over an opaque white rectangle.
    ///
    /// This is the technical-drawing convention: the dimension text "breaks"
    /// whatever lies underneath instead of blending into it. In a narrow room the
    /// labels inevitably crowd each other, and without this they turn into an
    /// unreadable pile.
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

    /// Shortest angular path between two angles, so the door arc doesn't take
    /// the 270° way around.
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

/// Maps room coordinates (metres, XZ plane) to viewport points.
///
/// Does three things, in this order: **rotates** to align the longest wall to
/// the horizontal, **scales** preserving the aspect ratio, and **centres**.
struct PlanTransform {
    private let rotation: Float
    private let scale: CGFloat
    private let offset: CGPoint
    private let origin: SIMD2<Float>
    private let polygon: [SIMD2<Float>]

    init?(scan: RoomScan, viewport: CGSize, margin: CGFloat, extraRotation: Angle = .zero) {
        let raw = scan.corners.map(\.xz)
        guard raw.count >= 2 else { return nil }

        // ARKit's world origin has an arbitrary heading — it depends on where
        // the phone pointed when the session started. Drawing raw XZ leaves the
        // room skewed on the page. Rotating by the longest wall gives a stable
        // reference and makes better use of the page.
        //
        // The manual adjustment is summed in here rather than applied as a
        // draw-time transform: this way the bounding box is recomputed already
        // rotated, and the plan keeps filling the whole page at any orientation.
        //
        // Computed into a local constant: reading the property inside the `map`
        // closure would capture `self` before it is initialised.
        let angle = -Self.dominantAngle(of: raw, closed: scan.isClosed) + Float(extraRotation.radians)
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

    /// Normalises to (−180°, 180°] and snaps to multiples of 90° when already
    /// close to one.
    ///
    /// A technical plan almost always wants an orthogonal orientation, and
    /// hitting exactly 90° with two fingers is impossible. The tolerance is
    /// narrow enough not to block a deliberately oblique angle.
    static func snapRotation(_ angle: Angle, tolerance: Double = 7) -> Angle {
        var degrees = angle.degrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees <= -180 { degrees += 360 }

        let nearestRightAngle = (degrees / 90).rounded() * 90
        guard abs(degrees - nearestRightAngle) <= tolerance else { return .degrees(degrees) }

        // 180 and −180 are the same angle; pick the positive form.
        return .degrees(nearestRightAngle == -180 ? 180 : nearestRightAngle)
    }

    /// Angle of the longest wall. That is the reference which ends up horizontal.
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

    /// Rectangle the drawing occupies within the viewport.
    var drawingBounds: CGRect {
        let minimum = polygon.reduce(polygon[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
        let maximum = polygon.reduce(polygon[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
        return CGRect(
            x: offset.x,
            y: offset.y,
            width: CGFloat(maximum.x - minimum.x) * scale,
            height: CGFloat(maximum.y - minimum.y) * scale
        )
    }

    /// Whether a **screen** point falls inside the room. Converts back to the
    /// rotated plane and reuses the same containment test as the dimension labels.
    func containsScreenPoint(_ point: CGPoint, in scan: RoomScan) -> Bool {
        guard scale > 0 else { return false }
        let planar = SIMD2<Float>(
            Float((point.x - offset.x) / scale) + origin.x,
            Float((point.y - offset.y) / scale) + origin.y
        )
        return PolygonMath.contains(planar, polygon: polygon)
    }

    func point(_ corner: SIMD3<Float>) -> CGPoint { point(corner.xz) }

    /// Top-down view: world X (already rotated) goes right, Z goes down.
    func point(_ planar: SIMD2<Float>) -> CGPoint {
        let rotated = Self.rotate(planar, by: rotation)
        return CGPoint(
            x: offset.x + CGFloat(rotated.x - origin.x) * scale,
            y: offset.y + CGFloat(rotated.y - origin.y) * scale
        )
    }

    /// Wall normal pointing **outward** from the polygon, in screen coordinates.
    ///
    /// Decides the side by testing whether an offset point falls inside the
    /// polygon, rather than deriving it from the sign of the area. Deriving it
    /// from the sign gets it wrong: the area is computed in the mathematical
    /// convention (Y up) and applied on screen, where Y grows downward — the flip
    /// swaps handedness and throws every label inside the room.
    func outwardNormal(ofWall index: Int, in scan: RoomScan) -> CGVector {
        guard let wall = scan.wall(at: index) else { return CGVector(dx: 0, dy: -1) }

        let startPlanar = Self.rotate(wall.start.xz, by: rotation)
        let endPlanar = Self.rotate(wall.end.xz, by: rotation)
        let delta = endPlanar - startPlanar
        let length = simd_length(delta)
        guard length > 1e-5 else { return CGVector(dx: 0, dy: -1) }

        let normal = SIMD2<Float>(-delta.y / length, delta.x / length)
        let midpoint = (startPlanar + endPlanar) / 2
        // Probe a few centimetres from the wall: close enough not to cross the
        // room and land outside on the far side.
        let probe = midpoint + normal * 0.05

        let pointsOutward = !PolygonMath.contains(probe, polygon: polygon)
        let sign: Float = pointsOutward ? 1 : -1

        // The screen axes follow those of the rotated plane, so the normal
        // carries over directly.
        return CGVector(dx: CGFloat(normal.x * sign), dy: CGFloat(normal.y * sign))
    }

    func inwardNormal(ofWall index: Int, in scan: RoomScan) -> CGVector {
        let outward = outwardNormal(ofWall: index, in: scan)
        return CGVector(dx: -outward.dx, dy: -outward.dy)
    }
}
