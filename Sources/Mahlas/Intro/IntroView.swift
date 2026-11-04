import SwiftUI

/// Cinematic opener: crimson light ribbons converge into a flare, the MAHLAS
/// wordmark slams in letter by letter, then the camera flies through the logo
/// into a white flash that the app fades out of.
struct IntroView: View {
    var onDone: () -> Void
    /// Renders a single frozen frame (used by `--snapshot`).
    var frozenTime: Double? = nil

    private static let letters = Array("MAHLAS").map(String.init)
    private static let ribbonHues: [Double] = [352, 4, 345, 10, 340, 356, 0, 14, 348, 6, 338, 18]

    /// Timeline in seconds, measured from when the intro mounts.
    private enum T {
        static let ribbons = 0.15
        static let flare = 1.0
        static let letters = 1.05
        static let letterGap = 0.15
        static let landing = 0.26
        static let tagline = 2.25
        static let zoom = 3.35
        static let done = 4.10
    }

    // Keyframe tracks (ported 1:1 from the web CSS)
    private static let ribbonEase = CubicBezier(0.65, 0, 0.25, 1)
    private static let ribbonX = Track([(0, 1), (0.8, 0), (1, 0)], easing: ribbonEase)          // × --from
    private static let ribbonSY = Track([(0, 0.35), (0.8, 1), (1, 0.6)], easing: ribbonEase)
    private static let ribbonSX = Track([(0, 1), (0.8, 1), (1, 0.2)], easing: ribbonEase)
    private static let ribbonOp = Track([(0, 0), (0.25, 1), (0.8, 1), (1, 0)], easing: ribbonEase)

    private static let flareEase = CubicBezier(0.2, 0.8, 0.2, 1)
    private static let flareSX = Track([(0, 0), (0.3, 1), (1, 1.15)], easing: flareEase)
    private static let flareSY = Track([(0, 1), (0.3, 1), (1, 0.3)], easing: flareEase)
    private static let flareOp = Track([(0, 0), (0.3, 1), (1, 0)], easing: flareEase)

    private static let letterEase = CubicBezier(0.2, 0.9, 0.3, 1)
    private static let letterOp = Track([(0, 0), (0.55, 1), (1, 1)], easing: letterEase)
    private static let letterScale = Track([(0, 2.6), (0.55, 0.94), (0.78, 1.04), (1, 1)], easing: letterEase)
    private static let letterY = Track([(0, -0.04), (0.55, 0), (1, 0)], easing: letterEase)
    private static let glint = Track([(0, 0), (0.4, 1), (1, 0)], easing: .easeOut)

    private static let zoomEase = CubicBezier(0.7, 0, 0.9, 0.4)

    @State private var start = Date()
    @State private var finished = false
    @State private var cancelled = false

    var body: some View {
        GeometryReader { geo in
            if let frozenTime {
                frame(t: frozenTime, size: geo.size)
            } else {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSince(start)
                    frame(t: t, size: geo.size)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { if frozenTime == nil { schedule() } }
        .onDisappear { cancelled = true }
    }

    // MARK: Frame

    @ViewBuilder
    private func frame(t: Double, size: CGSize) -> some View {
        let zoomP = progress(t, delay: T.zoom, duration: 0.8)
        let zoomE = Self.zoomEase(zoomP)
        let flashP = CubicBezier.easeIn(progress(t, delay: T.zoom, duration: 0.75))
        let fontSize = min(size.width * 0.135, size.height * 0.32)

        ZStack {
            // Backdrop
            Theme.bg
            RadialGradient(
                stops: [
                    .init(color: Color(hex: 0x7A0B16), location: 0),
                    .init(color: Color(hex: 0x33060E), location: 0.45),
                    .init(color: Theme.bg, location: 0.8)
                ],
                center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.6
            )
            .scaleEffect(x: 1.15, y: 0.9)

            // Converging light ribbons
            ZStack {
                ForEach(0..<Self.ribbonHues.count, id: \.self) { i in
                    ribbon(i: i, t: t, size: size)
                }
                flare(t: t, size: size)
            }

            // Wordmark
            VStack(spacing: fontSize * 0.12) {
                HStack(spacing: 0) {
                    ForEach(Array(Self.letters.enumerated()), id: \.offset) { i, l in
                        letter(l, i: i, t: t, fontSize: fontSize)
                    }
                }
                Text("HER AÇILIŞ, YENİ BİR KİMLİK")
                    .font(Theme.body(max(11, fontSize * 0.075), weight: .medium))
                    .tracking(max(5, fontSize * 0.045))
                    .foregroundStyle(Theme.ink.opacity(0.72))
                    .opacity(CubicBezier.easeOut(progress(t, delay: T.tagline, duration: 0.8)))
                    .offset(y: 18 * (1 - CubicBezier.easeOut(progress(t, delay: T.tagline, duration: 0.8))))
            }
            .scaleEffect(1 + 13 * zoomE)
            .opacity(1 - zoomE)

            // Vignette
            RadialGradient(
                stops: [.init(color: .clear, location: 0.45), .init(color: Theme.bg.opacity(0.75), location: 1)],
                center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.72
            )
            .allowsHitTesting(false)

            GrainOverlay(opacity: 0.07)

            // White flash
            Color(hex: 0xFFF5F5).opacity(t >= T.zoom ? flashP : 0)
                .allowsHitTesting(false)

            // Skip
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: finish) {
                        Text("Geç ›")
                            .font(Theme.body(11, weight: .medium))
                            .tracking(3)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(t < T.zoom ? 1 : 0)
                }
                .padding(22)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func ribbon(i: Int, t: Double, size: CGSize) -> some View {
        let hue = Self.ribbonHues[i] / 360
        let side: Double = i % 2 == 0 ? -1 : 1
        let width = CGFloat(4 + ((i * 7) % 14))
        let from = side * Double(30 + i * 5) / 100 * size.width
        let p = progress(t, delay: T.ribbons + Double(i) * 0.03, duration: 0.95)
        let color = Color(hue: hue, saturation: 1, brightness: 1)

        return Capsule()
            .fill(LinearGradient(colors: [.clear, color, .clear], startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: size.height * 1.2)
            .shadow(color: color.opacity(0.8), radius: 9)
            .scaleEffect(x: Self.ribbonSX.value(at: p), y: Self.ribbonSY.value(at: p))
            .offset(x: CGFloat((Double(i) - 6) * 12) + CGFloat(from * Self.ribbonX.value(at: p)))
            .opacity(Self.ribbonOp.value(at: p))
            .blendMode(.screen)
    }

    private func flare(t: Double, size: CGSize) -> some View {
        let p = progress(t, delay: T.flare, duration: 0.7)
        return Capsule()
            .fill(LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.35),
                        .init(color: .white, location: 0.65), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing))
            .frame(width: size.width * 0.8, height: 3)
            .shadow(color: Theme.redHi, radius: 12)
            .shadow(color: Theme.red.opacity(0.9), radius: 30)
            .scaleEffect(x: Self.flareSX.value(at: p), y: Self.flareSY.value(at: p))
            .opacity(Self.flareOp.value(at: p))
    }

    private func letter(_ l: String, i: Int, t: Double, fontSize: CGFloat) -> some View {
        let d = T.letters + Double(i) * T.letterGap
        let p = progress(t, delay: d, duration: 0.5)
        let g = Self.glint.value(at: progress(t, delay: d + 1.2, duration: 0.7))

        return Text(l)
            .font(Theme.display(fontSize, weight: .black))
            .foregroundStyle(Color(hex: 0xFFEEF0).mix(with: .white, by: g))
            .shadow(color: Color(hex: 0xE11D2E).opacity(0.75 + 0.25 * g), radius: 14 + 12 * g)
            .shadow(color: Color(hex: 0xFF6A3D).opacity(0.5 + 0.4 * g), radius: 35 + 20 * g)
            .shadow(color: .white.opacity(0.9 * g), radius: 9)
            .scaleEffect(Self.letterScale.value(at: p))
            .offset(y: fontSize * CGFloat(Self.letterY.value(at: p)))
            .opacity(Self.letterOp.value(at: p))
    }

    // MARK: Timeline side-effects

    private func schedule() {
        start = Date()
        let synth = Synth.shared
        func at(_ s: Double, _ fn: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                guard !cancelled, !finished else { return }
                fn()
            }
        }
        at(T.letters + 0.05) { synth.swell() }
        for i in Self.letters.indices {
            at(T.letters + Double(i) * T.letterGap + T.landing) { synth.hit(i) }
        }
        at(T.done) { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }
}

/// Animated film grain, stepped like the web version's `steps(6)` jitter.
struct GrainOverlay: View {
    var opacity: Double = 0.06
    private static let image: Image = {
        let w = 160, h = 160
        var px = [UInt8](repeating: 0, count: w * h)
        for i in px.indices { px[i] = UInt8.random(in: 0...255) }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return Image(decorative: cg, scale: 1)
    }()
    private static let jitter: [CGPoint] = [.init(x: 0, y: 0), .init(x: -0.03, y: 0.02), .init(x: 0.02, y: -0.04),
                                            .init(x: -0.04, y: -0.01), .init(x: 0.03, y: 0.03), .init(x: -0.01, y: 0.04)]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 1.0 / 6)) { ctx in
                let step = Int(ctx.date.timeIntervalSinceReferenceDate * 6) % Self.jitter.count
                let j = Self.jitter[step]
                Self.image
                    .resizable(resizingMode: .tile)
                    .frame(width: geo.size.width * 2, height: geo.size.height * 2)
                    .offset(x: geo.size.width * (j.x - 0.5), y: geo.size.height * (j.y - 0.5))
            }
        }
        .opacity(opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
        .clipped()
    }
}
