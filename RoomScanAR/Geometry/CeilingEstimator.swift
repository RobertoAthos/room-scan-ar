import simd

/// Ceiling-height estimation from the sparse feature-point cloud.
///
/// Pure: points in, statistics out. Knows nothing about ARKit.
///
/// Without LiDAR there is no ceiling mesh, but ARKit does track 3D feature
/// points while the user sweeps the room. Filtering for the ones that are high
/// up and away from the walls, the height distribution describes the ceiling —
/// including when it is sloped, a case in which a single number would represent
/// nothing.
enum CeilingEstimator {

    struct Summary: Equatable {
        let sampleCount: Int
        /// 10th percentile — the lowest part of the ceiling.
        let low: Float
        let median: Float
        /// 90th percentile — the highest part.
        let high: Float

        /// Difference between the ends. Past ~30 cm the ceiling is not flat.
        var spread: Float { high - low }
    }

    /// Heights of the points that may belong to the ceiling.
    ///
    /// Three filters, in this order:
    /// 1. height within the plausible ceiling range;
    /// 2. inside the room polygon — discards what belongs to another space;
    /// 3. away from the walls — discards points on the walls themselves, which
    ///    are high up and would pass the first two.
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

    /// Heights of the points sitting on the **wall-ceiling junction**.
    ///
    /// The inverse of `ceilingHeights`: instead of discarding what lies near the
    /// wall, it keeps only that.
    ///
    /// This covers the case where the ceiling face has no texture — a smooth
    /// white slab produces no feature points at all, and the interior sweep comes
    /// back empty. The corner line where wall and ceiling meet, however, is a
    /// shading discontinuity between two surfaces, and exists even on the
    /// smoothest ceiling. Walls also carry far more texture than ceilings:
    /// baseboards, outlets, picture frames, furniture pushed against them.
    ///
    /// The points gathered there sit on the wall at varying heights. The ceiling
    /// is the **top** of that distribution — hence `junctionCeilingHeight` using
    /// a high percentile rather than the median.
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

            // No containment test: the corner line sits on the polygon's outline,
            // and points slightly outside it are equally valid — the corner
            // tracing runs along the wall's inner face, and the wall has
            // thickness. Only the distance to the edge matters.
            let planar = point.xz
            guard PolygonMath.distanceToBoundary(planar, polygon: polygon) <= maxWallDistance else { return nil }

            return height
        }
    }

    /// Ceiling height derived from the junction samples.
    ///
    /// 92nd percentile rather than the maximum: the raw top would latch onto an
    /// isolated point on a beam, on a curtain rail, or already on the far side of
    /// the wall.
    static func junctionCeilingHeight(_ heights: [Float], minimumSamples: Int = 12) -> Float? {
        guard heights.count >= minimumSamples else { return nil }
        return percentile(heights.sorted(), 0.92)
    }

    /// Percentile summary.
    ///
    /// Percentiles rather than raw min and max: the cloud is noisy, and a single
    /// point on a light fixture or a loose beam would drag the whole extreme with
    /// it. The 10th and 90th percentiles describe the ceiling, not the accidents.
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

    /// Percentile with linear interpolation between the two neighbouring samples.
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
