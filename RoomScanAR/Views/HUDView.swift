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
            if manager.phase == .detectingFloor {
                floorDetectionPanel
            }

            HStack {
                Toggle(isOn: $manager.showDebugOverlays) {
                    Image(systemName: "ladybug.fill")
                }
                .toggleStyle(.button)
                .tint(.white)
                .foregroundStyle(.white)

                Spacer()

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
    }

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
}
