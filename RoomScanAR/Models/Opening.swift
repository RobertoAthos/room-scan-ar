import Foundation

enum OpeningType: Sendable, CaseIterable {
    case door
    case slidingDoor
    case openGap
    case window

    var label: String {
        switch self {
        case .door:        "Porta"
        case .slidingDoor: "Porta de correr"
        case .openGap:     "Vão aberto"
        case .window:      "Janela"
        }
    }

    /// Rótulo curto, para caber no seletor segmentado do HUD.
    var shortLabel: String {
        switch self {
        case .door:        "Porta"
        case .slidingDoor: "Correr"
        case .openGap:     "Vão"
        case .window:      "Janela"
        }
    }

    /// Valores padrão em metros, usados como ponto de partida editável.
    var defaultHeight: Float {
        switch self {
        case .door, .slidingDoor, .openGap: 2.10
        case .window:                       1.20
        }
    }

    var defaultSillHeight: Float {
        switch self {
        case .door, .slidingDoor, .openGap: 0.00
        case .window:                       1.10
        }
    }

    /// Só a janela tem peitoril; nas demais o vão desce até o piso.
    var hasSill: Bool { self == .window }

    /// Acima desta largura uma folha de giro deixa de fazer sentido — o padrão
    /// sugerido passa a ser porta de correr.
    static let slidingSuggestionWidth: Float = 1.20

    /// Tipo sugerido para um vão recém-marcado, a partir da largura.
    static func suggested(forWidth width: Float) -> OpeningType {
        width >= slidingSuggestionWidth ? .slidingDoor : .door
    }
}

/// Uma abertura posicionada ao longo de um segmento de parede.
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

    /// Altura do topo do vão a partir do piso.
    var topHeight: Float { sillHeight + height }
}
