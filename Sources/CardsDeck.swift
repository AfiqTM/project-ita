import SwiftUI
import MetalKit

// MARK: - "Cards" theme: the Courses page as a stack of metal cards floating over dusk water
//
// Built from the reference clip (Crest hero): a dusk sky with faint stars and a glow on the horizon, a flat sea with
// horizontal ripple bands, a dark pool with rings spreading under the card, a thin ring behind the card that shows
// up again in the water as a wobbling reflection, and one portrait metal card (chip, contactless mark, logo, name,
// diagonal highlight) that floats, bobs and sways in 3D. The card's finish and the whole scene change together
// (ember -> violet -> aqua). Here every subject is a card: they stack behind the front one, and a swipe sends the
// front card to the back of the stack while the next one comes forward.

// MARK: Font (Plus Jakarta Sans, bundled; the system font when it isn't there)

func deckFont(_ size: CGFloat, bold: Bool = true) -> Font {
    guard JakartaFont.available else { return .system(size: size, weight: bold ? .semibold : .regular) }
    return .custom(bold ? JakartaFont.bold : JakartaFont.medium, size: size)
}

// MARK: Palettes (one per finish)

struct DeckPalette {
    var skyTop: UInt32, skyMid: UInt32, glow: UInt32
    var seaTop: UInt32, seaBottom: UInt32
    var cardDark: UInt32, cardMid: UInt32, cardStreak: UInt32, cardLight: UInt32, logo: UInt32
    var name: String

    static let ember = DeckPalette(skyTop: 0x2A1238, skyMid: 0x8E2748, glow: 0xFF9440,
                                   seaTop: 0xC93A24, seaBottom: 0x12050A,
                                   cardDark: 0x0B0909, cardMid: 0xB41F10, cardStreak: 0xFF5A3A, cardLight: 0xF0B090,
                                   logo: 0xFF6A2A, name: "Ember")
    static let violet = DeckPalette(skyTop: 0x150F38, skyMid: 0x56368A, glow: 0xE08ACF,
                                    seaTop: 0x7648A0, seaBottom: 0x0F0822,
                                    cardDark: 0x0A0914, cardMid: 0x3822C8, cardStreak: 0x8A70FF, cardLight: 0xC4B4FF,
                                    logo: 0x7A5AF8, name: "Violet")
    static let aqua = DeckPalette(skyTop: 0x05202A, skyMid: 0x0E5A60, glow: 0x58E8CC,
                                  seaTop: 0x2DA89F, seaBottom: 0x021013,
                                  cardDark: 0x05151A, cardMid: 0x0F6A68, cardStreak: 0x4FF0D0, cardLight: 0xBAF2E2,
                                  logo: 0x3DE8C0, name: "Aqua")
    static let all: [DeckPalette] = [.ember, .violet, .aqua]

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded())
        }
        return (ch(16) << 16) | (ch(8) << 8) | ch(0)
    }

    static func blend(_ a: DeckPalette, _ b: DeckPalette, _ t: Double) -> DeckPalette {
        DeckPalette(skyTop: mix(a.skyTop, b.skyTop, t), skyMid: mix(a.skyMid, b.skyMid, t), glow: mix(a.glow, b.glow, t),
                    seaTop: mix(a.seaTop, b.seaTop, t), seaBottom: mix(a.seaBottom, b.seaBottom, t),
                    cardDark: mix(a.cardDark, b.cardDark, t), cardMid: mix(a.cardMid, b.cardMid, t),
                    cardStreak: mix(a.cardStreak, b.cardStreak, t), cardLight: mix(a.cardLight, b.cardLight, t),
                    logo: mix(a.logo, b.logo, t), name: t < 0.5 ? a.name : b.name)
    }
}

// MARK: The logo mark on the card (a wave-like wedge)

struct CrestMark: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0.02, 0.78))
        p.addCurve(to: pt(0.42, 0.04), control1: pt(0.03, 0.40), control2: pt(0.22, 0.02))
        p.addCurve(to: pt(1.0, 0.55), control1: pt(0.62, 0.06), control2: pt(0.80, 0.42))
        p.addCurve(to: pt(0.78, 0.62), control1: pt(0.93, 0.52), control2: pt(0.86, 0.58))
        p.addCurve(to: pt(0.30, 0.96), control1: pt(0.66, 0.80), control2: pt(0.50, 0.98))
        p.addCurve(to: pt(0.02, 0.78), control1: pt(0.14, 0.95), control2: pt(0.0, 0.88))
        p.closeSubpath()
        return p
    }
}

// MARK: One metal card

struct DeckCardFace: View {
    let pal: DeckPalette
    let code: String          // bottom left, where the video says "Crest"
    let label: String         // small caps above the value ("CREDIT" in the video)
    let value: String         // "•••• 7240" in the video
    var sheen: Double = 0     // -1...1: slides the diagonal highlight as the card tilts

    private func faceGradient() -> LinearGradient {
        let s = CGFloat(sheen) * 0.05
        let stops: [Gradient.Stop] = [
            .init(color: Color(hex: pal.cardDark), location: 0),
            .init(color: Color(hex: pal.cardDark), location: 0.14 + s),
            .init(color: Color(hex: pal.cardMid), location: 0.50 + s),
            .init(color: Color(hex: pal.cardStreak), location: 0.62 + s),
            .init(color: Color(hex: pal.cardLight).opacity(0.92), location: 0.78 + s),
            .init(color: Color(hex: pal.cardLight), location: 1)
        ]
        return LinearGradient(stops: stops, startPoint: UnitPoint(x: 0.08, y: 0.12), endPoint: UnitPoint(x: 0.95, y: 0.88))
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            let corner = w * 0.06
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(faceGradient())
                // soft gloss from the top edge
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0)],
                                         startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
                // thin lit edge
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.06)],
                                           startPoint: .topTrailing, endPoint: .bottomLeading), lineWidth: 1)

                // contactless mark and chip, top right
                HStack(spacing: w * 0.035) {
                    chip(w)
                }
                .position(x: w * 0.74, y: h * 0.13)

                // the logo
                CrestMark().fill(Color(hex: pal.logo))
                    .frame(width: w * 0.30, height: w * 0.25)
                    .position(x: w * 0.5, y: h * 0.45)

                // bottom: name left, label and value right
                Text(code)
                    .font(deckFont(w * 0.105, bold: false))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: w * 0.5, alignment: .leading)
                    .position(x: w * 0.08 + w * 0.25, y: h * 0.915)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(label).font(deckFont(w * 0.034, bold: false)).tracking(0.6)
                        .foregroundColor(Color.white.opacity(0.5))
                    Text(value).font(.system(size: w * 0.05, weight: .regular, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.62))
                }
                .position(x: w * 0.82, y: h * 0.915)
            }
        }
    }

    private func chip(_ w: CGFloat) -> some View {
        let cw = w * 0.13
        return ZStack {
            RoundedRectangle(cornerRadius: cw * 0.16, style: .continuous).fill(Color.white.opacity(0.88))
            VStack(spacing: cw * 0.13) {
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1)
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1)
            }
            HStack(spacing: cw * 0.17) {
                Rectangle().fill(Color.black.opacity(0.28)).frame(width: 1)
                Rectangle().fill(Color.black.opacity(0.28)).frame(width: 1)
            }
        }
        .frame(width: cw, height: cw * 0.82)
    }
}

// MARK: The scene: sky, stars, sea, ripples, pool, ring and its reflection

struct DeckScene: View {
    let pal: DeckPalette
    let time: Double
    let horizon: CGFloat
    let cardX: CGFloat
    let cardTop: CGFloat
    let cardW: CGFloat
    let cardH: CGFloat
    let face: DeckCardFace?       // the front card, drawn upside down in the water
    let reflX: CGFloat            // where that reflection sits (follows the card when it is dragged)
    var overlayOnly = false       // true when the GPU water (DeckWaterView) draws the sky and sea: only the ring and reflection here

    private func c(_ hex: UInt32, _ a: Double = 1) -> Color { Color(hex: hex).opacity(a) }

    var body: some View {
        Canvas(opaque: !overlayOnly, rendersAsynchronously: true) { ctx, size in
            if overlayOnly {
                drawReflection(&ctx, size)
            } else {
                drawSky(&ctx, size)
                drawSea(&ctx, size)
                drawPool(&ctx, size)
                drawReflection(&ctx, size)
                drawVignette(&ctx, size)
            }
        } symbols: {
            if let f = face {
                f.frame(width: cardW, height: cardH).tag(0)
            }
        }
    }

    /// The card in the water: the picture is cut into thin strips, each shifted sideways by a travelling wave, and it
    /// fades with depth, so the reflection ripples like real water instead of sitting there as a flipped copy.
    private func drawReflection(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard face != nil, let sym = ctx.resolveSymbol(id: 0) else { return }
        let top = cardTop + cardH + 6
        let reach = cardH * 0.6
        let strip: CGFloat = 4
        var y: CGFloat = 0
        while y < reach {
            let k = Double(y / reach)                   // 0 at the card, 1 deep down
            let wob = CGFloat(sin(Double(y) * 0.16 + time * 2.4) + 0.5 * sin(Double(y) * 0.37 - time * 3.1)) * CGFloat(1.2 + k * 5)
            var l = ctx
            l.clip(to: Path(CGRect(x: 0, y: top + y, width: size.width, height: strip + 0.5)))
            l.opacity = 0.62 * pow(1 - k, 1.5)
            l.translateBy(x: reflX + wob, y: top)
            l.scaleBy(x: 1, y: -1)
            l.draw(sym, at: CGPoint(x: 0, y: -cardH / 2))
            y += strip
        }
    }

    // sky with a glow that climbs from the horizon, and faint twinkling stars
    private func drawSky(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let sky = CGRect(x: 0, y: 0, width: size.width, height: horizon)
        let colors: [Color] = [c(pal.skyTop), c(pal.skyMid), c(pal.glow, 0.95)]
        ctx.fill(Path(sky), with: .linearGradient(Gradient(colors: colors),
                                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        // the glow behind the card
        let glowColors: [Color] = [c(pal.glow, 0.55), c(pal.glow, 0)]
        ctx.fill(Path(sky), with: .radialGradient(Gradient(colors: glowColors), center: CGPoint(x: cardX, y: horizon),
                                                  startRadius: 0, endRadius: size.width * 0.75))
        // stars
        var seed: UInt64 = 7919
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFF) / 65535.0
        }
        for i in 0..<30 {
            let x = rnd() * Double(size.width)
            let y = rnd() * Double(horizon) * 0.62
            let a = 0.18 + 0.22 * (0.5 + 0.5 * sin(time * 1.1 + Double(i) * 1.7))
            let r = 0.5 + rnd() * 0.7
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(Color.white.opacity(a)))
        }
    }

    // the sea: it mirrors the sky (bright at the horizon, deep and dark near you), its surface is made of wavy bands that
    // grow with distance, and light glitters on it in a column under the glow
    private func drawSea(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let seaH = size.height - horizon
        let sea = CGRect(x: 0, y: horizon, width: size.width, height: seaH)
        let colors: [Color] = [c(pal.glow, 0.85), c(pal.seaTop), c(pal.seaTop, 0.5), c(pal.seaBottom)]
        let stops: [Gradient.Stop] = [.init(color: colors[0], location: 0), .init(color: colors[1], location: 0.10),
                                      .init(color: colors[2], location: 0.45), .init(color: colors[3], location: 1)]
        ctx.fill(Path(sea), with: .linearGradient(Gradient(stops: stops),
                                                  startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)))
        let lightColors: [Color] = [c(pal.glow, 0.5), c(pal.glow, 0)]
        ctx.fill(Path(sea), with: .radialGradient(Gradient(colors: lightColors),
                                                  center: CGPoint(x: cardX, y: horizon + 4),
                                                  startRadius: 0, endRadius: size.width * 0.65))

        // wavy bands
        let count = 36
        let step: CGFloat = 12
        for j in 0..<count {
            let d = pow(Double(j) / Double(count), 1.85)
            let y = horizon + CGFloat(d) * seaH
            let thick = 0.7 + CGFloat(d) * 8
            let amp = 0.2 + CGFloat(d) * 3.4
            let freq = 0.030 + 0.030 * (1 - d)
            let ph = time * (0.45 + 0.5 * d) + Double(j) * 1.7
            var upper: [CGPoint] = []
            var x: CGFloat = -12
            while x < size.width + 12 {
                let wave = CGFloat(sin(Double(x) * freq + ph) + 0.45 * sin(Double(x) * freq * 2.3 - ph * 1.4))
                upper.append(CGPoint(x: x, y: y + amp * wave))
                x += step
            }
            var band = Path()
            band.move(to: upper[0])
            for pt in upper.dropFirst() { band.addLine(to: pt) }
            for pt in upper.reversed() {
                let wave = CGFloat(sin(Double(pt.x) * freq + ph + 0.9))
                band.addLine(to: CGPoint(x: pt.x, y: pt.y + thick + amp * 0.4 * wave))
            }
            band.closeSubpath()
            let flick = sin(time * 0.8 + Double(j) * 0.9)
            ctx.fill(band, with: .color(Color.black.opacity(0.10 + 0.22 * d + 0.05 * flick)))
            var crest = Path()
            crest.move(to: upper[0])
            for pt in upper.dropFirst() { crest.addLine(to: pt) }
            ctx.stroke(crest, with: .color(c(pal.glow, max(0, 0.30 - 0.20 * d + 0.07 * flick))), lineWidth: max(0.5, thick * 0.28))
        }

        // glitter on the water, thickest under the glow
        var seed: UInt64 = 104729
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFF) / 65535.0
        }
        for i in 0..<48 {
            let u = pow(rnd(), 1.5)
            let y = horizon + CGFloat(u) * seaH * 0.9
            let spread = (0.18 + CGFloat(u) * 1.0) * cardW * 1.2
            let x = cardX + CGFloat(rnd() - 0.5) * 2 * spread
            let w = 2 + CGFloat(u) * 18
            let h = 0.7 + CGFloat(u) * 1.8
            let tw = sin(time * (2.0 + rnd() * 3.0) + Double(i) * 1.9)
            let a = max(0, tw) * (0.65 - 0.4 * u)
            ctx.fill(Path(roundedRect: CGRect(x: x - w / 2, y: y, width: w, height: h), cornerRadius: h / 2),
                     with: .color(Color.white.opacity(a * 0.8)))
            ctx.fill(Path(roundedRect: CGRect(x: x - w, y: y - 0.5, width: w * 2, height: h + 1), cornerRadius: h),
                     with: .color(c(pal.glow, a * 0.35)))
        }
        // haze and the bright line on the horizon
        let hazeColors: [Color] = [c(pal.glow, 0.45), c(pal.glow, 0)]
        ctx.fill(Path(CGRect(x: 0, y: horizon - 14, width: size.width, height: 30)),
                 with: .linearGradient(Gradient(colors: [hazeColors[1], hazeColors[0], hazeColors[1]]),
                                       startPoint: CGPoint(x: 0, y: horizon - 14), endPoint: CGPoint(x: 0, y: horizon + 16)))
        ctx.fill(Path(CGRect(x: 0, y: horizon - 0.5, width: size.width, height: 1.2)), with: .color(c(pal.glow, 0.75)))
    }

    // the dark pool under the card and the rings that spread from it
    private func drawPool(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let base = cardTop + cardH
        let shadow = CGRect(x: cardX - cardW * 0.62, y: base - cardW * 0.05, width: cardW * 1.24, height: cardW * 0.2)
        ctx.fill(Path(ellipseIn: shadow), with: .color(Color.black.opacity(0.55)))
        let glowRect = CGRect(x: cardX - cardW * 0.9, y: base - cardW * 0.1, width: cardW * 1.8, height: cardW * 0.34)
        let colors: [Color] = [c(pal.glow, 0.55), c(pal.glow, 0)]
        ctx.fill(Path(ellipseIn: glowRect), with: .radialGradient(Gradient(colors: colors),
                                                                  center: CGPoint(x: cardX, y: base + cardW * 0.07),
                                                                  startRadius: 0, endRadius: cardW * 0.9))
        for k in 0..<5 {
            var ph = time * 0.16 + Double(k) / 5.0
            ph -= floor(ph)
            let rx = cardW * (0.52 + CGFloat(ph) * 1.5)
            let ry = rx * 0.16
            let rect = CGRect(x: cardX - rx, y: base + cardW * 0.06 - ry, width: rx * 2, height: ry * 2)
            let fade = 1 - ph
            ctx.stroke(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.55 * fade)), lineWidth: 2 + CGFloat(ph) * 7)
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 3, dy: 1)), with: .color(c(pal.glow, 0.22 * fade)), lineWidth: 1)
        }
    }

    // the thin ring behind the card, and its reflection: the same arc mirrored in the water and wobbling
    private func drawRing(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let radius = cardW * 0.95
        let cy = cardTop + cardH * 0.50
        var above = Path()
        var below = Path()
        var started = false
        var startedB = false
        var a = Double.pi
        while a >= -0.0001 {          // left, over the top, to the right
            let x = cardX + radius * CGFloat(cos(a))
            let y = cy - radius * CGFloat(sin(a))
            if y <= horizon {
                if started { above.addLine(to: CGPoint(x: x, y: y)) } else { above.move(to: CGPoint(x: x, y: y)); started = true }
                let depth = (horizon - y)
                let ry = horizon + depth * 0.6
                let wob = CGFloat(sin(Double(ry) * 0.085 + time * 2.3)) * (1.5 + depth * 0.05)
                let p = CGPoint(x: x + wob, y: ry)
                if startedB { below.addLine(to: p) } else { below.move(to: p); startedB = true }
            }
            a -= 0.04
        }
        ctx.stroke(above, with: .color(c(pal.glow, 0.35)), lineWidth: 4)
        ctx.stroke(above, with: .color(Color.black.opacity(0.88)), lineWidth: 1.8)
        ctx.stroke(below, with: .color(Color.black.opacity(0.8)), lineWidth: 1.8)
    }

    private func drawVignette(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let colors: [Color] = [Color.black.opacity(0), Color.black.opacity(0.55)]
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(Gradient(colors: colors), center: CGPoint(x: size.width / 2, y: size.height * 0.45),
                                       startRadius: size.width * 0.55, endRadius: size.height * 0.85))
    }
}

// MARK: The deck (the Courses page in the Cards theme)

struct CourseDeckView: View {
    let courses: [Course]
    let loading: Bool
    let name: String
    var starred: (Course) -> Bool
    var onOpen: (Course) -> Void
    var onStar: (Course) -> Void
    var onHide: (Course) -> Void

    @ObservedObject private var timetable = TimetableManager.shared
    @State private var front = 0
    @State private var dragX: CGFloat = 0
    @State private var palFrom = DeckPalette.ember
    @State private var palTo = DeckPalette.ember
    @State private var switchStart = Date.distantPast

    private func finish(_ i: Int) -> DeckPalette { DeckPalette.all[((i % 3) + 3) % 3] }

    /// The scene's colours at this moment (they glide from one finish to the next over about a second)
    private func palette(at date: Date) -> DeckPalette {
        let raw = min(max(date.timeIntervalSince(switchStart) / 1.1, 0), 1)
        let eased = raw * raw * (3 - 2 * raw)
        return DeckPalette.blend(palFrom, palTo, eased)
    }

    private func goTo(_ newFront: Int) {
        let now = palette(at: Date())
        palFrom = now
        palTo = finish(newFront)
        switchStart = Date()
    }

    private func slot(of index: Int) -> Int {
        let n = max(courses.count, 1)
        return ((index - front) % n + n) % n
    }

    // MARK: layout numbers

    private struct Layout {
        var W: CGFloat, H: CGFloat, top: CGFloat
        var cardW: CGFloat, cardH: CGFloat, cardX: CGFloat, cardTop: CGFloat
        var horizon: CGFloat, headlineBottom: CGFloat, barY: CGFloat
    }

    private func layout(_ g: GeometryProxy) -> Layout {
        let ins = g.safeAreaInsets
        let W = g.size.width
        let H = g.size.height + ins.top + ins.bottom
        let barRoom: CGFloat = ins.bottom > 60 ? ins.bottom : ins.bottom + 62
        let barY = H - barRoom - 46
        let headlineBottom = barY - 16
        let zoneTop = ins.top + 128
        let zoneBottom = headlineBottom - 104
        let zoneH = max(zoneBottom - zoneTop, 220)
        let cardW = min(W * 0.56, 250, zoneH * 0.74)
        let cardH = cardW * 1.38
        let cardTop = zoneTop + (zoneH - cardH) / 2 + cardH * 0.06
        let horizon = cardTop + cardH * 0.58
        return Layout(W: W, H: H, top: ins.top, cardW: cardW, cardH: cardH, cardX: W / 2, cardTop: cardTop,
                      horizon: horizon, headlineBottom: headlineBottom, barY: barY)
    }

    // MARK: body

    var body: some View {
        GeometryReader { g in
            let L = layout(g)
            ZStack(alignment: .topLeading) {
                sceneAndCards(L)
                    .frame(width: L.W, height: L.H)
                .contentShape(Rectangle())
                .gesture(drag(L))
                textLayer(L)
            }
            .frame(width: L.W, height: L.H, alignment: .topLeading)
            .offset(y: -L.top)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            palFrom = finish(front); palTo = finish(front)
        }
        .onChange(of: courses.count) { n in
            if front >= n { front = 0 }
        }
    }

    /// The water scene redraws 30 times a second; the cards (cheap, just moving) run at the full screen rate
    @ViewBuilder private func sceneAndCards(_ L: Layout) -> some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                sceneLayer(L, tl.date)
            }
            if !courses.isEmpty {
                TimelineView(.animation) { tl in
                    cardsLayer(L, tl.date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    @ViewBuilder private func sceneLayer(_ L: Layout, _ date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let pal = palette(at: date)
        let bob = CGFloat(sin(t * 0.9)) * 5
        let rx = L.cardX + (dragX < 0 ? dragX * 0.9 : 0)
        if DeckMetalCore.shared != nil {
            // sky and sea on the GPU (smooth at the full frame rate); the ring and the card's reflection on top
            ZStack(alignment: .topLeading) {
                DeckWaterView(params: DeckWaterParams(width: L.W, height: L.H, horizon: L.horizon, cardX: L.cardX,
                                                      cardBottom: L.cardTop + L.cardH, cardW: L.cardW,
                                                      from: palFrom, to: palTo,
                                                      switchAgo: date.timeIntervalSince(switchStart)))
                    .frame(width: L.W, height: L.H)
                DeckScene(pal: pal, time: t, horizon: L.horizon, cardX: L.cardX, cardTop: L.cardTop + bob,
                          cardW: L.cardW, cardH: L.cardH, face: frontFace(pal), reflX: rx, overlayOnly: true)
                    .frame(width: L.W, height: L.H)
            }
        } else {
            DeckScene(pal: pal, time: t, horizon: L.horizon, cardX: L.cardX, cardTop: L.cardTop + bob,
                      cardW: L.cardW, cardH: L.cardH, face: frontFace(pal), reflX: rx)
                .frame(width: L.W, height: L.H)
        }
    }

    @ViewBuilder private func cardsLayer(_ L: Layout, _ t: Double) -> some View {
        let bob = CGFloat(sin(t * 0.9)) * 5
        ZStack(alignment: .topLeading) {
            ForEach(Array(courses.enumerated()), id: \.element.id) { i, c in
                cardView(i, c, L, t, bob)
            }
        }
        .frame(width: L.W, height: L.H, alignment: .topLeading)
    }

    private func frontFace(_ pal: DeckPalette) -> DeckCardFace? {
        guard !courses.isEmpty else { return nil }
        let c = courses[min(front, courses.count - 1)]
        return DeckCardFace(pal: pal, code: c.headerCode, label: label(c), value: value(c))
    }

    private struct SlotLook { var scale: CGFloat; var dy: CGFloat; var dx: CGFloat; var rot: Double; var opacity: Double; var dim: Double; var blur: CGFloat }

    /// How a card looks at a (possibly fractional) place in the stack: 0 = front, 1 = right behind it, ...
    private func look(_ s: Double, _ L: Layout) -> SlotLook {
        let k = min(max(s, 0), 5)
        let scale = 1 - 0.085 * k
        let step = L.cardH * 0.068
        let dy = -(1 - scale) * L.cardH / 2 - CGFloat(k) * step
        let side: Double = (Int(k.rounded(.down)) % 2 == 0) ? 1 : -1
        return SlotLook(scale: CGFloat(scale), dy: dy, dx: CGFloat(side * k * 5), rot: side * k * 1.8,
                        opacity: max(0, 1 - 0.2 * k), dim: 0.12 * k, blur: CGFloat(0.7 * k))
    }

    /// Where a card is while a finger is down. Finger moving left: the front card goes with it and the others come
    /// forward. Finger moving right: the card at the back slides in from the left, over the others.
    private func placement(slot sl: Int, _ L: Layout) -> (x: CGFloat, eff: Double) {
        let n = courses.count
        if n < 2 { return (dragX * 0.25, 0) }
        let p = min(abs(Double(dragX)) / Double(L.W * 0.6), 1)
        if dragX < 0 {
            return sl == 0 ? (dragX, 0) : (0, max(Double(sl) - p, 0))
        }
        if dragX > 0 {
            // out of the back of the stack to the left (a half-turn of a sine), then in over the others to the front
            return sl == n - 1 ? (-L.cardW * 0.8 * CGFloat(sin(p * Double.pi)), Double(n - 1) * (1 - p)) : (0, Double(sl) + p)
        }
        return (0, Double(sl))
    }

    @ViewBuilder private func cardView(_ i: Int, _ c: Course, _ L: Layout, _ t: Double, _ bob: CGFloat) -> some View {
        let sl = slot(of: i)
        let n = courses.count
        if sl <= 5 || sl == n - 1 {
            let isFront = sl == 0
            let pl = placement(slot: sl, L)
            let lk = look(pl.eff, L)
            let pal = finish(i)
            let mover = isFront && dragX < 0
            // the card coming back stays behind the others until it has been pulled out to the side
            let pullP = min(Double(max(dragX, 0)) / Double(L.W * 0.6), 1)
            let z: Double = (dragX > 0 && sl == n - 1 && n > 1) ? (pullP > 0.45 ? Double(n + 1) : 0) : Double(n - sl)
            let sway = isFront ? sin(t * 0.55) * 7 : sin(t * 0.55 + Double(sl)) * 3
            let sway2 = isFront ? sin(t * 0.4 + 1) * 3 : 0
            let tiltDrag = mover ? Double(dragX) / Double(L.W) * 40 : 0
            let spin = mover ? Double(dragX) / Double(L.W) * 14 : 0
            DeckCardFace(pal: pal, code: c.headerCode, label: label(c), value: value(c))
                .frame(width: L.cardW, height: L.cardH)
                .scaleEffect(lk.scale)
                .brightness(-lk.dim)
                .rotation3DEffect(.degrees(sway + tiltDrag), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(sway2), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .rotationEffect(.degrees(lk.rot + spin))
                .shadow(color: Color.black.opacity(isFront ? 0.4 : 0), radius: isFront ? 14 : 0, y: 8)
                .offset(x: L.cardX - L.cardW / 2 + lk.dx + pl.x,
                        y: L.cardTop + lk.dy + (isFront ? bob : bob * 0.5))
                .opacity(lk.opacity)
                .zIndex(z)
                .onTapGesture { if isFront { onOpen(c) } }
                .contextMenu {
                    if isFront {
                        Button { onStar(c) } label: {
                            Label(starred(c) ? "Unstar" : "Star", systemImage: starred(c) ? "star.slash" : "star")
                        }
                        Button { onHide(c) } label: { Label("Remove from view", systemImage: "eye.slash") }
                    }
                }
        }
    }

    // MARK: gestures

    private func drag(_ L: Layout) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard courses.count > 0 else { return }
                dragX = v.translation.width * 0.95
            }
            .onEnded { v in
                let dx = v.translation.width
                let predicted = v.predictedEndTranslation.width
                if courses.count > 1 && (abs(dx) > 70 || abs(predicted) > 170) {
                    advance(toRight: dx > 0, L)
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { dragX = 0 }
                }
            }
    }

    private let backSpring = Animation.spring(response: 0.5, dampingFraction: 0.84)

    /// One movement, no pause: right to left sends the front card straight round to the back of the stack (from
    /// wherever your finger left it) while the next one comes forward; left to right brings the back card straight to
    /// the front. A new swipe can start at any moment and takes over from where the cards are.
    private func advance(toRight: Bool, _ L: Layout) {
        let n = courses.count
        let target = toRight ? (front - 1 + n) % n : (front + 1) % n
        goTo(target)
        withAnimation(backSpring) { front = target; dragX = 0 }
    }

    // MARK: text around the scene (the video's page text, rewritten for the subject on top)

    private func label(_ c: Course) -> String { c.coverTags(timetable: timetable.data).first?.uppercased() ?? "PUBLIC" }
    private func value(_ c: Course) -> String {
        if let p = c.completionProgress(timetable: timetable.data) { return "\u{2022}\u{2022}\u{2022}\u{2022} \(Int(p.rounded()))%" }
        return "\u{2022}\u{2022}\u{2022}\u{2022} " + c.semShortLabel(timetable: timetable.data).replacingOccurrences(of: "SEM ", with: "S")
    }

    private func monoLine(_ text: String) -> Text {
        Text(text).font(mono(8.5)).tracking(0.8).foregroundColor(Color.white.opacity(0.5))
    }

    private func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }

    @ViewBuilder private func textLayer(_ L: Layout) -> some View {
        if courses.isEmpty {
            VStack(spacing: 10) {
                if loading { ProgressView().tint(.white) }
                Text(loading ? "Loading your subjects" : "No courses here.")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(Color.white.opacity(0.75))
            }
            .frame(width: L.W, height: L.H)
        } else {
            let c = courses[min(front, courses.count - 1)]
            let pal = DeckPalette.all[((front % 3) + 3) % 3]
            ZStack(alignment: .topLeading) {
                // top row: mark and name left, count right
                HStack(spacing: 7) {
                    CrestMark().fill(Color.white).frame(width: 15, height: 12)
                    Text("iTa\u{2019}leem").font(deckFont(13)).foregroundColor(.white)
                    Spacer(minLength: 0)
                    Text("\(courses.count) subjects").font(mono(10)).foregroundColor(Color.white.opacity(0.6))
                }
                .padding(.horizontal, 20)
                .offset(y: L.top + 10)

                // small mono lines (left) and a short paragraph (right), like the clip's page text
                VStack(alignment: .leading, spacing: 3) {
                    monoLine("/ \(c.semShortLabel(timetable: timetable.data))")
                    monoLine("/ \(c.sectionLabel?.uppercased() ?? "PUBLIC")")
                    monoLine("/ \(front + 1) OF \(courses.count)")
                }
                .padding(.leading, 20).offset(y: L.top + 52)

                Text("Swipe the card to bring the next subject forward. Tap it to open.")
                    .font(deckFont(10.5, bold: false)).lineSpacing(2).multilineTextAlignment(.trailing)
                    .foregroundColor(Color.white.opacity(0.68))
                    .frame(width: 150, alignment: .trailing)
                    .frame(width: L.W - 20, alignment: .trailing)
                    .offset(y: L.top + 50)

                // the big line at the bottom: the subject on top
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(pal.name.uppercased()) FINISH \u{00B7} \(courses.count) SUBJECTS")
                        .font(mono(8)).tracking(0.8).foregroundColor(Color.white.opacity(0.5))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 0.6))
                    HStack(alignment: .top, spacing: 8) {
                        Text(c.subjectName)
                            .font(deckFont(34)).tracking(-1.2)
                            .foregroundColor(.white)
                            .lineLimit(2).minimumScaleFactor(0.55).lineSpacing(-4)
                        Text(c.coverTags(timetable: timetable.data).first ?? "Public")
                            .font(deckFont(10)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.16))
                            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.6))
                            .clipShape(Capsule())
                            .padding(.top, 6)
                            .fixedSize()
                    }
                    .frame(width: L.W - 40, alignment: .leading)
                    .id(c.id)
                    .transition(.opacity)
                }
                .padding(.leading, 20)
                .offset(y: L.headlineBottom - 92)
                .animation(.easeInOut(duration: 0.3), value: front)

                bottomBar(c, pal, L).offset(y: L.barY)
            }
            .frame(width: L.W, height: L.H, alignment: .topLeading)
            .allowsHitTesting(true)
        }
    }

    // dots for the stack (left) and a small card with an Open button (right)
    private func bottomBar(_ c: Course, _ pal: DeckPalette, _ L: Layout) -> some View {
        HStack(alignment: .center) {
            HStack(spacing: 5) {
                ForEach(0..<min(courses.count, 8), id: \.self) { i in
                    Capsule().fill(Color(hex: finish(i).cardStreak).opacity(i == front % 8 ? 1 : 0.45))
                        .frame(width: i == front % 8 ? 16 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: front)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(width: L.W, alignment: .leading)
    }
}


// MARK: - The water on the GPU
//
// A fragment shader paints the whole sky and sea every frame: the sea is a perspective plane whose waves come from
// stretched noise (so they run in long horizontal streaks, thin at the horizon and wide near you), it mirrors the sky
// with more mirror near the horizon (Fresnel), glitters in a column under the glow, and carries the dark pool and the
// rings that spread from under the card. It is compiled when first needed; if that fails (or there is no GPU) the
// Canvas version above is used instead.

enum DeckMetal {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut deckVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    float fbm(float2 p) {
        float s = 0.0;
        float a = 0.5;
        for (int i = 0; i < 4; i++) {
            s += a * vnoise(p);
            p = p * 2.03 + float2(17.1, 9.2);
            a *= 0.5;
        }
        return s;
    }

    float3 pc(constant float *u, int o, float k) {
        float3 a = float3(u[o], u[o + 1], u[o + 2]);
        float3 b = float3(u[o + 15], u[o + 16], u[o + 17]);
        return mix(a, b, k);
    }

    float3 skyCol(float h, float3 top, float3 mid, float3 glow) {
        float3 c = mix(top, mid, smoothstep(0.0, 0.75, h));
        return mix(c, glow, smoothstep(0.6, 1.0, h) * 0.95);
    }

    fragment float4 deckFragment(VOut in [[stage_in]], constant float *u [[buffer(0)]]) {
        float2 res = float2(u[1], u[2]);
        float2 px = in.uv * res;
        float t = u[0];
        float H = u[3];
        float cx = u[4];
        float base = u[5];
        float cw = u[6];
        float k = u[7];
        float3 skyTop = pc(u, 8, k);
        float3 skyMid = pc(u, 11, k);
        float3 glow = pc(u, 14, k);
        float3 seaTop = pc(u, 17, k);
        float3 seaBot = pc(u, 20, k);
        float3 col;

        if (px.y < H) {
            float h = px.y / H;
            col = skyCol(h, skyTop, skyMid, glow);
            float d = length((px - float2(cx, H)) / (res.x * 0.8));
            col += glow * 0.5 * (1.0 - smoothstep(0.0, 1.0, d));
            float cell = 18.0;
            float2 g = floor(px / cell);
            float r = hash21(g);
            float2 c = (g + 0.2 + 0.6 * float2(hash21(g + 3.1), hash21(g + 7.7))) * cell;
            float star = step(0.97, r) * smoothstep(1.5, 0.0, length(px - c));
            star *= (0.5 + 0.5 * sin(t * 1.1 + r * 80.0)) * (1.0 - smoothstep(0.4, 0.7, h));
            col += star * 0.7;
        } else {
            float dy = px.y - H;
            float depth = clamp(dy / max(res.y - H, 1.0), 0.0, 1.0);
            float z = 160.0 / (dy + 8.0);
            float wx = (px.x - cx) * z / 90.0;
            float wz = z;
            float n1 = fbm(float2(wx * 0.8 + t * 0.04, wz * 1.5 - t * 0.30));
            float n2 = vnoise(float2(wx * 1.8 - t * 0.08, wz * 5.5 + t * 0.55));
            float hgt = n1 * 0.65 + n2 * 0.35;
            float band = 0.5 + 0.5 * sin(wz * 7.0 + hgt * 7.0 - t * 0.9);

            // the sea mirrors the sky, shaken by the waves
            float ry = H - dy * 0.85 + (hgt - 0.5) * (6.0 + 40.0 * depth);
            float3 refl = skyCol(clamp(ry / H, 0.0, 1.0), skyTop, skyMid, glow);
            float fres = 0.14 + 0.8 * pow(1.0 - depth, 2.2);
            float3 deep = mix(seaTop, seaBot, smoothstep(0.0, 0.8, depth));
            col = mix(deep, refl, fres * (0.45 + 0.55 * band));
            col *= 1.0 - 0.5 * smoothstep(0.6, 1.0, 1.0 - band) * (0.35 + 0.65 * depth);

            // glitter and light under the glow
            float w = exp(-pow((px.x - cx) / (cw * (0.3 + depth * 1.6)), 2.0));
            float sp = smoothstep(0.74, 0.92, vnoise(float2(wx * 9.0, wz * 24.0 + t * 1.3)));
            sp *= 0.5 + 0.5 * sin(t * 3.0 + hgt * 40.0);
            col += glow * 1.2 * sp * w * (1.0 - 0.5 * depth);
            col += glow * 0.22 * w * (1.0 - depth);
            col += glow * 0.55 * exp(-dy * 0.35);

            // the dark pool under the card and the rings that spread from it
            float2 pq = (px - float2(cx, base + cw * 0.05)) / float2(cw * 0.66, cw * 0.11);
            float pool = 1.0 - smoothstep(0.35, 1.0, dot(pq, pq));
            col = mix(col, col * 0.1, pool * 0.8);
            float2 rq = (px - float2(cx, base + cw * 0.06)) / float2(cw, cw * 0.17);
            float rr = length(rq) + (hgt - 0.5) * 0.05;
            float ph = fract(rr * 1.05 - t * 0.16);
            float ring = smoothstep(0.0, 0.08, ph) * (1.0 - smoothstep(0.08, 0.4, ph));
            float rfade = (1.0 - smoothstep(0.4, 2.6, rr)) * step(0.45, rr);
            col *= 1.0 - 0.6 * ring * rfade;
        }

        float2 q = (in.uv - float2(0.5, 0.45)) * float2(1.0, res.y / res.x);
        col *= 1.0 - 0.55 * smoothstep(0.45, 1.05, length(q));
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """
}

final class DeckMetalCore {
    static let shared: DeckMetalCore? = DeckMetalCore()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = try? d.makeLibrary(source: DeckMetal.source, options: nil),
              let vf = lib.makeFunction(name: "deckVertex"),
              let ff = lib.makeFunction(name: "deckFragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let ps = try? d.makeRenderPipelineState(descriptor: desc) else { return nil }
        device = d
        queue = q
        pipeline = ps
    }
}

/// What the shader needs from the page (all sizes in points)
struct DeckWaterParams {
    var width: CGFloat = 0, height: CGFloat = 0
    var horizon: CGFloat = 0, cardX: CGFloat = 0, cardBottom: CGFloat = 0, cardW: CGFloat = 0
    var from = DeckPalette.ember, to = DeckPalette.ember
    var switchAgo: Double = 10          // seconds since the finish last changed
}

final class DeckWaterRenderer: NSObject, MTKViewDelegate {
    let core: DeckMetalCore
    var params = DeckWaterParams()
    var stamp = CACurrentMediaTime()
    private let epoch = Date().timeIntervalSinceReferenceDate

    init(core: DeckMetalCore) { self.core = core }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func rgb(_ hex: UInt32) -> [Float] {
        [Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255]
    }

    private func colors(_ p: DeckPalette) -> [Float] {
        rgb(p.skyTop) + rgb(p.skyMid) + rgb(p.glow) + rgb(p.seaTop) + rgb(p.seaBottom)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let cb = core.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let sc = Float(view.contentScaleFactor)
        let now = Date().timeIntervalSinceReferenceDate
        let bob = Float(sin(now * 0.9)) * 5                       // the card bobs, and the pool under it with it
        let ago = params.switchAgo + (CACurrentMediaTime() - stamp)
        let raw = min(max(ago / 1.1, 0), 1)
        let k = Float(raw * raw * (3 - 2 * raw))

        var u: [Float] = [Float(now - epoch), Float(params.width) * sc, Float(params.height) * sc,
                          Float(params.horizon) * sc, Float(params.cardX) * sc, (Float(params.cardBottom) + bob) * sc,
                          Float(params.cardW) * sc, k]
        u += colors(params.from)
        u += colors(params.to)

        enc.setRenderPipelineState(core.pipeline)
        enc.setFragmentBytes(u, length: u.count * MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

struct DeckWaterView: UIViewRepresentable {
    var params: DeckWaterParams

    func makeCoordinator() -> DeckWaterRenderer {
        DeckWaterRenderer(core: DeckMetalCore.shared!)      // only created when DeckMetalCore.shared exists
    }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: DeckMetalCore.shared?.device)
        v.delegate = context.coordinator
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.framebufferOnly = true
        v.isOpaque = true
        v.isUserInteractionEnabled = false
        context.coordinator.params = params
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.params = params
        context.coordinator.stamp = CACurrentMediaTime()
    }
}
