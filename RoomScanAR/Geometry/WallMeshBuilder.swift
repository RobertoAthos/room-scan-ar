import RealityKit
import simd

/// Geração da malha das paredes.
///
/// Puro no sentido que importa: entra par de cantos e altura, sai `MeshResource`.
/// Não conhece ARKit, sessão nem estado — só RealityKit, que é inevitável para
/// produzir malha.
enum WallMeshBuilder {

    /// Painel retangular vertical, definido pela sua base e por um intervalo de altura.
    ///
    /// Um quad de parede inteira é o caso `bottom = 0, top = pé-direito`. Aberturas
    /// (Etapa 7) dividem a parede em vários painéis usando a mesma primitiva.
    struct Panel {
        var start: SIMD3<Float>
        var end: SIMD3<Float>
        var bottom: Float
        var top: Float
    }

    /// Constrói a malha de um conjunto de painéis, num único `MeshResource`.
    ///
    /// Os triângulos são emitidos nos **dois sentidos de winding**. `SimpleMaterial`
    /// não expõe `faceCulling` (só `PhysicallyBasedMaterial` e `UnlitMaterial`), e o
    /// usuário fica *dentro* do cômodo: sem a face de trás as paredes ficariam
    /// invisíveis pelo lado interno, que é justamente de onde se olha.
    ///
    /// `@MainActor` porque `MeshResource.generate(from:)` é isolada ao MainActor no
    /// SDK. É por isso que `PolygonMath` mora num arquivo separado: a matemática
    /// pura continua chamável de qualquer contexto, inclusive dos testes.
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

            // Quatro cantos do painel: base e topo em cada extremidade.
            let p0 = panel.start.with(y: panel.bottom)
            let p1 = panel.end.with(y: panel.bottom)
            let p2 = panel.end.with(y: panel.top)
            let p3 = panel.start.with(y: panel.top)

            // Normal horizontal do painel: perpendicular à direção, no plano XZ.
            let normal = simd_normalize(SIMD3<Float>(direction.z, 0, -direction.x))

            // Face frontal (4 vértices) e face traseira (os mesmos 4, normal invertida).
            // Duplicar os vértices em vez de só os índices permite que cada face
            // tenha a sua própria normal — com normais compartilhadas, um dos lados
            // ficaria com iluminação invertida.
            positions.append(contentsOf: [p0, p1, p2, p3, p0, p1, p2, p3])
            normals.append(contentsOf: [normal, normal, normal, normal,
                                        -normal, -normal, -normal, -normal])

            // Frente: sentido anti-horário vista do lado da normal.
            indices.append(contentsOf: [
                base + 0, base + 1, base + 2,
                base + 0, base + 2, base + 3,
            ])
            // Verso: mesma geometria, winding invertido.
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

    /// Painéis de uma parede sem aberturas: um único quad da base ao teto.
    static func panels(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        ceilingHeight: Float
    ) -> [Panel] {
        [Panel(start: start, end: end, bottom: 0, top: ceilingHeight)]
    }
}
