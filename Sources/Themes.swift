import SwiftUI
import Combine
import UIKit
import CoreText

// MARK: - Themes (Others > Themes)
//
// To add a theme: add a case to AppTheme with its name, description, colour scheme and palette (a `Palette`
// in Theme.swift). Everything else (the Themes screen, the preview card, the colours, the switch) follows.
//
// How a switch works: Theme's colours read the chosen palette. RootView gives its tabs a new identity per
// theme, so every screen is rebuilt and reads the new colours; the selected tab and the open Others screen
// are kept. To hide the rebuild, the current screen is frozen as a picture on top of the window while it
// happens and then faded out.

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, terminal, retro, redDead

    var id: String { rawValue }

    var name: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .terminal: return "Terminal"
        case .retro: return "Retro"
        case .redDead: return "Red Dead Redemption 2"
        }
    }

    var detail: String {
        switch self {
        case .dark: return "True black with the tan accent. Easy on the eyes at night."
        case .light: return "Warm off-white with a deeper tan accent. Easier to read in bright light."
        case .terminal: return "Terminal look: near-black, neon green, a monospaced font and a green glow."
        case .retro: return "Old-school arcade: black and olive tiles, yellow accent, hard pixel edges and a pixel-style font."
        case .redDead: return "Rockstar-poster look: black and red, stencil-style caps headings, flat cards with a red banner strip."
        }
    }

    /// Light themes use the light look for system parts (keyboard, pickers, status bar); the others use dark
    var scheme: ColorScheme { self == .light ? .light : .dark }

    /// Monospaced font everywhere
    var mono: Bool { self == .terminal || self == .retro }

    /// Arcade headings: the pixel font (when bundled, see PixelFont) with a hard block shadow
    var pixelHeadings: Bool { self == .retro }

    /// Red Dead headings: Chinese Rocks, the game's lettering
    var westernHeadings: Bool { self == .redDead }

    /// Aged-photograph vignette and film grain over the whole app
    var aged: Bool { self == .redDead }

    var palette: Palette {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .terminal: return .terminal
        case .retro: return .retro
        case .redDead: return .redDead
        }
    }

    /// CRT scanlines and a vignette over the whole app
    var scanlines: Bool { self == .terminal }

    /// Soft glow around prominent text (see `textGlow()`)
    var glowsText: Bool { self == .terminal }

    // MARK: Course covers (My courses)

    /// Gradients for courses without an image, picked per course
    var covers: [(UInt32, UInt32)] {
        switch self {
        case .dark:
            return [(0x1b1712, 0x3a2f22), (0x14181c, 0x2c3a46), (0x1a1417, 0x3d2a33),
                    (0x121a16, 0x263b2f), (0x181510, 0x4a3a22), (0x15151c, 0x302f4a)]
        case .light:
            return [(0xF1E8DA, 0xE0CFB4), (0xDFE8F0, 0xC3D4E2), (0xF0DFE5, 0xE0C3CF),
                    (0xDDECE3, 0xBFD9C9), (0xF2E9CF, 0xE3CFA0), (0xE2E2F1, 0xC9C8E6)]
        case .terminal:
            return [(0x03120A, 0x0B3A1C), (0x021512, 0x0A3A35), (0x0A1204, 0x2A3F0A),
                    (0x041208, 0x0F4A24), (0x02130F, 0x0C4040), (0x0A1005, 0x1E3A12)]
        case .retro:
            return [(0x0E0D00, 0x2B2700), (0x0A0A0A, 0x2A2A18), (0x140A00, 0x3D2600),
                    (0x081000, 0x24330A), (0x100012, 0x2E1A36), (0x00101A, 0x0A2E44)]
        case .redDead:
            return [(0x0A0A0A, 0x4A0F0B), (0x120606, 0x7A1A12), (0x0A0A0A, 0x2E0B08),
                    (0x180808, 0x8A1F14), (0x0C0C0C, 0x5A120D), (0x100505, 0x3A0D0A)]
        }
    }

    /// Photo covers: dimmed on the dark themes so they sit in the page, left as they are on the light one
    var coverBrightness: Double {
        switch self {
        case .dark: return -0.2
        case .light: return 0
        case .terminal: return -0.25
        case .retro: return -0.15
        case .redDead: return -0.2
        }
    }
    var coverSaturation: Double {
        switch self {
        case .terminal: return 0.6
        case .retro: return 0.9
        case .redDead: return 0.3
        default: return 1
        }
    }
    /// Terminal: photos get a green monitor tint. Retro: a yellow one, like a two-colour game screen.
    var coverTint: UInt32? {
        switch self {
        case .terminal: return 0x1FBF55
        case .retro: return 0xFFE628
        case .redDead: return 0xC4281C   // red-and-black print
        default: return nil
        }
    }
    /// The star on a cover sits on a dark circle, so it needs a bright accent in every theme
    var onCoverAccent: UInt32 {
        switch self {
        case .terminal: return Palette.terminal.accent
        case .retro: return Palette.retro.accent
        case .redDead: return 0xFFFFFF   // white: a red star would vanish on the dark circle
        default: return Palette.dark.accent
        }
    }

    // MARK: Preview card (Themes screen)

    /// Text in the preview's title bar, for themes that look like text (nil = a plain bar)
    var previewTitle: String? {
        switch self {
        case .terminal: return "> italeem_"
        case .retro: return "ITA'LEEM  1UP"
        case .redDead: return "WANTED"
        default: return nil
        }
    }
    /// Two lines in the preview's cards (nil = plain bars)
    var previewLines: (String, String)? {
        switch self {
        case .terminal: return ("$ cs101", "> 85% ok")
        case .retro: return ("CS101", "SCORE 85")
        case .redDead: return ("CS101", "$85 REWARD")
        default: return nil
        }
    }
}

/// The home-screen icon that goes with each theme. Each one is an alternate icon set in the asset catalog
/// (Assets.xcassets/AppIcon-Dark, AppIcon-Light, AppIcon-Terminal, AppIcon-Retro, AppIcon-RedDead) and listed in project.yml under
/// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
/// iOS shows its own "You have changed the icon" notice every time the icon changes; apps can't hide it.
/// The icon only follows the theme while the switch on the Themes screen is on.
enum AppIcon {
    /// "Change app icon based on theme" switch at the top of the Themes screen (on by default)
    static let followsThemeKey = "app.iconFollowsTheme"
    static var followsTheme: Bool {
        UserDefaults.standard.object(forKey: followsThemeKey) as? Bool ?? true
    }

    static func name(for theme: AppTheme) -> String {
        switch theme {
        case .dark: return "AppIcon-Dark"
        case .light: return "AppIcon-Light"
        case .terminal: return "AppIcon-Terminal"
        case .retro: return "AppIcon-Retro"
        case .redDead: return "AppIcon-RedDead"
        }
    }

    @MainActor
    static func apply(for theme: AppTheme) {
        let app = UIApplication.shared
        let wanted = name(for: theme)
        guard app.supportsAlternateIcons, app.alternateIconName != wanted else { return }
        app.setAlternateIconName(wanted) { _ in }   // a failure just leaves the old icon
    }
}

/// The chosen theme, remembered across launches.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "app.theme"

    @Published private(set) var theme: AppTheme

    var palette: Palette { theme.palette }

    private init() {
        // "AMOLED Dark" and "Programmer" were renamed: keep what people had chosen
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        let renamed = ["amoledDark": AppTheme.dark.rawValue, "programmer": AppTheme.terminal.rawValue][saved] ?? saved
        theme = AppTheme(rawValue: renamed) ?? .dark
        if renamed != saved { UserDefaults.standard.set(renamed, forKey: Self.key) }
    }

    /// Switches theme with a cross-fade: the current screen is frozen as a picture on top of the window,
    /// the theme changes underneath, then the picture fades away (so nothing flashes or jumps).
    @MainActor
    func select(_ new: AppTheme) {
        guard new != theme else { return }

        var cover: UIView?
        if !UIAccessibility.isReduceMotionEnabled,
           let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
           let snap = window.snapshotView(afterScreenUpdates: false) {
            snap.frame = window.bounds
            snap.isUserInteractionEnabled = false
            window.addSubview(snap)
            cover = snap
        }

        theme = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.key)
        Theme.applyAppearance()   // new navigation / tab bars (created when the screens are rebuilt) get the new look
        if AppIcon.followsTheme { AppIcon.apply(for: new) }   // home-screen icon follows the theme (if switched on)

        guard let cover else { return }
        // a moment for the rebuilt screens to render underneath, then fade the old picture out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            UIView.animate(withDuration: 0.45, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                cover.alpha = 0
            } completion: { _ in
                cover.removeFromSuperview()
            }
        }
    }
}

/// The pixel font of the Retro theme: "iTaleem Pixel" (Fonts/ITaleemPixel-Regular.ttf and -Bold.ttf, made by
/// Tools/make_pixel_font.py from classic 5x7 dot-matrix letters). Registered at launch. Eight pixel rows make
/// one em, so a size of 8 x N points draws N-point pixels (16 = 2 pt pixels, the crispest sizes).
enum PixelFont {
    static let regular = "ITaleemPixel-Regular"
    static let bold = "ITaleemPixel-Bold"

    static func register() {
        for name in [regular, bold] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// False if the font files didn't make it into the app: headings then fall back to a heavy monospaced font
    static var available: Bool { UIFont(name: bold, size: 8) != nil }
}

/// The Red Dead Redemption 2 theme's font, built by Tools/make_rdr_font.py into Fonts/ChineseRocksPlus-Regular.ttf:
/// capitals are Chinese Rocks (Typodermic Fonts, the lettering of the game's logo and website), small letters are
/// Tavern (Oleg Voznyy), "&", brackets and braces are redrawn and check marks, bullets, arrows and shapes are added,
/// so no symbol falls back to the system font. Check both licences (and whether they allow modified copies) before
/// publishing the app.
enum WesternFont {
    static let name = "ChineseRocksPlus-Regular"
    /// The letters are narrow, so every size is this much bigger than in the other themes to look as large as them
    static let scale: CGFloat = 1.2

    static func register() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static var available: Bool { UIFont(name: name, size: 12) != nil }
}

/// Chinese Rocks Rg (Fonts/ChineseRocksCaps-Regular.ttf, built by Tools/make_rocks_caps.py): all capitals, the
/// game's lettering, letters untouched. Only "&" "(" ")" "{" "}" are redrawn (from Staatliches), the same fix as in
/// WesternFont, because the original draws them like a plus and square brackets. The Red Dead theme uses it for
/// headings, tab strips, the tab bar, nav bar titles and buttons; body text keeps WesternFont.
enum RocksFont {
    static let name = "ChineseRocksCaps-Regular"
    /// Capitals only, so a little smaller than WesternFont's 1.2 keeps headings from looking shouty
    static let scale: CGFloat = 1.1
    /// Letter spacing (points) for headings; the capitals are narrow and touch at small sizes
    static let tracking: CGFloat = 0.9

    static func register() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static var available: Bool { UIFont(name: name, size: 12) != nil }

    /// UIKit font for the nav bar / tab bar (size is the final point size, `scale` is not applied)
    static func ui(_ size: CGFloat) -> UIFont? { UIFont(name: name, size: size) }
}

/// Chinese Rocks Rg for one piece of text in the Red Dead theme; every other theme keeps `normal` (or whatever
/// font the text already had). Use it on the text itself, and give the other themes' font through `normal`,
/// since a `.font` set closer to the text would win over this one.
struct RocksText: ViewModifier {
    var pt: CGFloat
    var tracking: CGFloat
    var normal: Font?
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        if themes.theme.westernHeadings && RocksFont.available {
            content
                .font(.custom(RocksFont.name, size: pt * RocksFont.scale))
                .tracking(tracking)
        } else if let normal {
            content.font(normal)
        } else {
            content
        }
    }
}

/// Like `pixelHeading`, but Red Dead uses Chinese Rocks Rg instead of the Tavern-mixed WesternFont.
struct RocksHeading: ViewModifier {
    var size: CGFloat
    var normal: Font?
    var pt: CGFloat
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        if themes.theme.westernHeadings && RocksFont.available {
            content
                .font(.custom(RocksFont.name, size: pt * RocksFont.scale))
                .tracking(RocksFont.tracking)
        } else {
            content.pixelHeading(size, normal: normal, pt: pt)
        }
    }
}
extension View {
    func rocks(_ pt: CGFloat, tracking: CGFloat = RocksFont.tracking, normal: Font? = nil) -> some View {
        modifier(RocksText(pt: pt, tracking: tracking, normal: normal))
    }
    func rocksHeading(_ size: CGFloat = 12, normal: Font? = nil, pt: CGFloat) -> some View {
        modifier(RocksHeading(size: size, normal: normal, pt: pt))
    }
}

/// Arcade heading: the bold pixel font (or a heavy monospaced one) plus a hard block shadow. Retro only; in the
/// other themes this changes nothing, so the text keeps whatever font it already had.
struct PixelHeading: ViewModifier {
    var size: CGFloat
    /// The font the text has in the other themes. It is passed here instead of being set on the text itself,
    /// because a `.font` set closer to the text would win over the one set here.
    var normal: Font?
    /// Point size of that normal font, used by the Red Dead font
    var pt: CGFloat?
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        if themes.theme.pixelHeadings {
            content
                .font(PixelFont.available
                      ? Font.custom(PixelFont.bold, size: size)
                      : Font.system(size: size + 3, weight: .heavy, design: .monospaced))
                .shadow(color: Color(hex: themes.palette.glow), radius: 0, x: 2, y: 2)
        } else if themes.theme.westernHeadings {
            // same point size as the text has in the other themes, so nothing gets smaller or bigger
            content
                .font(WesternFont.available ? Font.custom(WesternFont.name, size: (pt ?? size) * WesternFont.scale)
                                            : (normal ?? Font.system(size: pt ?? size, weight: .heavy)))
                .tracking(0.6)
        } else if let normal {
            content.font(normal)
        } else {
            content
        }
    }
}
extension View {
    func pixelHeading(_ size: CGFloat = 12, normal: Font? = nil, pt: CGFloat? = nil) -> some View {
        modifier(PixelHeading(size: size, normal: normal, pt: pt))
    }
}

/// A soft glow in the theme's accent colour behind text or an icon. Only the Terminal theme has it; in the
/// others this changes nothing. Used on prominent texts only (a glow on a whole screen would slow scrolling).
struct TextGlow: ViewModifier {
    var radius: CGFloat
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        let on = themes.theme.glowsText
        return content
            .shadow(color: on ? Color(hex: themes.palette.accent).opacity(0.55) : Color.clear, radius: on ? radius : 0)
    }
}
extension View {
    func textGlow(radius: CGFloat = 5) -> some View { modifier(TextGlow(radius: radius)) }
}

/// Faint CRT scanlines (a dark line every 3 points) and darker screen corners over the whole app.
/// Touches pass through it; it is hidden when Reduce Transparency is on.
struct ScanlineOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduce

    var body: some View {
        if !reduce {
            ZStack {
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(Color.black.opacity(0.16)))
                        y += 3
                    }
                }
                RadialGradient(colors: [Color.clear, Color.black.opacity(0.35)],
                               center: .center, startRadius: 160, endRadius: 560)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A band whose bottom edge is ragged like torn paper (fixed pattern, so it never changes between redraws)
struct TornBand: Shape {
    func path(in rect: CGRect) -> Path {
        var seed: UInt64 = 0xC0FFEE
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 40) / CGFloat(1 << 24)
        }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        var x = rect.maxX
        p.addLine(to: CGPoint(x: x, y: rect.minY + rect.height * 0.6))
        while x > rect.minX {
            x = max(rect.minX, x - (3 + next() * 7))
            p.addLine(to: CGPoint(x: x, y: rect.minY + rect.height * (0.35 + next() * 0.65)))
        }
        p.closeSubpath()
        return p
    }
}

/// A five-pointed star
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let rr = i % 2 == 0 ? r : r * 0.42
            let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// Red Dead: faded red grunge stars over the page (like the website's footer), a dark vignette and a fixed
/// print-grain speckle. Touches pass through.
struct AgedOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduce

    var body: some View {
        if !reduce {
            ZStack {
                Canvas { ctx, size in
                    var seed: UInt64 = 0x9E3779B97F4A7C15
                    func next() -> CGFloat {   // fixed pseudo-random sequence, so the grain doesn't change
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        return CGFloat(seed >> 40) / CGFloat(1 << 24)
                    }
                    // big faded stars, each worn away by dark speckles
                    for i in 0..<9 {
                        let d = 70 + next() * 110
                        let c = CGPoint(x: next() * size.width, y: next() * size.height)
                        var star = StarShape().path(in: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))
                        star = star.applying(CGAffineTransform(rotationAngle: next() * .pi / 2)
                            .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
                        ctx.fill(star, with: .color(Color(hex: 0xD42B1F).opacity(0.07 + Double(i % 3) * 0.015)))
                        for _ in 0..<26 {
                            let r = 1 + next() * 3.5
                            let dot = CGRect(x: c.x + (next() - 0.5) * d, y: c.y + (next() - 0.5) * d, width: r, height: r)
                            ctx.fill(Path(ellipseIn: dot), with: .color(Color.black.opacity(0.55)))
                        }
                    }
                    for _ in 0..<500 {
                        let r = next() * 1.4 + 0.4
                        let rect = CGRect(x: next() * size.width, y: next() * size.height, width: r, height: r)
                        ctx.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0xFFFFFF).opacity(0.03 + Double(next()) * 0.04)))
                    }
                }
                RadialGradient(colors: [Color.clear, Color.black.opacity(0.6)],
                               center: .center, startRadius: 180, endRadius: 600)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Monospaced font for a whole screen tree (iOS 16.1 and later; older versions keep the normal font)
struct ThemeFont: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if #available(iOS 16.1, *) {
            content.fontDesign(mono ? Font.Design.monospaced : nil)
        } else {
            content
        }
    }
}

// MARK: - Screen

struct ThemesView: View {
    @ObservedObject private var store = ThemeStore.shared
    @AppStorage(AppIcon.followsThemeKey) private var iconFollowsTheme = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Change app icon based on theme (above the theme list)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Change app icon based on theme")
                            .foregroundColor(Theme.txt).fontWeight(.semibold).textGlow(radius: 3)
                        Text("The home-screen icon switches to match the theme you pick. iOS shows a short notice each time it changes.")
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $iconFollowsTheme)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glowCard()
                .onChange(of: iconFollowsTheme) { on in
                    if on { AppIcon.apply(for: store.theme) }   // switched on: match the current theme right away
                }

                Text("Choose how the app looks. The change applies everywhere straight away.")
                    .font(Theme.font(.footnote))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(AppTheme.allCases) { t in
                    Button { store.select(t) } label: {
                        ThemeCard(theme: t, selected: store.theme == t)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Themes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeCard: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemePreview(theme: theme)
                .frame(height: 120)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name).foregroundColor(Theme.txt).fontWeight(.semibold).textGlow(radius: 3).pixelHeading(12, pt: 17)
                    Text(theme.detail).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.font(.title3))
                    .foregroundColor(selected ? Theme.accent : Theme.muted.opacity(0.6))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius(14), style: .continuous)
                .stroke(Theme.accent, lineWidth: selected ? 2 : 0)
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: selected)
    }
}

/// A small picture of the app in a theme, drawn from that theme's own palette (not the current one)
private struct ThemePreview: View {
    let theme: AppTheme
    private var p: Palette { theme.palette }
    private var pixel: Bool { p.card == .pixel }
    /// Text in the preview, in the previewed theme's own font (not the current theme's)
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch theme {
        case .retro where PixelFont.available:
            return .custom(PixelFont.bold, size: 8)                 // 8 pt letters = 1 pt pixels
        case .redDead where WesternFont.available:
            return .custom(WesternFont.name, size: size * 1.3)
        default:
            return .system(size: size, weight: weight, design: theme.mono ? .monospaced : .default)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // title bar
            HStack {
                if let t = theme.previewTitle {
                    Text(t).textCase(theme.westernHeadings ? .uppercase : nil).font(mono(10, .bold))
                        .foregroundColor(Color(hex: p.accent))
                } else {
                    Capsule().fill(Color(hex: p.txt)).frame(width: 46, height: 6)
                }
                Spacer()
                Circle().fill(Color(hex: p.accent)).frame(width: 8, height: 8)
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(Color(hex: p.titleBar))

            // two cards
            HStack(spacing: 8) {
                card
                card
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(hex: p.bg))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(hex: p.line), lineWidth: 1))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let l = theme.previewLines {
                Text(l.0).font(mono(9, .bold)).foregroundColor(Color(hex: p.txt))
                Text(l.1).font(mono(8)).foregroundColor(Color(hex: p.muted))
            } else {
                Capsule().fill(Color(hex: p.txt)).frame(width: 52, height: 6)
                Capsule().fill(Color(hex: p.muted)).frame(width: 36, height: 5)
            }
            Spacer(minLength: 0)
            Text("Open")
                .font(mono(9, .bold))
                .foregroundColor(Color(hex: p.onAccent))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(hex: p.accent))
                .clipShape(Capsule())
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 70)
        .background(Color(hex: p.surface))
        .clipShape(RoundedRectangle(cornerRadius: pixel ? 2 : 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: pixel ? 2 : 8, style: .continuous)
            .stroke(Color(hex: p.line), lineWidth: pixel ? 2 : 1))
        .shadow(color: p.card == .terminal ? Color(hex: p.glow).opacity(0.9) : .clear, radius: 6)
        .shadow(color: pixel ? Color(hex: p.glow) : .clear, radius: 0, x: 2, y: 2)
    }
}
