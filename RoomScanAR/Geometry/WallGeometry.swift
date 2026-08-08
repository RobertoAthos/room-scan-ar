import simd

/// Geometry of a wall treated as an infinite vertical plane.
///
/// Pure: knows nothing about ARKit. Without LiDAR there is no ceiling or wall
/// mesh to raycast against, so both the ceiling-height measurement and
/// tap-to-select-a-wall are resolved analytically here.
enum WallGeometry {

    /// Unit horizontal direction of the wall, from start corner to end corner.
    static func direction(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD3<Float>? {
        let delta = SIMD3<Float>(end.x - start.x, 0, end.z - start.z)
        let length = simd_length(delta)
        guard length > 1e-5 else { return nil }
        return delta / length
    }

    /// Horizontal normal of the wall. Perpendicular to the direction, in the
    /// floor plane.
    static func normal(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD3<Float>? {
        guard let direction = direction(from: start, to: end) else { return nil }
        return SIMD3<Float>(direction.z, 0, -direction.x)
    }

    static func length(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Float {
        simd_length(SIMD3<Float>(end.x - start.x, 0, end.z - start.z))
    }

    /// Distance along the wall from the start corner to the projection of `point`.
    ///
    /// This is the parameter that positions doors and windows: storing openings
    /// this way rather than in absolute coordinates makes them follow the wall
    /// if the corners are adjusted later — by the orthogonal snap, for instance.
    static func project(
        _ point: SIMD3<Float>,
        onto start: SIMD3<Float>,
        _ end: SIMD3<Float>
    ) -> Float? {
        guard let direction = direction(from: start, to: end) else { return nil }
        let offset = SIMD3<Float>(point.x - start.x, 0, point.z - start.z)
        return simd_dot(offset, direction)
    }

    /// A point on the wall, at a given distance from the start corner and a
    /// given height.
    static func point(
        onWallFrom start: SIMD3<Float>,
        to end: SIMD3<Float>,
        distance: Float,
        height: Float
    ) -> SIMD3<Float> {
        guard let direction = direction(from: start, to: end) else {
            return start.with(y: start.y + height)
        }
        let base = start + direction * distance
        return base.with(y: start.y + height)
    }

    /// Intersection of a ray with the infinite vertical plane containing the wall.
    ///
    /// With point P on the wall, horizontal normal N, ray origin O and direction D:
    ///     t = ((P − O) · N) / (D · N)
    ///     intersection = O + t·D
    ///
    /// Returns `nil` when the ray is parallel to the plane or meets it behind
    /// the camera.
    static func intersectVerticalPlane(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        wallStart: SIMD3<Float>,
        wallEnd: SIMD3<Float>
    ) -> (point: SIMD3<Float>, distance: Float)? {
        guard let normal = normal(from: wallStart, to: wallEnd) else { return nil }

        let denominator = simd_dot(rayDirection, normal)
        guard abs(denominator) > 1e-4 else { return nil }

        let t = simd_dot(wallStart - rayOrigin, normal) / denominator
        guard t > 0 else { return nil }

        return (rayOrigin + t * rayDirection, t)
    }

    /// Index of the wall the ray is aiming at.
    ///
    /// Only considers walls whose plane is hit **within the segment's extent** —
    /// the plane is infinite, the wall is not. Among the candidates, picks the
    /// one closest to the camera.
    ///
    /// - Parameter tolerance: slack at the ends, in metres, so that aiming
    ///   exactly at a corner doesn't rule out both adjoining walls.
    static func aimedWall(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        corners: [SIMD3<Float>],
        closed: Bool,
        tolerance: Float = 0.15
    ) -> (index: Int, point: SIMD3<Float>)? {
        guard corners.count >= 2 else { return nil }
        let segmentCount = closed ? corners.count : corners.count - 1

        var best: (index: Int, point: SIMD3<Float>, distance: Float)?

        for index in 0..<segmentCount {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]

            guard let hit = intersectVerticalPlane(
                rayOrigin: rayOrigin,
                rayDirection: rayDirection,
                wallStart: start,
                wallEnd: end
            ) else { continue }

            guard let distanceAlong = project(hit.point, onto: start, end) else { continue }
            let wallLength = length(from: start, to: end)
            guard distanceAlong >= -tolerance, distanceAlong <= wallLength + tolerance else { continue }

            if best == nil || hit.distance < best!.distance {
                best = (index, hit.point, hit.distance)
            }
        }

        guard let best else { return nil }
        return (best.index, best.point)
    }
}
