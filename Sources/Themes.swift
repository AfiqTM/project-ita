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
    case amoledDark, light, programmer

    var id: String { rawValue }

    var name: String {
        switch self {
        case .amoledDark: return "AMOLED Dark"
        case .light: return "Light"
        case .programmer: return "Programmer"
        }
    }

    var detail: String {
        switch self {
        case .amoledDark: return "True black with the tan accent. Easy on the eyes at night."
        case .light: return "Warm off-white with a deeper tan accent. Easier to read in bright light."
        case .programmer: return "Terminal look: near-black, neon green, a monospaced font and a green glow."
        }
    }

    /// Light themes use the light look for system parts (keyboard, pickers, status bar); the others use dark
    var scheme: ColorScheme { self == .light ? .light : .dark }

    /// Monospaced font everywhere
    var mono: Bool { self == .programmer }

    var palette: Palette {
        switch self {
        case .amoledDark: return .amoledDark
        case .light: return .light
        case .programmer: return .programmer
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
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .amoledDark
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
                    Text(theme.name).foregroundColor(Theme.txt).fontWeight(.semibold)
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
        .system(size: size, weight: weight, design: theme.mono ? .monospaced : .default)
    }

    var body: some View {
        VStack(spacing: 8) {
            // title bar
            HStack {
                if theme.mono {
                    Text("> italeem_").font(mono(9, .bold)).foregroundColor(Color(hex: p.accent))
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
            if theme.mono {
                Text("$ cs101").font(mono(9, .bold)).foregroundColor(Color(hex: p.txt))
                Text("> 85% ok").font(mono(8)).foregroundColor(Color(hex: p.muted))
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color(hex: p.line), lineWidth: 1))
        .shadow(color: p.card == .terminal ? Color(hex: p.glow).opacity(0.9) : .clear, radius: 6)
    }
}
