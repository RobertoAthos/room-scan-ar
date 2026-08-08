import Foundation

/// Máquina de estados do fluxo de digitalização.
///
/// As transições são sempre explícitas (acionadas por botão) — nunca automáticas.
/// Isso é deliberado: um avanço de fase inesperado no meio de uma gravação de vídeo
/// arruína a demonstração.
enum ScanPhase: Int, CaseIterable, Sendable {
    case detectingFloor
    case markingCorners
    case measuringHeight
    case markingOpenings
    case results
}

extension ScanPhase {
    /// Instrução curta exibida no topo do HUD.
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
