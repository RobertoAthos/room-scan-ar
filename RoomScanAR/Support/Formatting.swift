import Foundation

/// Number formatting in pt-BR (decimal comma, two places), matching the app's
/// Brazilian Portuguese interface.
///
/// Uses `FormatStyle` rather than `NumberFormatter`: the latter is a
/// non-`Sendable` class, which rules out holding it as a `static let` under
/// Swift 6 strict concurrency checking. Output is identical.
enum Format {
    private static let locale = Locale(identifier: "pt_BR")

    private static var twoDecimals: FloatingPointFormatStyle<Double> {
        .number.locale(locale).precision(.fractionLength(2)).grouping(.never)
    }

    /// e.g. "3,45 m"
    static func meters(_ value: Float) -> String {
        "\(Double(value).formatted(twoDecimals)) m"
    }

    /// e.g. "12,30 m²"
    static func squareMeters(_ value: Float) -> String {
        "\(Double(value).formatted(twoDecimals)) m²"
    }

    /// Bare number, no unit — for labels where the unit is already in the header.
    static func decimal(_ value: Float) -> String {
        Double(value).formatted(twoDecimals)
    }
}
