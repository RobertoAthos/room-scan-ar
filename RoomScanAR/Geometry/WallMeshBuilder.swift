import RealityKit
import simd

/// Wall mesh generation.
///
/// Pure in the sense that matters: a corner pair and a height go in, a
/// `MeshResource` comes out. Knows nothing about ARKit, sessions or state — only
/// RealityKit, which is unavoidable when producing a mesh.
enum WallMeshBuilder {

    /// Vertical rectangular panel, defined by its base and a height interval.
    ///
    /// A whole-wall quad is the `bottom = 0, top = ceiling height` case. Openings
    /// split the wall into several panels using the same primitive.
    struct Panel {
        var start: SIMD3<Float>
        var end: SIMD3<Float>
        var bottom: Float
        var top: Float
    }

    /// Builds the mesh for a set of panels, as a single `MeshResource`.
    ///
    /// Triangles are emitted in **both winding orders**. The user stands *inside*
    /// the room, so without the back face the walls would be invisible from the
    /// inside — which is precisely where they are looked at. Emitting both
    /// windings makes this independent of any material's face-culling setting.
    ///
    /// `@MainActor` because `MeshResource.generate(from:)` is MainActor-isolated
    /// in the SDK. That is why `PolygonMath` lives in a separate file: the pure
    /// math stays callable from any context, tests included.
    @MainActor
    static func mesh(for panels: [Panel]) -> MeshResource? {
        guard !panels.isEmpty else { return nil }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for panel in panels {
            let direction = panel.end - panel.start
            guard simd_length(direction) > 1e-4, panel.top > panel.bottom else { continue }

            let base = UInt32(positions.count)

            // The panel's four corners: base and top at each end.
            let p0 = panel.start.with(y: panel.bottom)
            let p1 = panel.end.with(y: panel.bottom)
            let p2 = panel.end.with(y: panel.top)
            let p3 = panel.start.with(y: panel.top)

            // Horizontal normal of the panel: perpendicular to the direction, in XZ.
            let normal = simd_normalize(SIMD3<Float>(direction.z, 0, -direction.x))

            // Front face (4 vertices) and back face (the same 4, normal flipped).
            // Duplicating the vertices rather than just the indices lets each face
            // carry its own normal — with shared normals one side would end up
            // lit backwards.
            positions.append(contentsOf: [p0, p1, p2, p3, p0, p1, p2, p3])
            normals.append(contentsOf: [normal, normal, normal, normal,
                                        -normal, -normal, -normal, -normal])

            // Front: counter-clockwise as seen from the normal's side.
            indices.append(contentsOf: [
                base + 0, base + 1, base + 2,
                base + 0, base + 2, base + 3,
            ])
            // Back: same geometry, reversed winding.
            indices.append(contentsOf: [
                base + 4, base + 6, base + 5,
                base + 4, base + 7, base + 6,
            ])
        }

        guard !indices.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: "wall")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)

        return try? MeshResource.generate(from: [descriptor])
    }

    /// Panels for a wall with no openings: a single quad from base to ceiling.
    static func panels(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        ceilingHeight: Float
    ) -> [Panel] {
        [Panel(start: start, end: end, bottom: 0, top: ceilingHeight)]
    }

    /// An opening to cut out of the wall, in coordinates parametric along it.
    struct Cutout {
        /// Distance from the start corner to the opening's left edge.
        var distance: Float
        var width: Float
        /// Height of the opening's base: 0 for a door, the sill for a window.
        var sill: Float
        /// Height of the opening's top edge.
        var top: Float
    }

    /// Panels for a wall with openings.
    ///
    /// **There is no boolean operation.** RealityKit offers no practical CSG, so
    /// instead of cutting the mesh the wall is split into panels that go around
    /// the opening:
    ///
    ///     Door    →  left panel | right panel | header
    ///     Window  →  left panel | right panel | header | sill panel
    ///
    /// Visually indistinguishable from a real cut-out.
    static func panels(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        ceilingHeight: Float,
        cutouts: [Cutout]
    ) -> [Panel] {
        guard !cutouts.isEmpty else {
            return panels(from: start, to: end, ceilingHeight: ceilingHeight)
        }
        guard let direction = WallGeometry.direction(from: start, to: end) else { return [] }
        let wallLength = WallGeometry.length(from: start, to: end)
        guard wallLength > 1e-4 else { return [] }

        func pointAt(_ distance: Float) -> SIMD3<Float> {
            start + direction * distance
        }

        // Sorting is mandatory: the algorithm walks left to right filling the
        // gaps between openings.
        let ordered = cutouts
            .map { cutout -> Cutout in
                // Clamp the opening to the wall's and the ceiling's limits. An
                // opening wider than the wall would produce panels of negative
                // length.
                let distance = min(max(cutout.distance, 0), wallLength)
                let width = min(max(cutout.width, 0), wallLength - distance)
                let sill = min(max(cutout.sill, 0), ceilingHeight)
                let top = min(max(cutout.top, sill), ceilingHeight)
                return Cutout(distance: distance, width: width, sill: sill, top: top)
            }
            .filter { $0.width > 1e-4 }
            .sorted { $0.distance < $1.distance }

        var result: [Panel] = []
        var cursor: Float = 0

        for cutout in ordered {
            // Overlapping openings: ignore the stretch already consumed.
            let left = max(cutout.distance, cursor)
            let right = max(cutout.distance + cutout.width, cursor)
            guard right > left else { continue }

            // Solid stretch before the opening.
            if left > cursor + 1e-4 {
                result.append(Panel(start: pointAt(cursor), end: pointAt(left), bottom: 0, top: ceilingHeight))
            }

            let gapStart = pointAt(left)
            let gapEnd = pointAt(right)

            // Sill panel, below the opening. Absent on doors, where sill = 0.
            if cutout.sill > 1e-4 {
                result.append(Panel(start: gapStart, end: gapEnd, bottom: 0, top: cutout.sill))
            }
            // Header, above the opening.
            if cutout.top < ceilingHeight - 1e-4 {
                result.append(Panel(start: gapStart, end: gapEnd, bottom: cutout.top, top: ceilingHeight))
            }

            cursor = right
        }

        // Solid stretch after the last opening.
        if cursor < wallLength - 1e-4 {
            result.append(Panel(start: pointAt(cursor), end: pointAt(wallLength), bottom: 0, top: ceilingHeight))
        }

        return result
    }
}
