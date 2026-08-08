import SwiftUI

/// Sobreposição da tela AR: instrução no topo, medidas e ações no rodapé.
struct HUDView: View {
    @ObservedObject var manager: ARSessionManager

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Topo

    private var topBar: some View {
        VStack(spacing: 8) {
            Text(manager.phase.instruction)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 14))

            if let status = manager.statusMessage {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(.yellow.opacity(0.92), in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: manager.statusMessage)
    }

    // MARK: - Rodapé

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 12) {
            switch manager.phase {
            case .detectingFloor:
                floorDetectionPanel
            case .markingCorners:
                markingCornersPanel
            case .measuringHeight:
                ceilingHeightPanel
            case .markingOpenings:
                openingsPanel
            case .results:
                EmptyView()
            }

            persistentControls
        }
    }

    /// Desfazer e Reiniciar acompanham todas as fases, conforme especificação.
    private var persistentControls: some View {
        HStack {
            Toggle(isOn: $manager.showDebugOverlays) {
                Image(systemName: "ladybug.fill")
            }
            .toggleStyle(.button)
            .tint(.white)
            .foregroundStyle(.white)

            Spacer()

            Button {
                manager.undo()
            } label: {
                Label("Desfazer", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(!manager.canUndo)

            Button(role: .destructive) {
                manager.reset()
            } label: {
                Label("Reiniciar", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }

    // MARK: - Fase: detecção de piso

    private var floorDetectionPanel: some View {
        VStack(spacing: 10) {
            if let candidate = manager.floorCandidate {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Piso detectado")
                            .font(.subheadline.weight(.semibold))
                        Text("\(Format.squareMeters(candidate.area)) · \(candidate.isClassifiedFloor ? "classificado como piso" : "plano horizontal mais baixo")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)

                Button {
                    manager.confirmFloor()
                } label: {
                    Text("Confirmar piso e começar")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Procurando o piso…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 16))
        .animation(.easeOut(duration: 0.25), value: manager.floorCandidate)
    }

    // MARK: - Fase: marcação de cantos

    private var markingCornersPanel: some View {
        VStack(spacing: 12) {
            headerRow
            measurements

            if manager.offersAutoClose {
                autoCloseChoice
            } else if manager.scan.isClosed {
                closedNotice
            } else {
                markingActions
            }
        }
        .padding(14)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 16))
        .animation(.easeOut(duration: 0.2), value: manager.offersAutoClose)
        .animation(.easeOut(duration: 0.2), value: manager.scan.isClosed)
        .animation(.easeOut(duration: 0.2), value: manager.wallsBuilt)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.scan.isClosed ? "square.dashed.inset.filled" : "circle.dotted.and.circle")
                .foregroundStyle(manager.scan.isClosed ? .green : .yellow)
            Text(headerText)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.white)
    }

    private var headerText: String {
        let count = manager.scan.corners.count
        if manager.scan.isClosed {
            return "Cômodo fechado · \(count) paredes"
        }
        return count == 1 ? "1 canto marcado" : "\(count) cantos marcados"
    }

    /// Medidas ao vivo. Com o polígono ainda aberto, a área é uma prévia:
    /// o *shoelace* fecha implicitamente do último canto ao primeiro.
    @ViewBuilder
    private var measurements: some View {
        if manager.scan.corners.count >= 3 {
            HStack(spacing: 0) {
                measurement(
                    label: manager.scan.isClosed ? "Área" : "Área (prévia)",
                    value: Format.squareMeters(manager.scan.floorArea)
                )
                Divider().frame(height: 30).overlay(.white.opacity(0.25))
                measurement(
                    label: "Perímetro",
                    value: Format.meters(manager.scan.perimeter)
                )
            }
        } else if manager.scan.corners.count == 2 {
            HStack(spacing: 0) {
                measurement(label: "Perímetro", value: Format.meters(manager.scan.perimeter))
            }
        }
    }

    private func measurement(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markingActions: some View {
        HStack(spacing: 10) {
            Button {
                manager.markCorner()
            } label: {
                Text("Marcar canto")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.yellow)
            .disabled(!manager.canMarkCorner)

            Button {
                manager.closePolygon()
            } label: {
                Label("Fechar", systemImage: "point.forward.to.point.capsulepath")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)
            .disabled(!manager.canClosePolygon)
        }
    }

    private var autoCloseChoice: some View {
        VStack(spacing: 10) {
            Text("Você marcou perto do primeiro canto. Fechar o cômodo aqui?")
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    manager.acceptAutoClose()
                } label: {
                    Text("Fechar cômodo")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)

                Button {
                    manager.declineAutoClose()
                } label: {
                    Text("Marcar mesmo assim")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
            }
        }
    }

    private var closedNotice: some View {
        VStack(spacing: 10) {
            if manager.wallsBuilt {
                Button {
                    manager.replayWallRise()
                } label: {
                    Label("Repetir animação", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
            } else {
                Button {
                    manager.buildWalls()
                } label: {
                    Label("Levantar paredes", systemImage: "square.3.layers.3d.top.filled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
            }

            closedActions
        }
    }

    /// Alinhar em 90° e avançar para o pé-direito, ambos disponíveis assim que
    /// o polígono fecha.
    private var closedActions: some View {
        HStack(spacing: 10) {
            if manager.scan.isSnapped {
                Button {
                    manager.revertOrthogonalSnap()
                } label: {
                    Label("Desfazer 90°", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            } else {
                Button {
                    manager.applyOrthogonalSnap()
                } label: {
                    Label("Alinhar em 90°", systemImage: "square.grid.2x2")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            Button {
                manager.beginHeightMeasurement()
            } label: {
                Label("Pé-direito", systemImage: "arrow.up.and.down")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }

    // MARK: - Fase: pé-direito

    private var ceilingHeightPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                measurement(label: "Pé-direito", value: Format.meters(manager.scan.ceilingHeight))
                Divider().frame(height: 30).overlay(.white.opacity(0.25))
                measurement(label: "Parede (líquida)", value: Format.squareMeters(manager.scan.netWallArea))
            }

            Button {
                manager.measureCeilingHeight()
            } label: {
                Label(
                    manager.ceilingSamples.isEmpty ? "Medir mirando no teto" : "Medir outro ponto",
                    systemImage: "scope"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.yellow)
            .disabled(manager.reticleState == .searching)

            // Teto inclinado não tem um pé-direito único. Medir vários pontos e
            // escolher entre mínimo, média e máximo é o que torna a fase
            // utilizável fora de um cômodo de laje.
            if let stats = manager.ceilingStats {
                slopedCeilingChoice(stats)
            }

            // Fallback manual, obrigatório pela especificação: se a medição
            // falhar durante a gravação, o usuário ajusta e segue. Stepper em vez
            // de teclado — o teclado sobre a câmera atrapalha mais do que ajuda.
            HStack {
                Text("Ajuste manual")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Stepper(
                    value: Binding(
                        get: { manager.scan.ceilingHeight },
                        set: { manager.setCeilingHeight($0) }
                    ),
                    in: ARSessionManager.minCeilingHeight...ARSessionManager.maxCeilingHeight,
                    step: 0.05
                ) {
                    Text(Format.meters(manager.scan.ceilingHeight))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .fixedSize()
            }

            Button {
                manager.confirmCeilingHeight()
            } label: {
                Text("Confirmar e seguir")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)
        }
        .padding(14)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 16))
    }

    /// Escolha entre as medições acumuladas, para tetos que não são planos.
    private func slopedCeilingChoice(
        _ stats: (minimum: Float, average: Float, maximum: Float)
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(manager.ceilingSamples.count) medições")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button("Limpar") { manager.clearCeilingSamples() }
                    .font(.caption)
                    .tint(.white.opacity(0.7))
            }

            HStack(spacing: 8) {
                ceilingOption("Mínimo", stats.minimum)
                ceilingOption("Média", stats.average)
                ceilingOption("Máximo", stats.maximum)
            }
        }
        .padding(10)
        .background(.white.opacity(0.10), in: .rect(cornerRadius: 12))
    }

    private func ceilingOption(_ label: String, _ value: Float) -> some View {
        Button {
            manager.setCeilingHeight(value)
        } label: {
            VStack(spacing: 1) {
                Text(label)
                    .font(.caption2)
                Text(Format.meters(value))
                    .font(.footnote.weight(.semibold).monospacedDigit())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(abs(manager.scan.ceilingHeight - value) < 0.005 ? .yellow : .white)
    }

    // MARK: - Fase: portas e janelas

    private var openingsPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "door.left.hand.closed")
                    .foregroundStyle(.orange)
                Text(openingsHeader)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.white)

            if manager.selectedWallIndex == nil {
                Text("Toque numa parede para selecioná-la.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if manager.draftWidth == nil {
                Button {
                    manager.markOpeningPoint()
                } label: {
                    Text(manager.draftStart == nil ? "Marcar início do vão" : "Marcar fim do vão")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.yellow)
                .disabled(!manager.canMarkOpeningPoint)
            } else {
                openingEditor
            }

            Button {
                manager.showResults()
            } label: {
                Label("Ver planta baixa", systemImage: "square.on.square.dashed")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)
        }
        .padding(14)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 16))
        .animation(.easeOut(duration: 0.2), value: manager.selectedWallIndex)
        .animation(.easeOut(duration: 0.2), value: manager.draftWidth)
    }

    private var openingsHeader: String {
        if let index = manager.selectedWallIndex {
            let count = manager.scan.openings.count
            return "Parede \(index + 1) selecionada · \(count) aberturas"
        }
        let count = manager.scan.openings.count
        return count == 1 ? "1 abertura" : "\(count) aberturas"
    }

    private var openingEditor: some View {
        VStack(spacing: 10) {
            Picker("Tipo", selection: Binding(
                get: { manager.draftType },
                set: { manager.setDraftType($0) }
            )) {
                ForEach(OpeningType.allCases, id: \.self) { type in
                    Text(type.shortLabel).tag(type)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Largura \(Format.meters(manager.draftWidth ?? 0))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if manager.draftType == .slidingDoor,
                   (manager.draftWidth ?? 0) >= OpeningType.slidingSuggestionWidth {
                    Text("vão largo · sugerido correr")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
            }

            Stepper(value: $manager.draftHeight, in: 0.4...3.0, step: 0.05) {
                Text("Altura \(Format.meters(manager.draftHeight))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white)
            }

            if manager.draftType.hasSill {
                Stepper(value: $manager.draftSill, in: 0...2.0, step: 0.05) {
                    Text("Peitoril \(Format.meters(manager.draftSill))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 10) {
                Button {
                    manager.confirmOpening()
                } label: {
                    Text("Adicionar")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.orange)
                .disabled(!manager.canConfirmOpening)

                Button {
                    manager.clearOpeningDraft()
                } label: {
                    Text("Cancelar")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
            }
        }
    }
}
