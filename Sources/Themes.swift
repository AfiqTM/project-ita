import SwiftUI
import UIKit

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
    case dark, light, terminal, retro

    var id: String { rawValue }

    var name: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .terminal: return "Terminal"
        case .retro: return "Retro"
        }
    }

    var detail: String {
        switch self {
        case .dark: return "True black with the tan accent. Easy on the eyes at night."
        case .light: return "Warm off-white with a deeper tan accent. Easier to read in bright light."
        case .terminal: return "Terminal look: near-black, neon green, a monospaced font and a green glow."
        case .retro: return "Pixel-art look: pure black, bright yellow, flat dark tiles, a pixel font and yellow-toned covers."
        }
    }

    /// Light themes use the light look for system parts (keyboard, pickers, status bar); the others use dark
    var scheme: ColorScheme { self == .light ? .light : .dark }

    /// Which font look the whole app gets
    enum FontStyle { case standard, mono, arcade }

    var fontStyle: FontStyle {
        switch self {
        case .terminal: return .mono
        case .retro: return .arcade
        default: return .standard
        }
    }

    /// Monospaced font everywhere (Terminal)
    var mono: Bool { fontStyle == .mono }

    /// Wide, chunky type everywhere (Retro)
    var arcade: Bool { fontStyle == .arcade }

    var palette: Palette {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .terminal: return .terminal
        case .retro: return .retro
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
            return [(0x0D0C00, 0x3D3800), (0x0A0A06, 0x2B2A12), (0x120F00, 0x4A4200),
                    (0x080800, 0x2E2C00), (0x0F0E02, 0x524A08), (0x0B0B0B, 0x34331C)]
        }
    }

    /// Photo covers: dimmed on the dark themes so they sit in the page, left as they are on the light one
    var coverBrightness: Double {
        switch self {
        case .dark: return -0.2
        case .light: return 0
        case .terminal: return -0.25
        case .retro: return -0.1
        }
    }
    var coverSaturation: Double {
        switch self {
        case .terminal: return 0.6
        case .retro: return 0.5
        default: return 1
        }
    }
    /// Terminal: photos get a green monitor tint, Retro: a yellow one
    var coverTint: UInt32? {
        switch self {
        case .terminal: return 0x1FBF55
        case .retro: return 0xF4E52C   // yellow-toned artwork, like the album art in the reference
        default: return nil
        }
    }
    /// The star on a cover sits on a dark circle, so it needs a bright accent in every theme
    var onCoverAccent: UInt32 {
        switch self {
        case .terminal: return Palette.terminal.accent
        case .retro: return Palette.retro.accent
        default: return Palette.dark.accent
        }
    }
}

/// The chosen theme, remembered across launches.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "app.theme"

    @Published private(set) var theme: AppTheme

    var palette: Palette { theme.palette }

    private init() {
        theme = Self.stored()
    }

    /// Reads the saved theme. The old names ("amoledDark", "programmer") are mapped to the renamed themes,
    /// so nobody who picked one loses their choice.
    private static func stored() -> AppTheme {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        switch raw {
        case "amoledDark": return .dark
        case "programmer": return .terminal
        default: return AppTheme(rawValue: raw) ?? .dark
        }
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

/// A soft glow in the theme's accent colour behind text or an icon. Only the Terminal theme has it; in the
/// others this changes nothing. Used on prominent texts only (a glow on a whole screen would slow scrolling).
struct TextGlow: ViewModifier {
    var radius: CGFloat
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        let on = themes.theme.glowsText
        return content.shadow(color: on ? Color(hex: themes.palette.accent).opacity(0.55) : Color.clear,
                              radius: on ? radius : 0)
    }
}
extension View {
    func textGlow(radius: CGFloat = 5) -> some View { modifier(TextGlow(radius: radius)) }
}

/// Faint CRT scanlines (a dark line every 3 points) and darker screen corners over the whole app.
/// Terminal has them stronger, Retro lighter. Touches pass through it; it is hidden when Reduce Transparency is on.
struct ScanlineOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        if !reduce {
            let retro = themes.theme == .retro
            let lineOpacity = retro ? 0.10 : 0.16
            let vignette = retro ? 0.22 : 0.35
            ZStack {
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(Color.black.opacity(lineOpacity)))
                        y += 3
                    }
                }
                RadialGradient(colors: [Color.clear, Color.black.opacity(vignette)],
                               center: .center, startRadius: 160, endRadius: 560)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Font look for a whole screen tree.
/// `mono`: monospaced (Terminal, iOS 16.1+). `arcade`: the bundled pixel font (Retro, see RetroFonts.swift) for
/// every text that doesn't set its own font; texts that do (.font(.caption) and so on) are covered by
/// RetroFontStyles.swift.
struct ThemeFont: ViewModifier {
    let mono: Bool
    var arcade = false

    func body(content: Content) -> some View {
        if arcade {
            content.environment(\.font, RetroFonts.body)
        } else if #available(iOS 16.1, *) {
            content.fontDesign(mono ? Font.Design.monospaced : nil)
        } else {
            content
        }
    }
}

// MARK: - Screen

struct ThemesView: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Choose how the app looks. The change applies everywhere straight away.")
                    .font(.footnote)
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
                    Text(theme.name).foregroundColor(Theme.txt).fontWeight(.semibold).textGlow(radius: 3)
                    Text(theme.detail).font(.caption).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected ? Theme.accent : Theme.muted.opacity(0.6))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if theme.arcade { return RetroFonts.font(size, display: weight == .bold) }
        return .system(size: size, weight: weight, design: theme.mono ? .monospaced : .default)
    }

    private var cardShadow: Color {
        p.card == .terminal ? Color(hex: p.glow).opacity(0.9) : .clear
    }

    var body: some View {
        VStack(spacing: 8) {
            // title bar
            HStack {
                if theme.mono {
                    Text("> italeem_").font(mono(9, .bold)).foregroundColor(Color(hex: p.accent))
                } else if theme.arcade {
                    Text("00:00:32").font(mono(10)).foregroundColor(Color(hex: p.accent))
                } else {
                    SwiftUI.Capsule().fill(Color(hex: p.txt)).frame(width: 46, height: 6)
                }
                Spacer()
                SwiftUI.Circle().fill(Color(hex: p.accent)).frame(width: 8, height: 8)
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(Color(hex: p.titleBar))

            // two cards
            HStack(spacing: 8) {
                card(active: false)
                card(active: theme.arcade)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(hex: p.bg))
        .clipShape(SwiftUI.RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(SwiftUI.RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(hex: p.line), lineWidth: 1))
    }

    /// `active`: the Retro "pressed" tile, solid yellow with dark text (like the play button in the reference)
    private func card(active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if theme.mono {
                Text("$ cs101").font(mono(9, .bold)).foregroundColor(Color(hex: p.txt))
                Text("> 85% ok").font(mono(8)).foregroundColor(Color(hex: p.muted))
            } else if theme.arcade {
                Text("CS 101").font(mono(10, .bold))
                    .foregroundColor(Color(hex: active ? p.onAccent : p.accent))
                Text("85% done").font(mono(9))
                    .foregroundColor(Color(hex: active ? p.onAccent : p.muted))
            } else {
                SwiftUI.Capsule().fill(Color(hex: p.txt)).frame(width: 52, height: 6)
                SwiftUI.Capsule().fill(Color(hex: p.muted)).frame(width: 36, height: 5)
            }
            Spacer(minLength: 0)
            if !theme.arcade {
                Text("Open")
                    .font(mono(9, .bold))
                    .foregroundColor(Color(hex: p.onAccent))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(hex: p.accent))
                    .clipShape(SwiftUI.Capsule())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 70)
        .background(Color(hex: active ? p.accent : p.surface))
        .clipShape(SwiftUI.RoundedRectangle(cornerRadius: theme.arcade ? 12 : 8, style: .continuous))
        .overlay(SwiftUI.RoundedRectangle(cornerRadius: theme.arcade ? 12 : 8, style: .continuous)
            .stroke(Color(hex: p.line), lineWidth: 1))
        .shadow(color: cardShadow, radius: 6)
    }
}
