import simd

extension simd_float4x4 {
    /// Translation component of a transform matrix (the 4th column).
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension SIMD3<Float> {
    /// Projection onto the floor plane, dropping the height.
    /// All floor-plan geometry is computed in XZ.
    var xz: SIMD2<Float> { SIMD2<Float>(x, z) }

    /// Same position with the height replaced — used to lock corners to `floorY`.
    func with(y newY: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, newY, z)
    }
}

extension SIMD2<Float> {
    /// Rebuilds a 3D point from floor coordinates plus a height.
    func toXZ(y: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, y, self.y)
    }
}
