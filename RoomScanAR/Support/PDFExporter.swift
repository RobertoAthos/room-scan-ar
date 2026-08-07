import SwiftUI
import UIKit

/// Exportação da planta baixa em PDF.
enum PDFExporter {

    /// A4 retrato em pontos (72 dpi), que é a unidade nativa do PDF.
    static let pageSize = CGSize(width: 595, height: 842)

    /// Renderiza a planta num PDF **vetorial** e devolve a URL do arquivo temporário.
    ///
    /// O `ImageRenderer` desenha direto num `CGContext` de PDF, em vez de gerar um
    /// bitmap e embrulhá-lo: linhas e texto saem como vetor, que é o que faz uma
    /// planta continuar legível ampliada ou impressa.
    @MainActor
    static func export(scan: RoomScan, fileName: String = "planta-baixa") -> URL? {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("\(fileName).pdf")

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let page = FloorPlanPage(scan: scan)
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

/// Página da planta: cabeçalho com as medidas e o desenho abaixo.
private struct FloorPlanPage: View {
    let scan: RoomScan

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

            FloorPlanView(scan: scan)

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
        if !scan.openings.isEmpty {
            let doors = scan.openings.count { $0.type == .door }
            let windows = scan.openings.count { $0.type == .window }
            if doors > 0 { parts.append(doors == 1 ? "1 porta" : "\(doors) portas") }
            if windows > 0 { parts.append(windows == 1 ? "1 janela" : "\(windows) janelas") }
        }
        return parts.joined(separator: "  ·  ")
    }
}
