import Testing
import SwiftUI
import simd
@testable import RoomScanAR

/// Tests for the pure geometry: points in, numbers out. Since none of it
/// imports ARKit, this bundle runs in the Simulator even though the app itself
/// is physical-device only.

/// Comparison tolerance. Loose enough for `Float` noise, tight enough to catch
/// a formula error.
private let epsilon: Float = 1e-4

private func expectClose(
    _ actual: Float,
    _ expected: Float,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) < epsilon,
        comment ?? "expected \(expected), got \(actual)",
        sourceLocation: sourceLocation
    )
}

private func p(_ x: Float, _ z: Float) -> SIMD2<Float> { SIMD2<Float>(x, z) }

@Suite("Shoelace area")
struct ShoelaceTests {

    @Test("A 1 m square has an area of 1 m²")
    func unitSquare() {
        let square = [p(0, 0), p(1, 0), p(1, 1), p(0, 1)]
        expectClose(PolygonMath.area(square), 1.0)
    }

    @Test("L-shaped polygon of known area")
    func lShaped() {
        // A 3×1 rectangle with a 1×1 square added at the top-left corner.
        // Geometric area: 3 + 1 = 4 m².
        let shape = [p(0, 0), p(3, 0), p(3, 1), p(1, 1), p(1, 2), p(0, 2)]
        expectClose(PolygonMath.area(shape), 4.0)
    }

    @Test("Area is positive in both winding directions")
    func windingIndependence() {
        let counterClockwise = [p(0, 0), p(2, 0), p(2, 3), p(0, 3)]
        let clockwise = Array(counterClockwise.reversed())

        expectClose(PolygonMath.area(counterClockwise), 6.0)
        expectClose(PolygonMath.area(clockwise), 6.0)

        // The signed area, by contrast, tells them apart — it is where the floor
        // plan and the orthogonal snap get their orientation from.
        #expect(PolygonMath.signedArea(counterClockwise) * PolygonMath.signedArea(clockwise) < 0)
    }

    @Test("Precision holds far from the session origin")
    func farFromOrigin() {
        // A long AR session pushes corners tens of metres from the origin.
        // Without translating before summing, the Float shoelace loses digits here.
        let offset = p(850, -1240)
        let square = [p(0, 0), p(1, 0), p(1, 1), p(0, 1)].map { $0 + offset }
        expectClose(PolygonMath.area(square), 1.0)
    }

    @Test("Fewer than three corners have no area")
    func degenerate() {
        expectClose(PolygonMath.area([SIMD2<Float>]()), 0)
        expectClose(PolygonMath.area([p(0, 0)]), 0)
        expectClose(PolygonMath.area([p(0, 0), p(1, 0)]), 0)
    }

    @Test("Collinear corners give zero area")
    func collinear() {
        expectClose(PolygonMath.area([p(0, 0), p(1, 0), p(2, 0)]), 0)
    }
}

@Suite("Point in polygon")
struct ContainsTests {

    private let square = [p(0, 0), p(4, 0), p(4, 3), p(0, 3)]

    @Test("The centre is inside")
    func center() {
        #expect(PolygonMath.contains(p(2, 1.5), polygon: square))
    }

    @Test("Points outside, on all four sides")
    func outside() {
        #expect(!PolygonMath.contains(p(-1, 1.5), polygon: square))
        #expect(!PolygonMath.contains(p(5, 1.5), polygon: square))
        #expect(!PolygonMath.contains(p(2, -1), polygon: square))
        #expect(!PolygonMath.contains(p(2, 4), polygon: square))
    }

    @Test("The result is independent of winding")
    func windingIndependent() {
        let reversed = Array(square.reversed())
        #expect(PolygonMath.contains(p(2, 1.5), polygon: reversed))
        #expect(!PolygonMath.contains(p(5, 1.5), polygon: reversed))
    }

    @Test("An L's notch stays outside")
    func concave() {
        let shape = [p(0, 0), p(3, 0), p(3, 1), p(1, 1), p(1, 2), p(0, 2)]
        #expect(PolygonMath.contains(p(0.5, 1.5), polygon: shape))
        // This point is inside the bounding rectangle, but outside the L.
        #expect(!PolygonMath.contains(p(2.5, 1.8), polygon: shape))
    }

    @Test("A probe offset from the wall picks the outward side")
    func probeDetectsOutside() {
        // Exactly what the floor plan does to orient its dimension labels: offset
        // 5 cm from the wall midpoint and test whether it landed inside.
        // Bottom wall of the square, from (0,0) to (4,0): outside is y < 0.
        #expect(!PolygonMath.contains(p(2, -0.05), polygon: square))
        #expect(PolygonMath.contains(p(2, 0.05), polygon: square))
    }

    @Test("In a narrow room the probe doesn't cross to the far side")
    func narrowRoom() {
        // The case from the screenshot: 4.28 × 0.87 m. A 5 cm probe has to stay
        // inside and not exit through the opposite wall.
        let narrow = [p(0, 0), p(4.28, 0), p(4.28, 0.87), p(0, 0.87)]
        #expect(PolygonMath.contains(p(2.14, 0.05), polygon: narrow))
        #expect(!PolygonMath.contains(p(2.14, -0.05), polygon: narrow))
        #expect(PolygonMath.contains(p(2.14, 0.82), polygon: narrow))
        #expect(!PolygonMath.contains(p(2.14, 0.92), polygon: narrow))
    }

    @Test("Fewer than three points contain nothing")
    func degenerate() {
        #expect(!PolygonMath.contains(p(0, 0), polygon: [p(0, 0), p(1, 1)]))
    }
}

@Suite("Opening types")
struct OpeningTypeTests {

    @Test("Only the window has a sill")
    func sill() {
        #expect(!OpeningType.door.hasSill)
        #expect(!OpeningType.slidingDoor.hasSill)
        #expect(!OpeningType.openGap.hasSill)
        #expect(OpeningType.window.hasSill)
    }

    @Test("A narrow opening suggests a swing door; a wide one, a sliding door")
    func suggestion() {
        #expect(OpeningType.suggested(forWidth: 0.80) == .door)
        #expect(OpeningType.suggested(forWidth: 1.19) == .door)
        #expect(OpeningType.suggested(forWidth: 1.20) == .slidingDoor)
        #expect(OpeningType.suggested(forWidth: 2.40) == .slidingDoor)
    }

    @Test("Doors and passages run down to the floor")
    func defaults() {
        for type in [OpeningType.door, .slidingDoor, .openGap] {
            expectClose(type.defaultSillHeight, 0)
            expectClose(type.defaultHeight, 2.10)
        }
        expectClose(OpeningType.window.defaultSillHeight, 1.10)
        expectClose(OpeningType.window.defaultHeight, 1.20)
    }

    @Test("An open passage produces the same panels as a door")
    func openGapPanels() {
        // No sill: the difference between an open passage and a door is purely
        // symbolic, in the 2D plan and the frame colour — the wall is cut the same.
        let panels = WallMeshBuilder.panels(
            from: SIMD3<Float>(0, 0, 0), to: SIMD3<Float>(4, 0, 0),
            ceilingHeight: 2.60,
            cutouts: [.init(distance: 1.0, width: 1.60, sill: 0, top: 2.10)]
        )
        #expect(panels.count == 3)
        #expect(!panels.contains { $0.bottom < 1e-4 && $0.top < 2.0 })
    }
}

@Suite("Perimeter")
struct PerimeterTests {

    @Test("A closed 3×4 rectangle has a perimeter of 14 m")
    func rectangle() {
        let rectangle = [p(0, 0), p(3, 0), p(3, 4), p(0, 4)]
        expectClose(PolygonMath.perimeter(rectangle, closed: true), 14.0)
    }

    @Test("Open, the 3×4 rectangle excludes the closing segment")
    func openRectangle() {
        let rectangle = [p(0, 0), p(3, 0), p(3, 4), p(0, 4)]
        // 3 + 4 + 3 = 10; the closing side of 4 is missing.
        expectClose(PolygonMath.perimeter(rectangle, closed: false), 10.0)
    }

    @Test("Individual lengths come out in corner order")
    func segments() {
        let rectangle = [p(0, 0), p(3, 0), p(3, 4), p(0, 4)]
        let lengths = PolygonMath.segmentLengths(rectangle, closed: true)
        #expect(lengths.count == 4)
        expectClose(lengths[0], 3)
        expectClose(lengths[1], 4)
        expectClose(lengths[2], 3)
        expectClose(lengths[3], 4)
    }

    @Test("A lone corner has no segments")
    func singleCorner() {
        #expect(PolygonMath.segmentLengths([p(0, 0)], closed: false).isEmpty)
    }
}

@Suite("Centroid")
struct CentroidTests {

    @Test("A square's centroid is its centre")
    func square() {
        let square = [p(0, 0), p(2, 0), p(2, 2), p(0, 2)]
        let center = PolygonMath.centroid(square)
        expectClose(center.x, 1.0)
        expectClose(center.y, 1.0)
    }

    @Test("In an L, the centre of mass differs from the vertex mean")
    func lShaped() {
        let shape = [p(0, 0), p(3, 0), p(3, 1), p(1, 1), p(1, 2), p(0, 2)]
        let center = PolygonMath.centroid(shape)
        let vertexMean = shape.reduce(SIMD2<Float>.zero, +) / Float(shape.count)

        // Centre of mass of two parts: a 3×1 rectangle (area 3, centre (1.5, 0.5))
        // and a 1×1 square (area 1, centre (0.5, 1.5)).
        // x = (3·1.5 + 1·0.5) / 4 = 1.25    y = (3·0.5 + 1·1.5) / 4 = 0.75
        expectClose(center.x, 1.25)
        expectClose(center.y, 0.75)
        #expect(abs(center.x - vertexMean.x) > 0.01 || abs(center.y - vertexMean.y) > 0.01)
    }

    @Test("Collinear corners fall back to the vertex mean")
    func collinearFallback() {
        let line = [p(0, 0), p(1, 0), p(2, 0)]
        let center = PolygonMath.centroid(line)
        expectClose(center.x, 1.0)
        expectClose(center.y, 0.0)
    }
}

@Suite("Wall area")
struct WallAreaTests {

    @Test("Net area deducts the openings")
    func netArea() {
        // 14 m of perimeter × 2.60 m = 36.40 m²; less 1.68 m² of openings.
        expectClose(
            PolygonMath.netWallArea(perimeter: 14, ceilingHeight: 2.60, openingsArea: 1.68),
            34.72
        )
    }

    @Test("Openings larger than the wall don't produce negative area")
    func clampedAtZero() {
        expectClose(
            PolygonMath.netWallArea(perimeter: 1, ceilingHeight: 2.60, openingsArea: 100),
            0
        )
    }
}

@Suite("Orthogonal snap")
struct OrthogonalSnapTests {

    /// Angle between consecutive segments, in degrees.
    private func turnAngles(_ points: [SIMD2<Float>]) -> [Float] {
        (0..<points.count).map { index in
            let a = points[(index + 1) % points.count] - points[index]
            let b = points[(index + 2) % points.count] - points[(index + 1) % points.count]
            let cosine = simd_dot(simd_normalize(a), simd_normalize(b))
            return acos(min(max(cosine, -1), 1)) * 180 / .pi
        }
    }

    @Test("A slightly skewed square converges to 90°")
    func crookedSquare() {
        // A 3 m square with its corners nudged a few centimetres, which is what
        // a real marking produces.
        let crooked = [
            p(0.00, 0.00),
            p(3.04, 0.07),
            p(2.96, 3.05),
            p(-0.05, 2.98),
        ]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("the snap should have been applied")
            return
        }

        #expect(result.corners.count == 4)
        for angle in turnAngles(result.corners) {
            expectClose(angle, 90, "angle of \(angle)° should be a right angle")
        }
    }

    @Test("After snapping, the polygon closes exactly")
    func closesExactly() {
        let crooked = [p(0, 0), p(4.03, 0.05), p(3.98, 2.51), p(-0.04, 2.47)]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("the snap should have been applied")
            return
        }

        // Walking every segment has to return to the starting point.
        var walk = SIMD2<Float>.zero
        for index in result.corners.indices {
            walk += result.corners[(index + 1) % result.corners.count] - result.corners[index]
        }
        expectClose(simd_length(walk), 0, "residual closure error of \(simd_length(walk)) m")
    }

    @Test("The snap preserves the first corner")
    func preservesFirstCorner() {
        let crooked = [p(1, 2), p(4.03, 2.05), p(3.98, 4.51), p(0.96, 4.47)]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("the snap should have been applied")
            return
        }
        expectClose(result.corners[0].x, 1)
        expectClose(result.corners[0].y, 2)
    }

    @Test("Area barely changes on a slightly skewed square")
    func areaIsPreserved() {
        let crooked = [p(0, 0), p(3.04, 0.07), p(2.96, 3.05), p(-0.05, 2.98)]
        let before = PolygonMath.area(crooked)

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("the snap should have been applied")
            return
        }
        let after = PolygonMath.area(result.corners)
        #expect(abs(after - before) / before < 0.05, "area went from \(before) to \(after)")
    }

    @Test("A very irregular polygon is rejected")
    func rejectsIrregular() {
        // A triangle has no way to become rectangular: the 60° angles round to
        // 90° and the closure error blows past the limit.
        let triangle = [p(0, 0), p(4, 0), p(2, 3.46)]

        guard case .failure(let failure) = OrthogonalSnap.snap(triangle) else {
            Issue.record("the snap should have been rejected")
            return
        }
        // Rejected for residual error or for an unbalanced axis — both are
        // legitimate refusals for this shape.
        #expect(failure != .notEnoughCorners)
    }

    @Test("Fewer than three corners is rejected")
    func rejectsTooFewCorners() {
        guard case .failure(let failure) = OrthogonalSnap.snap([p(0, 0), p(1, 0)]) else {
            Issue.record("should have been rejected")
            return
        }
        #expect(failure == .notEnoughCorners)
    }

    @Test("A slightly skewed L-shaped room also converges")
    func crookedLShape() {
        let crooked = [
            p(0.00, 0.00),
            p(3.03, 0.04),
            p(2.98, 1.02),
            p(1.01, 0.99),
            p(0.97, 2.03),
            p(-0.03, 1.98),
        ]

        guard case .success(let result) = OrthogonalSnap.snap(crooked) else {
            Issue.record("the snap should have been applied")
            return
        }
        for angle in turnAngles(result.corners) {
            expectClose(angle, 90, "angle of \(angle)° should be a right angle")
        }
    }
}

@Suite("Wall panels")
struct WallPanelTests {

    private let start = SIMD3<Float>(0, 0, 0)
    private let end = SIMD3<Float>(4, 0, 0)
    private let ceiling: Float = 2.60

    @Test("A wall with no openings is a single full-height panel")
    func solidWall() {
        let panels = WallMeshBuilder.panels(from: start, to: end, ceilingHeight: ceiling)
        #expect(panels.count == 1)
        expectClose(panels[0].bottom, 0)
        expectClose(panels[0].top, ceiling)
    }

    @Test("A door produces left panel, right panel and header")
    func door() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 1.0, width: 0.80, sill: 0, top: 2.10)]
        )
        // No sill: left (0→1), header (1→1.8 above 2.10), right (1.8→4).
        #expect(panels.count == 3)
        // No panel covers the opening at walking height.
        let atDoorHeight = panels.filter { $0.bottom < 1.0 && $0.top > 1.0 }
        for panel in atDoorHeight {
            let coversGap = panel.start.x < 1.79 && panel.end.x > 1.01
            #expect(!coversGap, "a panel closes the doorway")
        }
    }

    @Test("A window produces a sill panel as well as a header")
    func window() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 1.5, width: 1.20, sill: 1.10, top: 2.30)]
        )
        // Left, sill panel, header, right.
        #expect(panels.count == 4)
        #expect(panels.contains { abs($0.bottom - 0) < 1e-4 && abs($0.top - 1.10) < 1e-4 })
        #expect(panels.contains { abs($0.bottom - 2.30) < 1e-4 && abs($0.top - ceiling) < 1e-4 })
    }

    @Test("An opening reaching the ceiling produces no header")
    func openingUpToCeiling() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 1.0, width: 1.0, sill: 0, top: ceiling)]
        )
        #expect(panels.count == 2)
    }

    @Test("An opening wider than the wall is clamped, with no negative-length panel")
    func oversizedOpening() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [.init(distance: 3.5, width: 10, sill: 0, top: 2.10)]
        )
        for panel in panels {
            let length = simd_distance(panel.start, panel.end)
            #expect(length > 0, "panel with length \(length)")
            #expect(panel.top >= panel.bottom)
        }
    }

    @Test("Two openings on one wall produce the solid stretch between them")
    func twoOpenings() {
        let panels = WallMeshBuilder.panels(
            from: start, to: end, ceilingHeight: ceiling,
            cutouts: [
                .init(distance: 2.4, width: 0.9, sill: 1.10, top: 2.30),
                .init(distance: 0.5, width: 0.8, sill: 0, top: 2.10),
            ]
        )
        // The openings go in out of order on purpose: the algorithm must sort them.
        let fullHeight = panels.filter { $0.bottom < 1e-4 && $0.top > ceiling - 1e-4 }
        // Solid stretches: before the first opening, between the two, and after the second.
        #expect(fullHeight.count == 3)
    }
}

@Suite("Wall geometry")
struct WallGeometryTests {

    @Test("Projection onto the wall returns the distance from the start corner")
    func projection() {
        let start = SIMD3<Float>(0, 0, 0)
        let end = SIMD3<Float>(4, 0, 0)
        // A point off the wall projects perpendicularly onto it.
        let distance = WallGeometry.project(SIMD3<Float>(1.5, 0, 0.6), onto: start, end)
        expectClose(distance ?? -1, 1.5)
    }

    @Test("The ray finds the wall being aimed at")
    func aimedWall() {
        // 4×3 room, camera in the middle looking at wall 0 (z = 0).
        let corners = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(4, 0, 0),
            SIMD3<Float>(4, 0, 3),
            SIMD3<Float>(0, 0, 3),
        ]
        let aimed = WallGeometry.aimedWall(
            rayOrigin: SIMD3<Float>(2, 1.5, 1.5),
            rayDirection: simd_normalize(SIMD3<Float>(0, 0.4, -1)),
            corners: corners,
            closed: true
        )
        #expect(aimed?.index == 0)
    }

    @Test("Intersecting the wall plane gives the ceiling height")
    func ceilingIntersection() {
        let start = SIMD3<Float>(0, 0, 0)
        let end = SIMD3<Float>(4, 0, 0)
        // From (2, 1.5, 2), aiming at the wall with an upward tilt. The wall is
        // 2 m ahead; rising 0.55 per metre reaches 1.5 + 1.1 = 2.6.
        let hit = WallGeometry.intersectVerticalPlane(
            rayOrigin: SIMD3<Float>(2, 1.5, 2),
            rayDirection: simd_normalize(SIMD3<Float>(0, 0.55, -1)),
            wallStart: start,
            wallEnd: end
        )
        expectClose(hit?.point.y ?? -1, 2.6)
    }

    @Test("A ray parallel to the wall plane doesn't intersect")
    func parallelRay() {
        let hit = WallGeometry.intersectVerticalPlane(
            rayOrigin: SIMD3<Float>(2, 1.5, 2),
            rayDirection: SIMD3<Float>(1, 0, 0),
            wallStart: SIMD3<Float>(0, 0, 0),
            wallEnd: SIMD3<Float>(4, 0, 0)
        )
        #expect(hit == nil)
    }
}

@Suite("Distance to boundary")
struct DistanceToBoundaryTests {

    private let square = [p(0, 0), p(4, 0), p(4, 3), p(0, 3)]

    @Test("From the centre to the nearest wall")
    func center() {
        // 4×3 room: from the centre, the nearest wall is 1.5 m away.
        expectClose(PolygonMath.distanceToBoundary(p(2, 1.5), polygon: square), 1.5)
    }

    @Test("Near a wall")
    func nearWall() {
        expectClose(PolygonMath.distanceToBoundary(p(2, 0.2), polygon: square), 0.2)
        expectClose(PolygonMath.distanceToBoundary(p(3.9, 1.5), polygon: square), 0.1)
    }

    @Test("On a corner the distance is zero")
    func onCorner() {
        expectClose(PolygonMath.distanceToBoundary(p(0, 0), polygon: square), 0)
    }

    @Test("Outside the polygon the distance is still to the edge")
    func outside() {
        // The function doesn't tell inside from outside — `contains` does that.
        expectClose(PolygonMath.distanceToBoundary(p(-1, 1.5), polygon: square), 1.0)
    }

    @Test("Projection clamped to the segment, not to the infinite line")
    func clampedToSegment() {
        // In line with the bottom wall, but past the corner: the distance has to
        // be to the corner, not the perpendicular 0.5 m to the infinite line.
        let distance = PolygonMath.distanceToBoundary(p(-3, -0.5), polygon: square)
        expectClose(distance, sqrt(9 + 0.25))
    }
}

@Suite("Ceiling estimation")
struct CeilingEstimatorTests {

    private let room = [p(0, 0), p(4, 0), p(4, 3), p(0, 3)]

    private func point(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }

    private func heights(_ points: [SIMD3<Float>]) -> [Float] {
        CeilingEstimator.ceilingHeights(
            from: points,
            floorY: 0,
            polygon: room,
            minimumHeight: 1.8,
            maximumHeight: 6.0,
            wallMargin: 0.35
        )
    }

    @Test("High points in the middle of the room are kept")
    func acceptsCeilingPoints() {
        let result = heights([point(2, 2.7, 1.5), point(1.5, 2.68, 1.2)])
        #expect(result.count == 2)
    }

    @Test("Points below the range are discarded")
    func rejectsLowPoints() {
        // A table at 0.75 m and a cabinet at 1.7 m are left out.
        #expect(heights([point(2, 0.75, 1.5), point(2, 1.7, 1.5)]).isEmpty)
    }

    @Test("Points hugging the wall are discarded")
    func rejectsWallPoints() {
        // High and inside the room, but 10 cm from the wall: that's the wall, not
        // the ceiling. Without this filter every high wall would contaminate the
        // statistic.
        #expect(heights([point(2, 2.7, 0.10)]).isEmpty)
        #expect(heights([point(0.05, 2.7, 1.5)]).isEmpty)
    }

    @Test("Points from another space are discarded")
    func rejectsPointsOutsideRoom() {
        #expect(heights([point(9, 2.7, 9)]).isEmpty)
    }

    @Test("Too few samples produce no summary")
    func needsEnoughSamples() {
        #expect(CeilingEstimator.summarize([2.5, 2.6, 2.7]) == nil)
    }

    @Test("A flat ceiling's summary converges to one height")
    func flatCeiling() {
        let flat = (0..<40).map { _ in Float(2.60) }
        guard let summary = CeilingEstimator.summarize(flat) else {
            Issue.record("should have produced a summary")
            return
        }
        expectClose(summary.low, 2.60)
        expectClose(summary.median, 2.60)
        expectClose(summary.high, 2.60)
        expectClose(summary.spread, 0)
    }

    @Test("A sloped ceiling is described by the spread between its ends")
    func slopedCeiling() {
        // Ramp from 2.40 to 3.60 m, like an exposed roof.
        let count = 100
        let sloped = (0..<count).map { 2.40 + Float($0) * (1.20 / Float(count - 1)) }
        guard let summary = CeilingEstimator.summarize(sloped) else {
            Issue.record("should have produced a summary")
            return
        }
        #expect(summary.spread > 0.9, "spread of \(summary.spread) m")
        expectClose(summary.median, 3.00, "the median should land in the middle of the ramp")
    }

    @Test("A lone outlier doesn't shift the ends")
    func outlierResistance() {
        // This is why the summary uses percentiles rather than raw min and max:
        // one point on a light fixture would drag the whole extreme with it.
        var samples = (0..<99).map { _ in Float(2.60) }
        samples.append(5.90)

        guard let summary = CeilingEstimator.summarize(samples) else {
            Issue.record("should have produced a summary")
            return
        }
        expectClose(summary.high, 2.60, "the 90th percentile should not see the outlier")
    }

    private func junction(_ points: [SIMD3<Float>]) -> [Float] {
        CeilingEstimator.junctionHeights(
            from: points,
            floorY: 0,
            polygon: room,
            minimumHeight: 1.8,
            maximumHeight: 6.0,
            maxWallDistance: 0.25
        )
    }

    @Test("The junction keeps what the ceiling sweep discards")
    func junctionKeepsWallPoints() {
        // Same point 10 cm from the wall: rejected as ceiling, accepted as junction.
        let nearWall = point(2, 2.7, 0.10)
        #expect(heights([nearWall]).isEmpty)
        #expect(junction([nearWall]).count == 1)
    }

    @Test("The junction ignores the middle of the room")
    func junctionIgnoresInterior() {
        // The two bands don't overlap: 1.5 m from the wall is ceiling, not junction.
        #expect(junction([point(2, 2.7, 1.5)]).isEmpty)
    }

    @Test("Points just outside the polygon count as junction")
    func junctionAcceptsSlightlyOutside() {
        // The wall has thickness, and the corner tracing runs along its inner
        // face — points slightly beyond still belong to the corner line.
        #expect(junction([point(2, 2.7, -0.08)]).count == 1)
    }

    @Test("Junction height is the top of the distribution, not the median")
    func junctionUsesUpperPercentile() {
        // Points scattered across the wall from 1.8 to 2.6 m: the ceiling is the top.
        let sorted = (0..<100).map { 1.8 + Float($0) * (0.8 / 99) }
        guard let estimate = CeilingEstimator.junctionCeilingHeight(sorted) else {
            Issue.record("should have produced an estimate")
            return
        }
        #expect(estimate > 2.5, "estimated \(estimate) m, expected around 2.6")
    }

    @Test("A stray point above the ceiling doesn't flip the result")
    func junctionResistsOutlier() {
        // 92nd percentile rather than the maximum: a curtain rail or an isolated
        // beam would drag the raw top with it.
        var samples = (0..<99).map { _ in Float(2.60) }
        samples.append(5.80)
        expectClose(CeilingEstimator.junctionCeilingHeight(samples) ?? 0, 2.60)
    }

    @Test("Too few samples estimate nothing")
    func junctionNeedsSamples() {
        #expect(CeilingEstimator.junctionCeilingHeight([2.5, 2.6]) == nil)
    }

    @Test("Percentiles interpolate between neighbouring samples")
    func percentiles() {
        let sorted: [Float] = [1, 2, 3, 4, 5]
        expectClose(CeilingEstimator.percentile(sorted, 0), 1)
        expectClose(CeilingEstimator.percentile(sorted, 0.5), 3)
        expectClose(CeilingEstimator.percentile(sorted, 1), 5)
        expectClose(CeilingEstimator.percentile(sorted, 0.25), 2)
    }
}

@Suite("Plan rotation")
struct PlanRotationTests {

    private func degrees(_ value: Double) -> Angle { .degrees(value) }

    @Test("A near-right angle snaps to the multiple of 90°")
    func snapsWhenClose() {
        #expect(PlanTransform.snapRotation(degrees(87)).degrees == 90)
        #expect(PlanTransform.snapRotation(degrees(93)).degrees == 90)
        #expect(PlanTransform.snapRotation(degrees(-4)).degrees == 0)
        #expect(PlanTransform.snapRotation(degrees(184)).degrees == 180)
    }

    @Test("A deliberate oblique angle is preserved")
    func keepsDeliberateAngle() {
        // The tolerance has to be narrow enough not to hijack an orientation
        // chosen on purpose.
        #expect(PlanTransform.snapRotation(degrees(45)).degrees == 45)
        #expect(PlanTransform.snapRotation(degrees(80)).degrees == 80)
    }

    @Test("Full turns are normalised")
    func normalizesFullTurns() {
        // Four 90° taps on the button would accumulate 360° without this.
        #expect(PlanTransform.snapRotation(degrees(360)).degrees == 0)
        #expect(PlanTransform.snapRotation(degrees(450)).degrees == 90)
        #expect(PlanTransform.snapRotation(degrees(-270)).degrees == 90)
    }

    @Test("180 and −180 converge to the positive form")
    func canonicalHalfTurn() {
        #expect(PlanTransform.snapRotation(degrees(-180)).degrees == 180)
        #expect(PlanTransform.snapRotation(degrees(180)).degrees == 180)
    }

    @Test("Four 90° turns return to the starting point")
    func fourQuarterTurns() {
        var angle = Angle.zero
        for _ in 0..<4 {
            angle = PlanTransform.snapRotation(angle + .degrees(90))
        }
        #expect(angle.degrees == 0)
    }
}

@Suite("RoomScan measurements")
struct RoomScanMeasurementTests {

    /// Builds a rectangular 3×4 m room at the given floor height.
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

    @Test("Area and perimeter of a 3×4 room")
    func rectangle() {
        let scan = rectangularScan()
        expectClose(scan.floorArea, 12.0)
        expectClose(scan.perimeter, 14.0)
        #expect(scan.wallCount == 4)
    }

    @Test("Floor height doesn't affect the area, which is measured in XZ")
    func floorHeightIsIrrelevant() {
        expectClose(rectangularScan(floorY: -1.85).floorArea, 12.0)
    }

    @Test("With the polygon open the area is a preview but the perimeter excludes the closure")
    func openPolygon() {
        let scan = rectangularScan(closed: false)
        // The shoelace closes implicitly: the area preview stays correct.
        expectClose(scan.floorArea, 12.0)
        expectClose(scan.perimeter, 10.0)
        #expect(scan.wallCount == 3)
    }

    @Test("Net wall area deducts door and window")
    func netWallArea() {
        var scan = rectangularScan()
        scan.ceilingHeight = 2.60
        scan.openings = [
            Opening(wallIndex: 0, distanceFromStart: 1, width: 0.80, height: 2.10, sillHeight: 0, type: .door),
            Opening(wallIndex: 1, distanceFromStart: 1, width: 1.20, height: 1.20, sillHeight: 1.10, type: .window),
        ]
        // 14 × 2.60 = 36.40; openings 1.68 + 1.44 = 3.12.
        expectClose(scan.openingsArea, 3.12)
        expectClose(scan.netWallArea, 33.28)
    }
}
