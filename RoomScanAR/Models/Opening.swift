import Foundation

enum OpeningType: Sendable, CaseIterable {
    case door
    case window

    var label: String {
        switch self {
        case .door:   "Porta"
        case .window: "Janela"
        }
    }

    /// Valores padrão em metros, usados como ponto de partida editável.
    var defaultHeight: Float {
        switch self {
        case .door:   2.10
        case .window: 1.20
        }
    }

    var defaultSillHeight: Float {
        switch self {
        case .door:   0.00
        case .window: 1.10
        }
    }
}

/// Uma abertura (porta ou janela) posicionada ao longo de um segmento de parede.
///
/// A posição é paramétrica em relação à parede — `distanceFromStart` mede a partir
/// do canto inicial do segmento. Guardar assim (em vez de coordenadas de mundo)
/// significa que a abertura acompanha a parede se os cantos forem ajustados depois,
/// por exemplo pelo snap ortogonal.
struct Opening: Identifiable, Sendable {
    let id = UUID()
    var wallIndex: Int
    var distanceFromStart: Float
    var width: Float
    var height: Float
    var sillHeight: Float
    var type: OpeningType

    /// Área do vão, usada para descontar da área líquida de parede.
    var area: Float { width * height }
}
