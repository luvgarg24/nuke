import SwiftUI

struct NukeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .black, design: .rounded))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.82, blue: 0.0))
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(configuration.isPressed ? 0.08 : 0.30), lineWidth: 1)
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.black.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.10 : 0.34), radius: configuration.isPressed ? 1 : 2, x: 0, y: configuration.isPressed ? 1 : 4)
            .offset(y: configuration.isPressed ? 3 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct NukeDetonationOverlay: View {
    let bytes: Int64
    let finished: () -> Void
    @State private var phase = 0
    @State private var didFinish = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(phase >= 1 ? 0.74 : 0)
                    .ignoresSafeArea()

                if phase >= 1 {
                    Circle()
                        .stroke(Color(red: 1.0, green: 0.82, blue: 0.0).opacity(phase >= 4 ? 0 : 0.85), lineWidth: phase >= 3 ? 3 : 10)
                        .frame(width: phase >= 3 ? geo.size.width * 1.25 : 40, height: phase >= 3 ? geo.size.width * 1.25 : 40)
                        .blur(radius: phase >= 3 ? 2 : 0)
                }

                VStack(spacing: 0) {
                    Spacer()
                    ZStack(alignment: .bottom) {
                        if phase >= 2 {
                            Circle()
                                .fill(Color.white.opacity(phase == 2 ? 0.98 : 0))
                                .frame(width: phase == 2 ? 260 : 520, height: phase == 2 ? 260 : 520)
                                .blur(radius: phase == 2 ? 12 : 30)

                            VStack(spacing: -22) {
                                ZStack {
                                    Circle().fill(Color(red: 1.0, green: 0.82, blue: 0.0)).frame(width: phase >= 3 ? 190 : 70, height: phase >= 3 ? 105 : 70)
                                    Circle().fill(Color.white.opacity(0.72)).frame(width: phase >= 3 ? 110 : 40, height: phase >= 3 ? 62 : 40).blur(radius: 8)
                                }
                                RoundedRectangle(cornerRadius: 30)
                                    .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.0), .orange.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                                    .frame(width: phase >= 3 ? 54 : 24, height: phase >= 3 ? 118 : 34)
                            }
                            .transition(.scale(scale: 0.25).combined(with: .opacity))
                        } else {
                            Image(systemName: "capsule.portrait.fill")
                                .font(.system(size: 38, weight: .black))
                                .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.0))
                                .rotationEffect(.degrees(180))
                                .offset(y: phase == 0 ? -geo.size.height * 0.45 : 0)
                                .shadow(color: .yellow.opacity(0.35), radius: 8)
                        }
                    }
                    .frame(height: 230)

                    if phase >= 4 {
                        VStack(spacing: 6) {
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) nuked.")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .monospacedDigit()
                            Text("Your Mac can breathe again.")
                                .foregroundStyle(.secondary)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Spacer()
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.72), value: phase)
        }
        .allowsHitTesting(true)
        .onAppear { detonate() }
    }

    private func detonate() {
        phase = 0
        withAnimation(.easeIn(duration: 0.42)) { phase = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) { withAnimation(.easeOut(duration: 0.10)) { phase = 2 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) { withAnimation(.spring(response: 0.46, dampingFraction: 0.64)) { phase = 3 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.18) { withAnimation(.easeOut(duration: 0.30)) { phase = 4 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) {
            guard !didFinish else { return }
            didFinish = true
            finished()
        }
    }
}
