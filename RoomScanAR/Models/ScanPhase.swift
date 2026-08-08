import Foundation

/// State machine for the scanning flow.
///
/// Transitions are always explicit (button-driven) — never automatic. That is
/// deliberate: an unexpected phase change in the middle of a video recording
/// ruins the demo.
enum ScanPhase: Int, CaseIterable, Sendable {
    case detectingFloor
    case markingCorners
    case measuringHeight
    case markingOpenings
    case results
}

extension ScanPhase {
    /// Short instruction shown at the top of the HUD.
    /// User-facing copy stays in Brazilian Portuguese, as the spec requires.
    var instruction: String {
        switch self {
        case .detectingFloor:  "Aponte para o chão e mova o celular devagar"
        case .markingCorners:  "Mire no encontro entre parede e piso e toque em Marcar canto"
        case .measuringHeight: "Mire no encontro entre parede e teto"
        case .markingOpenings: "Toque numa parede, depois marque dois cantos opostos do vão"
        case .results:         "Digitalização concluída"
        }
    }

    var title: String {
        switch self {
        case .detectingFloor:  "Detectando piso"
        case .markingCorners:  "Marcando cantos"
        case .measuringHeight: "Pé-direito"
        case .markingOpenings: "Portas e janelas"
        case .results:         "Resultados"
        }
    }
}
