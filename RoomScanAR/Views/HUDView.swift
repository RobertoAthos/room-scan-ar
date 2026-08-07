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
            default:
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

    /// A medição de pé-direito é a Etapa 5; até lá o fechamento é o fim do fluxo.
    private var closedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Toque em Desfazer para reabrir e ajustar os cantos.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
    }
}
