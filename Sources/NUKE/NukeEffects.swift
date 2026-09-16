import SwiftUI

private let nukeYellow = Color(red: 1.0, green: 0.78, blue: 0.05)
private let nukeAmber = Color(red: 1.0, green: 0.47, blue: 0.06)

private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func segment(_ value: Double, from start: Double, to end: Double) -> Double {
    guard end > start else { return value >= end ? 1 : 0 }
    return clamp01((value - start) / (end - start))
}

private func easeOutCubic(_ value: Double) -> Double {
    let t = clamp01(value)
    return 1 - pow(1 - t, 3)
}

private func easeInOutCubic(_ value: Double) -> Double {
    let t = clamp01(value)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

struct NukeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.72))
                        .offset(y: configuration.isPressed ? 1 : 3)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .darkGray).opacity(0.92),
                                    Color.black.opacity(0.96)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(nukeYellow)
                                .frame(width: 3, height: 20)
                                .padding(.leading, 7)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(configuration.isPressed ? 0.08 : 0.16), lineWidth: 1)
                        }
                }
            }
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.14 : 0.28),
                radius: configuration.isPressed ? 2 : 5,
                x: 0,
                y: configuration.isPressed ? 1 : 3
            )
            .offset(y: configuration.isPressed ? 2 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.075), value: configuration.isPressed)
    }
}

struct NukeDetonationOverlay: View {
    let bytes: Int64
    let finished: () -> Void

    private let duration = 1.72
    @State private var startedAt: Date?
    @State private var didFinish = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            GeometryReader { geo in
                let progress = animationProgress(at: timeline.date)
                let shortestSide = max(1, min(geo.size.width, geo.size.height))
                let textIn = easeOutCubic(segment(progress, from: 0.66, to: 0.84))
                let dimIn = easeOutCubic(segment(progress, from: 0.00, to: 0.10))
                let dimOut = easeInOutCubic(segment(progress, from: 0.80, to: 1.00))

                ZStack {
                    Color.black
                        .opacity((0.58 * dimIn) * (1 - 0.68 * dimOut))

                    DetonationCanvas(progress: progress)
                        .frame(width: shortestSide * 0.82, height: shortestSide * 0.82)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.45)

                    VStack(spacing: 5) {
                        Spacer()

                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) nuked.")
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                            .monospacedDigit()

                        Text("Space reclaimed.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, max(34, geo.size.height * 0.10))
                    .opacity(textIn * (1 - 0.45 * dimOut))
                    .offset(y: 8 * (1 - textIn))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
        .allowsHitTesting(true)
        .onAppear {
            startedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                guard !didFinish else { return }
                didFinish = true
                finished()
            }
        }
    }

    private func animationProgress(at date: Date) -> Double {
        guard let startedAt else { return 0 }
        return clamp01(date.timeIntervalSince(startedAt) / duration)
    }
}

private struct DetonationCanvas: View {
    let progress: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            drawFlash(in: &context, center: center, side: side)
            drawShockwave(in: &context, center: center, side: side)
            drawParticles(in: &context, center: center, side: side)
            drawCloud(in: &context, center: center, side: side)
        }
        .compositingGroup()
    }

    private func drawFlash(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let appear = easeOutCubic(segment(progress, from: 0.10, to: 0.20))
        let disappear = easeOutCubic(segment(progress, from: 0.22, to: 0.43))
        let visibility = appear * (1 - disappear)
        guard visibility > 0.001 else { return }

        let radius = side * CGFloat(0.055 + 0.22 * easeOutCubic(segment(progress, from: 0.10, to: 0.34)))
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)

        context.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(0.98 * visibility),
                    nukeYellow.opacity(0.92 * visibility),
                    nukeAmber.opacity(0.34 * visibility),
                    Color.clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawShockwave(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let wave = easeOutCubic(segment(progress, from: 0.17, to: 0.58))
        let fade = easeOutCubic(segment(progress, from: 0.38, to: 0.68))
        let opacity = (1 - fade) * 0.82
        guard opacity > 0.001 else { return }

        let radius = side * CGFloat(0.035 + 0.39 * wave)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        context.stroke(path, with: .color(nukeYellow.opacity(opacity)), lineWidth: max(1, 5 - 3.5 * wave))
    }

    private func drawParticles(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let travel = easeOutCubic(segment(progress, from: 0.17, to: 0.63))
        let fade = easeOutCubic(segment(progress, from: 0.42, to: 0.72))
        let opacity = 1 - fade
        guard opacity > 0.001 else { return }

        for index in 0..<22 {
            let seed = Double(index)
            let angle = (seed / 22.0) * Double.pi * 2 + sin(seed * 1.91) * 0.15
            let maxDistance = side * CGFloat(0.16 + (sin(seed * 2.37) + 1) * 0.055)
            let distance = maxDistance * CGFloat(travel)
            let x = center.x + cos(angle) * distance
            let y = center.y + sin(angle) * distance
            let diameter = CGFloat(1.7 + (index % 4)) * CGFloat(1 - 0.42 * travel)
            let rect = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
            context.fill(Path(ellipseIn: rect), with: .color((index % 3 == 0 ? Color.white : nukeYellow).opacity(opacity * 0.86)))
        }
    }

    private func drawCloud(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let grow = easeOutCubic(segment(progress, from: 0.23, to: 0.53))
        let fade = easeOutCubic(segment(progress, from: 0.64, to: 0.90))
        let opacity = (1 - fade) * 0.96
        guard opacity > 0.001 else { return }

        let lift = side * CGFloat(0.045 * grow)
        let cloudCenter = CGPoint(x: center.x, y: center.y - lift)

        let stemWidth = side * CGFloat(0.042 + 0.010 * grow)
        let stemHeight = side * CGFloat(0.03 + 0.16 * grow)
        let stemRect = CGRect(
            x: cloudCenter.x - stemWidth / 2,
            y: cloudCenter.y,
            width: stemWidth,
            height: stemHeight
        )
        context.fill(
            Path(roundedRect: stemRect, cornerRadius: stemWidth / 2),
            with: .linearGradient(
                Gradient(colors: [
                    nukeYellow.opacity(opacity),
                    nukeAmber.opacity(opacity * 0.74)
                ]),
                startPoint: CGPoint(x: stemRect.midX, y: stemRect.minY),
                endPoint: CGPoint(x: stemRect.midX, y: stemRect.maxY)
            )
        )

        let capWidth = side * CGFloat(0.08 + 0.28 * grow)
        let capHeight = side * CGFloat(0.055 + 0.10 * grow)
        let capY = cloudCenter.y - capHeight * 0.54

        let lobes: [(CGFloat, CGFloat, CGFloat)] = [
            (-0.30, 0.10, 0.46),
            (-0.13, -0.04, 0.58),
            (0.08, -0.08, 0.64),
            (0.29, 0.08, 0.48),
            (0.00, 0.14, 0.72)
        ]

        for (xFactor, yFactor, scale) in lobes {
            let width = capWidth * scale
            let height = capHeight * (0.72 + scale * 0.34)
            let x = cloudCenter.x + capWidth * xFactor
            let y = capY + capHeight * yFactor
            let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
            context.fill(Path(ellipseIn: rect), with: .color(nukeYellow.opacity(opacity)))
        }

        let coreWidth = capWidth * 0.48
        let coreHeight = capHeight * 0.54
        let coreRect = CGRect(
            x: cloudCenter.x - coreWidth / 2,
            y: capY - coreHeight / 2,
            width: coreWidth,
            height: coreHeight
        )
        context.fill(Path(ellipseIn: coreRect), with: .color(Color.white.opacity(opacity * 0.56)))
    }
}
