import SwiftUI
import UIKit

/// Floor plan export to PDF.
enum PDFExporter {

    /// A4 portrait in points (72 dpi), which is the PDF's native unit.
    static let pageSize = CGSize(width: 595, height: 842)

    /// Renders the plan into a **vector** PDF and returns the temporary file's URL.
    ///
    /// `ImageRenderer` draws straight into a PDF `CGContext` instead of producing
    /// a bitmap and wrapping it: lines and text come out as vectors, which is
    /// what keeps a plan legible when zoomed or printed.
    ///
    /// - Parameter rotation: the orientation chosen on screen. The PDF comes out
    ///   as the plan is being displayed — rotating the view alone would be
    ///   pointless, since the reason to rotate is to export oriented.
    @MainActor
    static func export(
        scan: RoomScan,
        rotation: Angle = .zero,
        fileName: String = "planta-baixa"
    ) -> URL? {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("\(fileName).pdf")

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let page = FloorPlanPage(scan: scan, rotation: rotation)
            .frame(width: pageSize.width, height: pageSize.height)

        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(pageSize)

        var succeeded = false
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            succeeded = true
        }
        context.closePDF()

        return succeeded ? url : nil
    }
}

/// The plan's page: a header with the measurements and the drawing below.
/// User-facing copy stays in Brazilian Portuguese, as the spec requires.
private struct FloorPlanPage: View {
    let scan: RoomScan
    let rotation: Angle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Planta baixa")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.black)

                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 12)

            FloorPlanView(scan: scan, rotation: rotation)

            Text("RoomScan AR")
                .font(.system(size: 10))
                .foregroundStyle(.black.opacity(0.4))
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
    }

    private var summary: String {
        var parts = [
            "Área \(Format.squareMeters(scan.floorArea))",
            "Perímetro \(Format.meters(scan.perimeter))",
            "Pé-direito \(Format.meters(scan.ceilingHeight))",
        ]

        // Iterate over every case rather than special-casing doors and windows:
        // a plan with only a sliding door or an open passage would otherwise
        // list no openings at all.
        for type in OpeningType.allCases {
            let count = scan.openings.count { $0.type == type }
            guard count > 0 else { continue }
            parts.append(count == 1 ? "1 \(type.label.lowercased())" : "\(count) \(type.pluralLabel.lowercased())")
        }

        return parts.joined(separator: "  ·  ")
    }
}
