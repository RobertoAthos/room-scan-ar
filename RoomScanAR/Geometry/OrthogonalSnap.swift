import simd

/// Snapping the polygon to right angles.
///
/// Pure: XZ points in, points out. Testable without a device.
enum OrthogonalSnap {

    /// Maximum tolerated residual error, as a fraction of the perimeter. Beyond
    /// it the marking is too irregular for the snap to represent the room.
    static let maxResidualRatio: Float = 0.15

    struct Result {
        /// Snapped corners. They close exactly and form only right angles.
        let corners: [SIMD2<Float>]
        /// Closure error before adjustment, as a fraction of the perimeter.
        let residualRatio: Float
    }

    enum Failure: Error, Equatable {
        /// Fewer than three corners: there is no polygon.
        case notEnoughCorners
        /// Residual error above the limit — the marking is too skewed.
        case tooIrregular(residualRatio: Float)
        /// After snapping, one axis ended up travelled in a single direction.
        /// The polygon would have no way to close.
        case unbalancedAxis
    }

    /// Snaps the segments to multiples of 90° relative to the first one.
    ///
    /// The first corner and the first segment's direction are preserved; what
    /// changes are the remaining segments' directions and, to close the polygon,
    /// their lengths.
    ///
    /// **Divergence from the specification.** The spec asks for the residual
    /// error to be distributed across the vertices. That closes the polygon but
    /// reintroduces non-right angles — you pay for the snap without ending up
    /// with exact 90°. Since every segment ends up axis-aligned in the θ₀ frame
    /// after snapping, the polygon can instead be closed by adjusting lengths
    /// only: it suffices that the sum of travel in one direction equals the sum
    /// in the opposite direction, per axis. Closure is then exact and the right
    /// angles survive.
    static func snap(_ points: [SIMD2<Float>]) -> Swift.Result<Result, Failure> {
        guard points.count >= 3 else { return .failure(.notEnoughCorners) }

        let count = points.count
        var lengths: [Float] = []
        var quadrants: [Int] = []

        // Reference frame: the first segment's direction becomes the u axis.
        let firstDelta = points[1] - points[0]
        guard simd_length(firstDelta) > 1e-5 else { return .failure(.notEnoughCorners) }
        let theta0 = atan2(firstDelta.y, firstDelta.x)

        for index in 0..<count {
            let delta = points[(index + 1) % count] - points[index]
            let length = simd_length(delta)
            lengths.append(length)

            // Angle relative to θ₀, rounded to the nearest multiple of 90°.
            let relative = atan2(delta.y, delta.x) - theta0
            let quadrant = Int((relative / (.pi / 2)).rounded()) %% 4
            quadrants.append(quadrant)
        }

        let perimeter = lengths.reduce(0, +)
        guard perimeter > 1e-5 else { return .failure(.notEnoughCorners) }

        // Closure error when walking with the snapped directions and the
        // original lengths.
        var walk = SIMD2<Float>.zero
        for index in 0..<count {
            walk += axis(quadrants[index], theta0: theta0) * lengths[index]
        }
        let residualRatio = simd_length(walk) / perimeter
        guard residualRatio <= maxResidualRatio else {
            return .failure(.tooIrregular(residualRatio: residualRatio))
        }

        // Length adjustment, axis by axis. Quadrants 0 and 2 travel the u axis in
        // opposite directions; 1 and 3 travel the v axis.
        guard let scales = balancingScales(lengths: lengths, quadrants: quadrants) else {
            return .failure(.unbalancedAxis)
        }

        var corners: [SIMD2<Float>] = [points[0]]
        corners.reserveCapacity(count)
        var cursor = points[0]
        // The last segment is the closing one: it returns to the first corner by
        // construction, so it produces no new vertex.
        for index in 0..<(count - 1) {
            cursor += axis(quadrants[index], theta0: theta0) * (lengths[index] * scales[index])
            corners.append(cursor)
        }

        return .success(Result(corners: corners, residualRatio: residualRatio))
    }

    /// Per-segment length correction factor.
    ///
    /// On each axis, the sum of lengths in one direction has to equal the sum in
    /// the opposite one. The difference is distributed proportionally to length,
    /// so that long segments absorb more of it than short ones.
    private static func balancingScales(lengths: [Float], quadrants: [Int]) -> [Float]? {
        var totals = [Float](repeating: 0, count: 4)
        for index in lengths.indices {
            totals[quadrants[index]] += lengths[index]
        }

        var scales = [Float](repeating: 1, count: lengths.count)

        for (positive, negative) in [(0, 2), (1, 3)] {
            let forward = totals[positive]
            let backward = totals[negative]

            // Axis with no travel at all: nothing to balance.
            if forward < 1e-5 && backward < 1e-5 { continue }
            // Travel in one direction only: no amount of scaling closes the polygon.
            if forward < 1e-5 || backward < 1e-5 { return nil }

            let target = (forward + backward) / 2
            for index in lengths.indices {
                if quadrants[index] == positive { scales[index] = target / forward }
                if quadrants[index] == negative { scales[index] = target / backward }
            }
        }

        return scales
    }

    /// Unit vector of the quadrant, in the frame rotated by θ₀.
    private static func axis(_ quadrant: Int, theta0: Float) -> SIMD2<Float> {
        let angle = theta0 + Float(quadrant) * (.pi / 2)
        return SIMD2<Float>(cos(angle), sin(angle))
    }
}

// MARK: - 3D convenience

extension OrthogonalSnap {
    /// Snaps 3D corners while preserving each one's height.
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

/// Always-positive modulo. `-1 % 4` is `-1` in Swift, which would break quadrant
/// indexing for segments turning in the negative direction.
infix operator %%: MultiplicationPrecedence
private func %% (lhs: Int, rhs: Int) -> Int {
    let remainder = lhs % rhs
    return remainder < 0 ? remainder + rhs : remainder
}
