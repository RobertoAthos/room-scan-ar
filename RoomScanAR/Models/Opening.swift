import Foundation

enum OpeningType: Sendable, CaseIterable {
    case door
    case slidingDoor
    case openGap
    case window

    /// User-facing copy stays in Brazilian Portuguese, as the spec requires.
    var label: String {
        switch self {
        case .door:        "Porta"
        case .slidingDoor: "Porta de correr"
        case .openGap:     "Vão aberto"
        case .window:      "Janela"
        }
    }

    /// Plural form, for summaries that group openings by type.
    var pluralLabel: String {
        switch self {
        case .door:        "Portas"
        case .slidingDoor: "Portas de correr"
        case .openGap:     "Vãos abertos"
        case .window:      "Janelas"
        }
    }

    /// Short label, sized to fit the HUD's segmented picker.
    var shortLabel: String {
        switch self {
        case .door:        "Porta"
        case .slidingDoor: "Correr"
        case .openGap:     "Vão"
        case .window:      "Janela"
        }
    }

    /// Defaults in metres, used as an editable starting point.
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

    /// Only windows have a sill; in the others the opening runs down to the floor.
    var hasSill: Bool { self == .window }

    /// Past this width a swing leaf stops making sense — the suggested default
    /// becomes a sliding door.
    static let slidingSuggestionWidth: Float = 1.20

    /// Type suggested for a freshly marked opening, based on its width.
    static func suggested(forWidth width: Float) -> OpeningType {
        width >= slidingSuggestionWidth ? .slidingDoor : .door
    }
}

/// An opening positioned along a wall segment.
///
/// The position is parametric relative to the wall — `distanceFromStart`
/// measures from the segment's start corner. Storing it this way (rather than in
/// world coordinates) means the opening follows the wall if the corners are
/// adjusted later, by the orthogonal snap for instance.
struct Opening: Identifiable, Sendable {
    let id = UUID()
    var wallIndex: Int
    var distanceFromStart: Float
    var width: Float
    var height: Float
    var sillHeight: Float
    var type: OpeningType

    /// Opening area, deducted from the net wall area.
    var area: Float { width * height }

    /// Height of the opening's top edge above the floor.
    var topHeight: Float { sillHeight + height }
}
