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

    /// Themes with their own title font (Red Dead: Chinese Rocks) and body font (Zilla Slab).
    /// The fonts themselves come from `Face`.
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
            return [(0x030303, 0x1A0605), (0x050303, 0x220706), (0x030303, 0x140404),
                    (0x060303, 0x260807), (0x040404, 0x1E0605), (0x030202, 0x160505)]
        }
    }

    /// Photo covers: dimmed on the dark themes so they sit in the page, left as they are on the light one
    var coverBrightness: Double {
        switch self {
        case .dark: return -0.2
        case .light: return 0
        case .terminal: return -0.25
        case .retro: return -0.15
        case .redDead: return -0.4
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
/// (Assets.xcassets/AppIcon-Light, AppIcon-Terminal, AppIcon-Retro, AppIcon-RedDead) and listed in project.yml under
/// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
/// iOS shows its own "You have changed the icon" notice every time the icon changes; apps can't hide it.
/// The icon only follows the theme while the switch on the Themes screen is on.
enum AppIcon {
    /// "Change app icon based on theme" switch at the top of the Themes screen (on by default)
    static let followsThemeKey = "app.iconFollowsTheme"
    static var followsTheme: Bool {
        UserDefaults.standard.object(forKey: followsThemeKey) as? Bool ?? true
    }

    /// Each theme has its own icon. nil = the main icon (AppIcon), whose default image is the dark icon,
    /// so Dark never depends on an alternate-icon lookup (the only one that showed the blank placeholder).
    static func name(for theme: AppTheme) -> String? {
        switch theme {
        case .dark: return nil
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
        app.setAlternateIconName(wanted) { error in
            // a failed switch must not leave the placeholder: fall back to the primary icon
            guard error != nil, app.alternateIconName != nil else { return }
            DispatchQueue.main.async { app.setAlternateIconName(nil) { _ in } }
        }
    }

    /// Re-checks the icon against the theme when the app comes to the front, so a half-switched or
    /// missing icon repairs itself.
    @MainActor
    static func syncWithTheme() {
        guard followsTheme else { return }
        apply(for: ThemeStore.shared.theme)
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

/// Body font of the Red Dead Redemption 2 theme: Zilla Slab (Fonts/ZillaSlab-Medium.ttf and -Bold.ttf, SIL OFL), a
/// slab serif that is easy to read in long text and still looks Western. Titles and sub-titles use RocksFont instead.
enum WesternFont {
    static let name = "ZillaSlab-Medium"
    static let bold = "ZillaSlab-Bold"
    /// Zilla Slab's letters are a little smaller than the system font's at the same size
    static let scale: CGFloat = 1.08

    static func register() {
        for file in [name, bold] {
            guard let url = Bundle.main.url(forResource: file, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static var available: Bool { UIFont(name: name, size: 12) != nil && UIFont(name: bold, size: 12) != nil }
}

/// Chinese Rocks Rg (Fonts/ChineseRocksCaps-Regular.ttf, built by Tools/make_rocks_caps.py): all capitals, the
/// game's lettering, letters untouched. Only "&" "(" ")" "{" "}" are redrawn (from Staatliches), the same fix as in
/// WesternFont, because the original draws them like a plus and square brackets. The Red Dead theme uses it for
/// titles, sub-titles, tab strips, the tab bar, nav bar titles and buttons; running text uses WesternFont (Zilla Slab).
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

/// The title face and the text face of the themes with `westernHeadings`: the sizes of the nav bar, tab bar and
/// bar buttons are kept together here.
struct FaceSpec {
    let name: String
    let bold: String
    let scale: CGFloat
    let tracking: CGFloat
    var navTitle: CGFloat = 28, navLarge: CGFloat = 46, tab: CGFloat = 15, bar: CGFloat = 17
    var navKern: CGFloat = 1.2, tabKern: CGFloat = 0.5

    var available: Bool { UIFont(name: name, size: 12) != nil && UIFont(name: bold, size: 12) != nil }
    /// UIKit font for the nav bar / tab bar (size is the final point size, `scale` is not applied)
    func ui(_ size: CGFloat) -> UIFont? { UIFont(name: name, size: size) }

    static let rocks = FaceSpec(name: RocksFont.name, bold: RocksFont.name, scale: RocksFont.scale, tracking: RocksFont.tracking)
    static let zilla = FaceSpec(name: WesternFont.name, bold: WesternFont.bold, scale: WesternFont.scale, tracking: 0)
}

enum Face {
    static var display: FaceSpec { .rocks }
    static var body: FaceSpec { .zilla }
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
        if themes.theme.westernHeadings && Face.display.available {
            content
                .font(.custom(Face.display.name, size: pt * Face.display.scale))
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
        if themes.theme.westernHeadings && Face.display.available {
            content
                .font(.custom(Face.display.name, size: pt * Face.display.scale))
                .tracking(Face.display.tracking)
        } else {
            content.pixelHeading(size, normal: normal, pt: pt)
        }
    }
}
extension View {
    func rocks(_ pt: CGFloat, tracking: CGFloat? = nil, normal: Font? = nil) -> some View {
        modifier(RocksText(pt: pt, tracking: tracking ?? Face.display.tracking, normal: normal))
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
                      ? Font.custom(PixelFont.bold, size: size * 1.2)
                      : Font.system(size: size + 3, weight: .heavy, design: .monospaced))
                .shadow(color: Color(hex: themes.palette.glow), radius: 0, x: 2, y: 2)
        } else if themes.theme.westernHeadings {
            // Chinese Rocks at the size the text has in the other themes
            content
                .font(Face.display.available ? Font.custom(Face.display.name, size: (pt ?? size) * Face.display.scale)
                                             : (normal ?? Font.system(size: pt ?? size, weight: .heavy)))
                .tracking(Face.display.tracking)
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
                        ctx.fill(star, with: .color(Color(hex: 0xC8281C).opacity(0.04 + Double(i % 3) * 0.01)))
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
                RadialGradient(colors: [Color.clear, Color.black.opacity(0.85)],
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

    /// The theme's name in that theme's own main font (not the font of the theme that is active right now).
    /// Sizes are picked so the capital letters are the same height (about 14 pt) in every theme:
    /// system 20 pt = 14.1, pixel 16 pt = 14.0 (2 pt pixels), Chinese Rocks 17 x scale = 13.9.
    private var nameFont: Font {
        switch theme {
        case .terminal: return .system(size: 20, weight: .semibold, design: .monospaced)
        case .retro: return PixelFont.available ? .custom(PixelFont.bold, size: 16)
                                                 : .system(size: 20, weight: .heavy, design: .monospaced)
        case .redDead: return RocksFont.available ? .custom(RocksFont.name, size: 17 * RocksFont.scale)
                                                  : .system(size: 20, weight: .semibold)
        default: return .system(size: 20, weight: .semibold)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemePreview(theme: theme)
                .frame(height: 120)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name).font(nameFont).foregroundColor(Theme.txt)
                        // the active theme may force a monospaced design on everything below it: reset it here
                        .modifier(ThemeFont(mono: theme == .terminal))
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
        case .redDead where RocksFont.available:
            return .custom(RocksFont.name, size: size * 0.95 * RocksFont.scale)   // same capital height as the system font
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
        .modifier(ThemeFont(mono: theme.mono))     // overrides the active theme's forced monospaced design
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
        .clipShape(RoundedRectangle(cornerRadius: pixel ? 6 : 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: pixel ? 6 : 8, style: .continuous)
            .stroke(Color(hex: p.line), lineWidth: pixel ? 2 : 1))
        .shadow(color: p.card == .terminal ? Color(hex: p.glow).opacity(0.9) : .clear, radius: 6)
        .shadow(color: pixel ? Color(hex: p.glow) : .clear, radius: 0, x: 2, y: 2)
    }
}


// MARK: - Greeting intro
//
// "Hello, <name>" on the My courses tab plays an intro once per launch (and once more after switching to the theme),
// and it always leaves the same way it came:
//  - Red Dead Redemption 2: a muzzle flash at the left edge, a bullet with a long trace crosses the whole row
//    (uncovering the text behind it) and flies off the right edge; the trace then fades out.
//  - Retro: Pac-Man chases a ghost across the row eating the dots under the text, which appears behind him; he
//    eats the power pellet at the end of the text, the ghost turns blue, and both run off the right edge.
//  - Terminal: the text is a grid of random symbols that lock into the letters one by one, left to right, behind
//    a block cursor that blinks a few times and fades out once the last letter has locked.
// Skipped when Reduce Motion is on.

/// Which themes already played their greeting in this launch (so changing tabs doesn't replay it)
final class GreetingPlayed {
    static var themes = Set<String>()
}

/// The scramble-to-text effect of the Terminal theme
enum ScrambleText {
    static let pool = Array("@#$8*!%&?<>/\\|[]{}=+~^0123456789ABCDEF")
    /// Second at which the i-th letter (counting across both words) locks in
    static func lockTime(_ i: Int) -> Double { 0.45 + Double(i) * 0.085 + Double((i * 37) % 11) * 0.012 }

    static func make(_ text: String, offset: Int, elapsed: Double, dim: Color) -> AttributedString {
        var out = AttributedString()
        let step = Int(max(elapsed, 0) * 22)                       // symbols change about 22 times a second
        for (k, ch) in text.enumerated() {
            let i = offset + k
            if ch == " " || elapsed >= lockTime(i) {
                out += AttributedString(String(ch))
            } else {
                var g = AttributedString(String(pool[(i * 7919 + step * 104729 + (step % 3) * 31) % pool.count]))
                g.foregroundColor = dim
                out += g
            }
        }
        return out
    }
}

struct GreetingBar<Trailing: View>: View {
    let hello: String
    let name: String
    private let trailing: Trailing
    @ObservedObject private var themes = ThemeStore.shared
    @State private var playing: Bool
    @State private var started = false
    @State private var t0 = Date()
    @State private var progress: CGFloat = 0      // Red Dead / Retro: 0 = before the start, 1 = the effect has left the row
    @State private var flash: Double = 0          // muzzle flash
    @State private var fade: Double = 0           // the effect's trace fading out
    @State private var shake: CGFloat = 0         // recoil of the text when the shot is fired
    @State private var textSize: CGSize = .zero
    @State private var rowSize: CGSize = .zero
    @State private var trailingWidth: CGFloat = 0

    init(hello: String, name: String, @ViewBuilder trailing: () -> Trailing) {
        self.hello = hello
        self.name = name
        self.trailing = trailing()
        let t = ThemeStore.shared.theme
        let will = (t == .redDead || t == .retro || t == .terminal) && !UIAccessibility.isReduceMotionEnabled
            && !GreetingPlayed.themes.contains(t.rawValue)
        _playing = State(initialValue: will)
    }

    private var letters: Int { hello.count + name.count }

    /// The strip the effects run in: the row without the trailing button (chat icon), so they end before it
    private var lane: CGSize {
        CGSize(width: max(rowSize.width - trailingWidth - 12, 0), height: rowSize.height)
    }

    /// How much of the text is uncovered, in points from the left (Red Dead and Retro)
    private var revealWidth: CGFloat {
        if themes.theme == .redDead { return min(max(0, -14 + progress * (lane.width + 90) - 6), textSize.width) }
        return min(max(0, -26 + progress * (lane.width + 70) + 13), textSize.width)       // Pac-Man's centre
    }

    var body: some View {
        HStack {
            textRow
                .mask(alignment: .leading) {
                    if playing && themes.theme != .terminal { Rectangle().frame(width: revealWidth) } else { Rectangle() }
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { textSize = g.size; begin() }
                        .onChange(of: g.size) { textSize = $0 }
                })
                .offset(x: shake)
            Spacer()
            trailing
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { trailingWidth = g.size.width }
                        .onChange(of: g.size.width) { trailingWidth = $0 }
                })
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { rowSize = g.size }
                .onChange(of: g.size) { rowSize = $0 }
        })
        .overlay(alignment: .leading) {
            if playing { effect.mask(alignment: .leading) { laneMask } }
        }
    }

    @ViewBuilder private var textRow: some View {
        if playing && themes.theme == .terminal {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                let e = ctx.date.timeIntervalSince(t0)
                let dim = Color(hex: themes.palette.accent).opacity(0.55)
                greeting(ScrambleText.make(hello, offset: 0, elapsed: e, dim: dim),
                         ScrambleText.make(name, offset: hello.count, elapsed: e, dim: dim))
            }
        } else {
            greeting(AttributedString(hello), AttributedString(name))
        }
    }

    private func greeting(_ a: AttributedString, _ b: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(a).foregroundColor(Theme.muted)
            Text(b).foregroundColor(Theme.accent).fontWeight(.semibold)
        }
        .textGlow()
        .rocksHeading(16, normal: .title3, pt: 20)
    }

    /// Everything the effects draw fades out over the last 40 points of the lane, so they dissolve before the chat icon
    /// instead of running into it (the muzzle flash, left of the lane, stays visible)
    private var laneMask: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.black).frame(width: 60).offset(x: -60)
            Rectangle()
                .fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: max(0, (lane.width - 40) / max(lane.width, 1))),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: lane.width)
        }
    }

    @ViewBuilder private var effect: some View {
        switch themes.theme {
        case .redDead:
            GunshotEffect(progress: progress, flash: flash, fade: fade, size: lane)
        case .retro:
            PacmanEffect(progress: progress, size: lane, textWidth: textSize.width)
        default:
            TerminalCursor(start: t0, letters: letters, textSize: textSize)
        }
    }

    private func begin() {
        guard playing, !started else { return }
        started = true
        let theme = themes.theme
        GreetingPlayed.themes.insert(theme.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch theme {
            case .redDead:
                // shot: flash and a little recoil, then the bullet crosses the row and leaves the screen
                withAnimation(.easeOut(duration: 0.08)) { flash = 1; shake = -4 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { shake = 0 }
                    withAnimation(.easeIn(duration: 0.35)) { flash = 0 }
                }
                withAnimation(.timingCurve(0.25, 0.1, 0.35, 1, duration: 1.7)) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { withAnimation(.easeOut(duration: 0.6)) { fade = 1 } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { playing = false }
            case .retro:
                withAnimation(.linear(duration: 2.6)) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { playing = false }
            default:
                t0 = Date()
                let last = ScrambleText.lockTime(letters - 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + last + 1.4) { playing = false }
            }
        }
    }
}

/// A spiky flash
private struct StarBurst: Shape {
    var points = 9
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        for i in 0..<(points * 2) {
            let a = CGFloat(i) * .pi / CGFloat(points)
            let rad = (i % 2 == 0 ? 1.0 : 0.42) * r.width / 2
            let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// Red Dead Redemption 2: muzzle flash at the left edge, a bullet with a long bright trace crossing the row
private struct GunshotEffect: View {
    let progress: CGFloat
    let flash: Double
    let fade: Double
    let size: CGSize

    var body: some View {
        let x = -14 + progress * (size.width + 90)               // the bullet's centre; it ends beyond the right edge
        let tail = min(max(x + 14, 0), 260)
        ZStack(alignment: .leading) {
            Capsule()                                             // trace left behind the bullet
                .fill(LinearGradient(colors: [Color.clear, Color(hex: 0xFFE9B0).opacity(0.7)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: tail, height: 3)
                .offset(x: x - tail)
            Capsule()                                             // a fainter, wider smoke band under the trace
                .fill(LinearGradient(colors: [Color.clear, Color(hex: 0xC8281C).opacity(0.25)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: tail * 0.9, height: 9)
                .blur(radius: 4)
                .offset(x: x - tail * 0.9)
            Capsule()                                             // the bullet
                .fill(LinearGradient(colors: [Color(hex: 0xFFF3C9), Color(hex: 0xC98A2B)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 6)
                .offset(x: x - 9)
            StarBurst(points: 9)                                  // muzzle flash
                .fill(RadialGradient(colors: [Color.white, Color(hex: 0xFFB02E), Color(hex: 0xC8281C).opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 30))
                .frame(width: 60, height: 60)
                .scaleEffect(0.35 + flash * 0.85)
                .opacity(flash)
                .offset(x: -30)
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .opacity(1 - fade)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Pac-Man with his mouth opened by `mouth` degrees on each side
private struct PacShape: Shape {
    var mouth: Double
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let rad = r.width / 2
        var p = Path()
        p.move(to: c)
        var a = mouth
        while a <= 360 - mouth {
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a * .pi / 180)) * rad, y: c.y + CGFloat(sin(a * .pi / 180)) * rad))
            a += 6
        }
        p.addLine(to: CGPoint(x: c.x + CGFloat(cos((360 - mouth) * .pi / 180)) * rad,
                              y: c.y + CGFloat(sin((360 - mouth) * .pi / 180)) * rad))
        p.closeSubpath()
        return p
    }
}

/// A ghost: round head, three feet at the bottom
private struct GhostShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: w / 2))
        var a = 180.0
        while a <= 360 {
            p.addLine(to: CGPoint(x: w / 2 + CGFloat(cos(a * .pi / 180)) * w / 2,
                                  y: w / 2 + CGFloat(sin(a * .pi / 180)) * w / 2))
            a += 10
        }
        p.addLine(to: CGPoint(x: w, y: h))
        let f = w / 3
        p.addLine(to: CGPoint(x: w - f * 0.5, y: h * 0.8))
        p.addLine(to: CGPoint(x: w - f, y: h))
        p.addLine(to: CGPoint(x: w - f * 1.5, y: h * 0.8))
        p.addLine(to: CGPoint(x: w - f * 2, y: h))
        p.addLine(to: CGPoint(x: w - f * 2.5, y: h * 0.8))
        p.closeSubpath()
        return p
    }
}

/// Retro: Pac-Man crosses the whole row eating the dots under the text and a power pellet at its end; the ghost
/// he was chasing turns blue, and both run off the right edge of the screen
private struct PacmanEffect: View {
    let progress: CGFloat
    let size: CGSize
    let textWidth: CGFloat

    var body: some View {
        let d: CGFloat = 26
        let x = -d + progress * (size.width + 70)                // Pac-Man's left edge (ends beyond the right edge)
        let eaten = x + d * 0.5
        let scared = eaten > textWidth                           // after the power pellet
        let gx = scared ? x + d * 1.6 : x + d * 1.9              // the ghost runs ahead of him once it is blue
        let count = max(Int(textWidth / 16), 1)
        ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { i in
                let dx = CGFloat(i) * 16 + 8
                Rectangle()
                    .fill(Color(hex: 0xFFE628))
                    .frame(width: 4, height: 4)
                    .position(x: dx, y: size.height / 2)
                    .opacity(dx > eaten ? 1 : 0)
            }
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let mouth = 4 + 36 * abs(sin(t * 11))
                ZStack(alignment: .topLeading) {
                    Circle()                                      // power pellet at the end of the text, blinking
                        .fill(Color(hex: 0xFFE628))
                        .frame(width: 10, height: 10)
                        .position(x: textWidth + 14, y: size.height / 2)
                        .opacity(eaten > textWidth + 14 ? 0 : (sin(t * 9) > 0 ? 1 : 0.25))
                    PacShape(mouth: mouth)
                        .fill(Color(hex: 0xFFE628))
                        .frame(width: d, height: d)
                        .offset(x: x, y: (size.height - d) / 2)
                    GhostShape()
                        .fill(scared ? Color(hex: 0x2A4BFF) : Color(hex: 0xFF4A3F))
                        .frame(width: d * 0.92, height: d * 0.92)
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                ForEach(0..<2, id: \.self) { _ in
                                    Circle().fill(Color.white).frame(width: 7, height: 8)
                                        .overlay(Circle().fill(scared ? Color.white : Color(hex: 0x2A4BFF))
                                            .frame(width: 3.5, height: 3.5).offset(x: scared ? 0 : 1.5))
                                }
                            }
                            .padding(.leading, 4).padding(.top, 7)
                        }
                        .offset(x: gx, y: (size.height - d * 0.92) / 2 + (sin(t * 14) > 0 ? 0 : 1))
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Terminal: a block cursor that moves along with the locking letters, then blinks a few times and fades out
private struct TerminalCursor: View {
    let start: Date
    let letters: Int
    let textSize: CGSize
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let e = ctx.date.timeIntervalSince(start)
            let locked = (0..<letters).filter { ScrambleText.lockTime($0) <= e }.count
            let last = ScrambleText.lockTime(letters - 1)
            let after = e - last
            let alpha: Double = after < 0 ? 1
                : (Int(after / 0.25) % 2 == 0 ? 1 : 0.0) * min(1, max(0, (1.3 - after) / 0.3))
            Rectangle()
                .fill(Color(hex: themes.palette.accent))
                .frame(width: 9, height: max(textSize.height * 0.8, 14))
                .shadow(color: Color(hex: themes.palette.accent).opacity(0.8), radius: 6)
                .opacity(alpha)
                .offset(x: textSize.width * CGFloat(locked) / CGFloat(max(letters, 1)) + 2)
                .frame(width: textSize.width + 20, height: textSize.height, alignment: .leading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
