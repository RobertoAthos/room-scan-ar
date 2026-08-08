import SwiftUI

/// Reticle pinned to the centre of the screen. Changes colour depending on
/// whether there is a valid surface beneath it.
struct ReticleView: View {
    let state: ReticleState

    private var color: Color {
        switch state {
        case .searching:   .white.opacity(0.45)
        case .approximate: .orange
        case .valid:       .green
        }
    }

    private var ringSize: CGFloat {
        state == .searching ? 26 : 34
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: 2)
                .frame(width: ringSize, height: ringSize)

            Circle()
                .fill(color)
                .frame(width: 4, height: 4)

            // Cardinal ticks help aim precisely at the wall-floor junction.
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 1.5, height: 7)
                    .offset(y: -(ringSize / 2 + 5))
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .animation(.easeOut(duration: 0.15), value: state)
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        Color.gray
        VStack(spacing: 40) {
            ReticleView(state: .searching)
            ReticleView(state: .approximate)
            ReticleView(state: .valid)
        }
    }
}
