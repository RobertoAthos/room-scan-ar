import simd

/// The scan's primary data model.
///
/// Every value is in **metres**, in the content anchor's space — not in ARKit
/// world coordinates. ARKit repositions its anchors on every drift correction,
/// so points captured at different moments are only mutually consistent when
/// expressed relative to the anchor.
///
/// Corners are stored in sequential order around the room, all sharing the same
/// Y (`floorY`).
struct RoomScan: Sendable {
    var corners: [SIMD3<Float>] = []

    /// Floor height in anchor space. The anchor is created exactly at floor
    /// level, so in practice this is 0 — the field exists to keep the intent
    /// explicit in the geometry code.
    var floorY: Float = 0
    var ceilingHeight: Float = 2.60
    var openings: [Opening] = []
    var isClosed: Bool = false

    /// Original corners, kept before applying the orthogonal snap so that the
    /// operation stays reversible.
    var cornersBeforeSnap: [SIMD3<Float>]?

    var isSnapped: Bool { cornersBeforeSnap != nil }

    /// Wall segment count: n corners closed form n walls, n corners open form n-1.
    var wallCount: Int {
        guard corners.count >= 2 else { return 0 }
        return isClosed ? corners.count : corners.count - 1
    }

    /// The pair of corners bounding the wall at `index`.
    func wall(at index: Int) -> (start: SIMD3<Float>, end: SIMD3<Float>)? {
        guard index >= 0, index < wallCount else { return nil }
        return (corners[index], corners[(index + 1) % corners.count])
    }
}

// MARK: - Measurements

/// All derived from `PolygonMath`, which is pure. The model caches no
/// measurements: they are O(n) with n < 20, and caching here would only create
/// state to invalidate.
extension RoomScan {

    /// Floor area by the *shoelace* formula.
    ///
    /// With the polygon still open the formula closes implicitly from the last
    /// corner back to the first — which is exactly the preview the HUD shows
    /// while corners are being marked.
    var floorArea: Float {
        PolygonMath.area(corners)
    }

    /// Perimeter. Includes the closing segment only once the polygon is closed.
    var perimeter: Float {
        PolygonMath.perimeter(corners, closed: isClosed)
    }

    var wallLengths: [Float] {
        PolygonMath.segmentLengths(corners, closed: isClosed)
    }

    var openingsArea: Float {
        openings.reduce(0) { $0 + $1.area }
    }

    /// Wall area with the openings deducted.
    var netWallArea: Float {
        PolygonMath.netWallArea(
            perimeter: perimeter,
            ceilingHeight: ceilingHeight,
            openingsArea: openingsArea
        )
    }

    /// Area centroid in XZ — where the floor plan places the area label.
    var centroidXZ: SIMD2<Float> {
        PolygonMath.centroid(corners)
    }
}
