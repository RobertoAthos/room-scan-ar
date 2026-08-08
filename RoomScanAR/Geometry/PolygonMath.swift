import simd

/// Pure geometry of the room polygon.
///
/// Imports neither ARKit nor RealityKit: points in, numbers out. That is what
/// makes the math testable in the Simulator, with no physical device.
///
/// Everything is computed in the XZ plane — the "plan" — since every corner
/// shares the same height by construction. In the `SIMD2` values used here,
/// `x` is world X and `y` is world **Z**.
enum PolygonMath {

    // MARK: - Area

    /// Signed area, by the *shoelace* formula.
    ///
    /// The sign encodes the vertex winding, which matters for orienting the
    /// floor plan and for the orthogonal snap. To display measurements use
    /// `area`, which is always positive.
    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }

        // Translate to the first vertex before summing. Corners arrive in world
        // coordinates that can sit tens of metres from the AR session origin;
        // multiplying large coordinates and then subtracting close values eats
        // Float precision exactly where it matters. Accumulating in Double is
        // cheap reinforcement.
        let origin = points[0]
        var sum = 0.0
        for index in points.indices {
            let a = points[index] - origin
            let b = points[(index + 1) % points.count] - origin
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return Float(sum / 2)
    }

    /// Floor area, always positive — independent of whether the corners were
    /// marked clockwise or counter-clockwise.
    static func area(_ points: [SIMD2<Float>]) -> Float {
        abs(signedArea(points))
    }

    // MARK: - Lengths

    /// Length of each segment, in corner order.
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

    // MARK: - Centroid

    /// Centroid of the polygon's **area**, not the mean of its vertices.
    ///
    /// The vertex mean is biased by corners bunched together — in an L-shaped
    /// room it can even land outside the polygon. To position the area label on
    /// the floor plan we want the centre of mass.
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

        // Degenerate polygon (collinear corners): no centre of mass is defined,
        // so fall back to the vertex mean.
        guard abs(doubleArea) > 1e-9 else { return vertexMean(points) }

        // Cx = Σ(xᵢ + xᵢ₊₁)·cross / (6A), and doubleArea = 2A, hence 6A = 3·doubleArea.
        let factor = 1.0 / (3.0 * doubleArea)
        return origin + SIMD2<Float>(
            Float(accumulatedX * factor),
            Float(accumulatedY * factor)
        )
    }

    private static func vertexMean(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        points.reduce(.zero, +) / Float(points.count)
    }

    // MARK: - Inside or outside

    /// Whether the point lies inside the polygon, by ray casting.
    ///
    /// Counts how many edges a horizontal ray from the point crosses: odd means
    /// inside. Works for any simple polygon, concave included, and is
    /// **independent of vertex winding**.
    ///
    /// That independence is what lets the floor plan orient its dimension labels
    /// without deriving handedness from the sign of the area — a derivation that
    /// gets it wrong whenever the destination coordinate system flips an axis,
    /// as the screen does with its downward-growing Y.
    static func contains(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var isInside = false
        var previous = polygon.count - 1

        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]

            // Does this edge straddle the horizontal line through the point?
            let straddles = (a.y > point.y) != (b.y > point.y)
            if straddles {
                // X of the crossing, by linear interpolation along the edge.
                let crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossingX { isInside.toggle() }
            }
            previous = current
        }

        return isInside
    }

    // MARK: - Walls

    /// Net wall area: perimeter × ceiling height, less the openings.
    static func netWallArea(perimeter: Float, ceilingHeight: Float, openingsArea: Float) -> Float {
        max(0, perimeter * ceilingHeight - openingsArea)
    }
}

// MARK: - 3D conveniences

/// Overloads that project 3D corners into XZ. They keep the functions above
/// purely two-dimensional, which is how they are tested.
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
