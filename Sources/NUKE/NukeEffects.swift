import SwiftUI

let nukeYellow = Color(red: 1.0, green: 0.79, blue: 0.08)

private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func segment(_ value: Double, from start: Double, to end: Double) -> Double {
    guard end > start else { return value >= end ? 1 : 0 }
    return clamp01((value - start) / (end - start))
}

private func smoothstep(_ value: Double) -> Double {
    let t = clamp01(value)
    return t * t * (3 - 2 * t)
}

private func easeOutExpo(_ value: Double) -> Double {
    let t = clamp01(value)
    return t == 1 ? 1 : 1 - pow(2, -10 * t)
}

struct NukeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, 18)
            .frame(minWidth: 172, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .black).opacity(isEnabled ? 0.88 : 0.35))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(nukeYellow)
                            .frame(width: 2, height: 18)
                            .padding(.leading, 10)
                            .opacity(isEnabled ? 1 : 0.35)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.07 : 0.13))
                    }
            }
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.20),
                radius: configuration.isPressed ? 2 : 8,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct NukeDetonationOverlay: View {
    let bytes: Int64
    let finished: () -> Void

    private let duration = ProcessInfo.processInfo.arguments.contains("--preview-detonation") ? 12.0 : 1.65
    @State private var startedAt: Date?
    @State private var didFinish = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            GeometryReader { geometry in
                let progress = animationProgress(at: timeline.date)
                let side = max(1, min(geometry.size.width, geometry.size.height))
                let captionIn = smoothstep(segment(progress, from: 0.58, to: 0.76))
                let fadeOut = smoothstep(segment(progress, from: 0.86, to: 1.0))

                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)

                    Color.black.opacity(0.54 - 0.18 * fadeOut)

                    DetonationCanvas(progress: progress)
                        .frame(width: side * 0.68, height: side * 0.68)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.44)

                    VStack(spacing: 6) {
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) gone")
                            .font(.system(size: 24, weight: .semibold))
                            .monospacedDigit()
                        Text("Scan again to see what remains.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, max(34, geometry.size.height * 0.105))
                    .opacity(captionIn * (1 - fadeOut))
                    .offset(y: 5 * (1 - captionIn))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
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

            drawGuideField(in: &context, center: center, side: side)
            drawCollapse(in: &context, center: center, side: side)
            drawIgnition(in: &context, center: center, side: side)
            drawShockRings(in: &context, center: center, side: side)
            drawFragments(in: &context, center: center, side: side)
        }
        .compositingGroup()
        .drawingGroup()
    }

    private func drawGuideField(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let enter = smoothstep(segment(progress, from: 0.00, to: 0.14))
        let fade = smoothstep(segment(progress, from: 0.52, to: 0.80))
        let opacity = enter * (1 - fade) * 0.17
        guard opacity > 0.001 else { return }

        for index in 0..<4 {
            let radius = side * CGFloat(0.12 + Double(index) * 0.075)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(opacity)),
                style: StrokeStyle(lineWidth: 0.8, dash: [2, 7], dashPhase: CGFloat(index * 3))
            )
        }
    }

    private func drawCollapse(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let collapse = smoothstep(segment(progress, from: 0.03, to: 0.28))
        let fade = smoothstep(segment(progress, from: 0.25, to: 0.38))
        let opacity = (1 - fade) * 0.62
        guard opacity > 0.001 else { return }

        for index in 0..<36 {
            let seed = Double(index)
            let angle = seed / 36 * Double.pi * 2 + sin(seed * 2.17) * 0.08
            let startRadius = side * CGFloat(0.20 + 0.13 * (sin(seed * 1.73) + 1) / 2)
            let radius = startRadius * CGFloat(1 - 0.88 * collapse)
            let length = side * CGFloat(0.010 + 0.018 * (sin(seed * 0.91) + 1) / 2)
            let tangent = CGVector(dx: CGFloat(-sin(angle)), dy: CGFloat(cos(angle)))
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
            var path = Path()
            path.move(to: CGPoint(x: point.x - tangent.dx * length, y: point.y - tangent.dy * length))
            path.addLine(to: CGPoint(x: point.x + tangent.dx * length, y: point.y + tangent.dy * length))
            context.stroke(path, with: .color((index % 5 == 0 ? nukeYellow : .white).opacity(opacity)), lineWidth: 1)
        }
    }

    private func drawIgnition(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let enter = easeOutExpo(segment(progress, from: 0.24, to: 0.34))
        let fade = smoothstep(segment(progress, from: 0.39, to: 0.64))
        let opacity = enter * (1 - fade)
        guard opacity > 0.001 else { return }

        let radius = side * CGFloat(0.015 + 0.075 * enter)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(opacity),
                    nukeYellow.opacity(opacity * 0.88),
                    Color.clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawShockRings(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        for index in 0..<3 {
            let delay = Double(index) * 0.055
            let travel = easeOutExpo(segment(progress, from: 0.30 + delay, to: 0.68 + delay))
            let fade = smoothstep(segment(progress, from: 0.52 + delay, to: 0.86 + delay))
            let opacity = (1 - fade) * (index == 0 ? 0.80 : 0.34)
            guard opacity > 0.001 else { continue }

            let radius = side * CGFloat(0.025 + 0.39 * travel)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color((index == 0 ? nukeYellow : Color.white).opacity(opacity)),
                lineWidth: index == 0 ? 1.8 : 0.75
            )
        }
    }

    private func drawFragments(in context: inout GraphicsContext, center: CGPoint, side: CGFloat) {
        let travel = easeOutExpo(segment(progress, from: 0.31, to: 0.77))
        let fade = smoothstep(segment(progress, from: 0.57, to: 0.91))
        let opacity = 1 - fade
        guard opacity > 0.001 else { return }

        for index in 0..<28 {
            let seed = Double(index)
            let angle = seed / 28 * Double.pi * 2 + sin(seed * 2.41) * 0.12
            let distance = side * CGFloat(0.04 + (0.24 + 0.08 * sin(seed * 1.37)) * travel)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * distance,
                y: center.y + CGFloat(sin(angle)) * distance
            )
            let length = side * CGFloat(0.006 + 0.008 * (sin(seed * 0.73) + 1) / 2)
            var path = Path()
            path.move(to: point)
            path.addLine(to: CGPoint(
                x: point.x - CGFloat(cos(angle)) * length,
                y: point.y - CGFloat(sin(angle)) * length
            ))
            context.stroke(
                path,
                with: .color((index % 6 == 0 ? nukeYellow : Color.white).opacity(opacity * 0.72)),
                lineWidth: index % 6 == 0 ? 1.4 : 0.8
            )
        }
    }
}
