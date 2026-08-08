import SwiftUI

/// Tela de resultados: medidas consolidadas, planta baixa e exportação em PDF.
struct ResultsView: View {
    let scan: RoomScan
    let onClose: () -> Void

    @State private var pdfURL: URL?
    @State private var exportFailed = false

    /// Rotação confirmada da planta.
    @State private var planRotation: Angle = .zero
    /// Rotação em curso durante o gesto, ainda não confirmada.
    @State private var liveRotation: Angle = .zero

    private var effectiveRotation: Angle { planRotation + liveRotation }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    measurementsGrid

                    planSection

                    if !scan.openings.isEmpty {
                        openingsList
                    }

                    exportSection
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Resultados")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Voltar ao AR", systemImage: "arkit", action: onClose)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Planta

    private var planSection: some View {
        VStack(spacing: 10) {
            FloorPlanView(scan: scan, rotation: effectiveRotation)
                .frame(height: 420)
                .background(.white)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.black.opacity(0.15), lineWidth: 1)
                }
                .gesture(rotationGesture)

            rotationControls
        }
        // O PDF sai na orientação exibida, então um arquivo já gerado fica
        // obsoleto assim que a planta gira.
        .onChange(of: planRotation) { _, _ in pdfURL = nil }
    }

    /// Gesto de dois dedos. Os botões de 90° existem em paralelo porque, durante
    /// uma gravação, botão é mais confiável do que acertar um gesto.
    private var rotationGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                liveRotation = value.rotation
            }
            .onEnded { value in
                planRotation = PlanTransform.snapRotation(planRotation + value.rotation)
                liveRotation = .zero
            }
    }

    private var rotationControls: some View {
        HStack(spacing: 10) {
            Button {
                rotate(by: -90)
            } label: {
                Label("Girar à esquerda", systemImage: "rotate.left")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                rotate(by: 90)
            } label: {
                Label("Girar à direita", systemImage: "rotate.right")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if planRotation != .zero {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { planRotation = .zero }
                } label: {
                    Text("Reorientar")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private func rotate(by degrees: Double) {
        withAnimation(.easeInOut(duration: 0.25)) {
            planRotation = PlanTransform.snapRotation(planRotation + .degrees(degrees))
        }
    }

    // MARK: - Medidas

    private var measurementsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metric("Área do piso", Format.squareMeters(scan.floorArea))
            metric("Perímetro", Format.meters(scan.perimeter))
            metric("Pé-direito", Format.meters(scan.ceilingHeight))
            metric("Parede (líquida)", Format.squareMeters(scan.netWallArea))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Paredes e aberturas

    private var openingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aberturas")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(scan.openings) { opening in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: opening.type))
                        .foregroundStyle(tint(for: opening.type))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(opening.type.label) · parede \(opening.wallIndex + 1)")
                            .font(.subheadline.weight(.medium))
                        Text(detail(for: opening))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func detail(for opening: Opening) -> String {
        var text = "\(Format.meters(opening.width)) × \(Format.meters(opening.height))"
        if opening.type.hasSill {
            text += " · peitoril \(Format.meters(opening.sillHeight))"
        }
        return text
    }

    private func icon(for type: OpeningType) -> String {
        switch type {
        case .door:        "door.left.hand.closed"
        case .slidingDoor: "door.sliding.left.hand.closed"
        case .openGap:     "rectangle.portrait.and.arrow.right"
        case .window:      "window.vertical.closed"
        }
    }

    private func tint(for type: OpeningType) -> Color {
        switch type {
        case .door:        .orange
        case .slidingDoor: .purple
        case .openGap:     .gray
        case .window:      .teal
        }
    }

    // MARK: - Exportação

    private var exportSection: some View {
        VStack(spacing: 10) {
            if let pdfURL {
                ShareLink(item: pdfURL) {
                    Label("Compartilhar PDF", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    pdfURL = PDFExporter.export(scan: scan, rotation: planRotation)
                    exportFailed = pdfURL == nil
                } label: {
                    Label("Exportar PDF", systemImage: "doc.badge.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if exportFailed {
                Text("Não foi possível gerar o PDF.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
