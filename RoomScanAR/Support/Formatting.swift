import Foundation

/// Formatação numérica em pt-BR (vírgula decimal, duas casas).
///
/// Usa `FormatStyle` em vez de `NumberFormatter`: este último é uma classe
/// não-`Sendable`, o que impede guardá-lo como `static let` sob a checagem de
/// concorrência estrita do Swift 6. A saída é idêntica.
enum Format {
    private static let locale = Locale(identifier: "pt_BR")

    private static var twoDecimals: FloatingPointFormatStyle<Double> {
        .number.locale(locale).precision(.fractionLength(2)).grouping(.never)
    }

    /// Ex.: "3,45 m"
    static func meters(_ value: Float) -> String {
        "\(Double(value).formatted(twoDecimals)) m"
    }

    /// Ex.: "12,30 m²"
    static func squareMeters(_ value: Float) -> String {
        "\(Double(value).formatted(twoDecimals)) m²"
    }

    /// Número puro, sem unidade — para rótulos onde a unidade já está no cabeçalho.
    static func decimal(_ value: Float) -> String {
        Double(value).formatted(twoDecimals)
    }
}
