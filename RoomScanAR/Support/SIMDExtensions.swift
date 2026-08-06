import simd

extension simd_float4x4 {
    /// Componente de translação de uma matriz de transformação (a 4ª coluna).
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension SIMD3<Float> {
    /// Projeção no plano do piso, descartando a altura.
    /// A geometria da planta baixa é toda calculada em XZ.
    var xz: SIMD2<Float> { SIMD2<Float>(x, z) }

    /// Mesma posição com a altura substituída — usado para travar os cantos em `floorY`.
    func with(y newY: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, newY, z)
    }
}

extension SIMD2<Float> {
    /// Reconstrói um ponto 3D a partir das coordenadas de piso e uma altura.
    func toXZ(y: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, y, self.y)
    }
}
