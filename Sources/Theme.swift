import SwiftUI
import UIKit

// The colours of one theme, as 0xRRGGBB values. The AMOLED one is taken 1:1 from the "iTa'leem AMOLED Dark" userscript.
// Themes.swift lists the themes the user can pick; each one needs a palette here.
struct Palette {
    /// How cards are lifted off the page: a soft glow (dark), a drop shadow + outline (light),
    /// or a glow + outline like a terminal window
    enum Card { case glow, soft, terminal }

    let bg, surface, surface2, titleBar, line, txt, muted, accent, onAccent: UInt32
    let green, red, amber, blue: UInt32     // status colours (present / absent / late / info)
    let glow: UInt32                        // colour of the glow behind cards
    let card: Card

    static let amoledDark = Palette(bg: 0x000000, surface: 0x060606, surface2: 0x0b0b0b, titleBar: 0x0a0a0a,
                                    line: 0x1c1c1c, txt: 0xe6e6e6, muted: 0x9a9a9a, accent: 0xD2B48C,
                                    onAccent: 0x000000,
                                    green: 0x5fbf7f, red: 0xe0605a, amber: 0xe0b050, blue: 0x5a9be0,
                                    glow: 0x1c1c1c, card: .glow)

    // Warm off-white page with white cards. The accent is a deeper tan so it stays readable on light
    // backgrounds (about 5:1 against white), and text on accent buttons is white.
    static let light = Palette(bg: 0xF7F4EF, surface: 0xFFFFFF, surface2: 0xF1EDE6, titleBar: 0xEEE9E0,
                               line: 0xE3DDD2, txt: 0x1F1B16, muted: 0x6B6458, accent: 0x8A6A3B,
                               onAccent: 0xFFFFFF,
                               green: 0x2C8A4B, red: 0xC23B35, amber: 0x9A6A00, blue: 0x2B6CB0,
                               glow: 0x000000, card: .soft)

    // Terminal look: near-black with a green tint, mint text, neon green accent, green glow around cards
    static let programmer = Palette(bg: 0x020805, surface: 0x06120B, surface2: 0x0A1B11, titleBar: 0x08160E,
                                    line: 0x15402A, txt: 0xA9F5BC, muted: 0x5FA777, accent: 0x39FF6E,
                                    onAccent: 0x02140A,
                                    green: 0x39FF6E, red: 0xFF5C5C, amber: 0xFFC83D, blue: 0x4FB3FF,
                                    glow: 0x0C3D20, card: .terminal)
}

// Every colour reads from the palette of the chosen theme (Themes.swift). Screens pick the new colours up
// when the theme is switched because RootView rebuilds its tabs for the new theme (see MainViews.swift).
enum Theme {
    private static var p: Palette { ThemeStore.shared.palette }

    static var bg: Color       { Color(hex: p.bg) }
    static var surface: Color  { Color(hex: p.surface) }
    static var surface2: Color { Color(hex: p.surface2) }
    static var titleBar: Color { Color(hex: p.titleBar) }   // "General" title bar / table headers
    static var line: Color     { Color(hex: p.line) }
    static var txt: Color      { Color(hex: p.txt) }
    static var muted: Color    { Color(hex: p.muted) }
    static var accent: Color   { Color(hex: p.accent) }
    /// Text / icons drawn on top of an accent-coloured background (black on the tan, white on the deeper tan, ...)
    static var onAccent: Color { Color(hex: p.onAccent) }

    // UIKit versions (navigation bar, tab bar, tab badges)
    static var uiBg: UIColor       { UIColor(hex: p.bg) }
    static var uiTxt: UIColor      { UIColor(hex: p.txt) }
    static var uiAccent: UIColor   { UIColor(hex: p.accent) }
    static var uiOnAccent: UIColor { UIColor(hex: p.onAccent) }

    /// Navigation bar, tab bar and tab badges. Bars that already exist keep the old look, so call this
    /// before the screens are rebuilt for a new theme (ThemeStore.select does).
    static func applyAppearance() {
        let mono = ThemeStore.shared.theme.mono

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBg
        nav.shadowColor = .clear
        var title: [NSAttributedString.Key: Any] = [.foregroundColor: uiTxt]
        var large: [NSAttributedString.Key: Any] = [.foregroundColor: uiTxt]
        if mono {
            title[.font] = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
            large[.font] = UIFont.monospacedSystemFont(ofSize: 34, weight: .bold)
        }
        nav.titleTextAttributes = title
        nav.largeTitleTextAttributes = large
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiBg
        tab.shadowColor = .clear
        // Tab badges in the app's accent colour with contrasting text. SwiftUI's .badge ignores
        // UITabBarItem.appearance().badgeColor, so it is set through UITabBarAppearance instead.
        let badgeText: [NSAttributedString.Key: Any] = [.foregroundColor: uiOnAccent]
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            for state in [item.normal, item.selected] {
                state.badgeBackgroundColor = uiAccent
                state.badgeTextAttributes = badgeText
            }
            if mono {
                let f = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
                item.normal.titleTextAttributes = [.font: f, .foregroundColor: UIColor(hex: p.muted)]
                item.selected.titleTextAttributes = [.font: f, .foregroundColor: uiAccent]
            }
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

// Card background. AMOLED: soft glow (the 10/30/64px rgba(28,28,28) shadows from the userscript).
// Light: a gentle drop shadow and a thin outline, since a glow doesn't show on a light page.
// Programmer: a green glow and a thin green outline, like a terminal window.
struct GlowCard: ViewModifier {
    var radius: CGFloat = 14
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        // One fixed structure (only the values change), so switching theme never rebuilds what is inside the card
        let p = themes.theme.palette
        let soft = p.card == .soft
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let g = Color(hex: p.glow)
        return content
            .background(Color(hex: p.surface))
            .clipShape(shape)
            .overlay(shape.stroke(Color(hex: p.line), lineWidth: p.card == .glow ? 0 : 1))
            .shadow(color: soft ? Color.black.opacity(0.06) : g.opacity(0.85), radius: soft ? 6 : 5, y: soft ? 2 : 0)
            .shadow(color: soft ? Color.black.opacity(0.04) : g.opacity(0.5), radius: soft ? 18 : 15, y: soft ? 6 : 0)
            .shadow(color: soft ? Color.clear : g.opacity(0.25), radius: 32)
    }
}
extension View {
    func glowCard(radius: CGFloat = 14) -> some View { modifier(GlowCard(radius: radius)) }
}

extension String {
    private func decodeOnce() -> String {
        guard contains("&") else { return self }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "copy": "\u{A9}"]
        guard let re = try? NSRegularExpression(pattern: "&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);") else { return self }
        let ns = self as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let ent = ns.substring(with: m.range(at: 1))
            var rep: String? = nil
            if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
                if let n = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(n) { rep = String(Character(u)) }
            } else if ent.hasPrefix("#") {
                if let n = UInt32(ent.dropFirst()), let u = Unicode.Scalar(n) { rep = String(Character(u)) }
            } else { rep = named[ent] }
            result += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// "Foo &amp; Bar" -> "Foo & Bar" (Moodle HTML-encodes names; runs twice for double-encoded text)
    var decodedEntities: String {
        var s = self
        for _ in 0..<2 { let n = s.decodeOnce(); if n == s { break }; s = n }
        return s
    }

    var plainText: String {
        var s = replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n",
                                     options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.decodedEntities.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func fmt(_ ts: Int?, time: Bool = true) -> String {
    guard let ts, ts > 0 else { return "-" }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = time ? .short : .none
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

// Dark CSS injected into every page shown in the in-app web view
// (trimmed port of the userscript's stylesheet).
// Notes: text colour is only forced on the page/body and headings and is otherwise inherited, so coloured status
// text and text inside buttons keep their own colour; the <style> is moved to the very end of the document once
// the page's own stylesheets have loaded, so it wins over Moodle's !important rules.
enum WebTheme {
    static let js = #"""
    (function(){
      if (window.__amoledTheme) return;
      window.__amoledTheme = true;
      var s=document.createElement('style');
      s.id='amoled-theme';
      s.textContent=`
      :root{--amoled-bg:#000;--amoled-surface:#060606;--amoled-surface-2:#0b0b0b;--amoled-border:#1c1c1c;
        --amoled-text:#e6e6e6;--amoled-muted:#9a9a9a;--amoled-accent:#D2B48C;
        --bs-body-bg:#000;--bs-body-color:#e6e6e6;--bs-border-color:#1c1c1c;--bs-link-color:#D2B48C;
        --bs-primary:#D2B48C;--bs-primary-rgb:210,180,140;--bs-secondary-color:#9a9a9a;--bs-emphasis-color:#e6e6e6;
        color-scheme:dark;accent-color:#D2B48C}
      html,body,#page,#page-wrapper,#page-content,#region-main,#region-main-box,#topofscroll,.main-inner,.drawers{background:#000!important}
      body,#region-main{color:#e6e6e6!important}
      .navbar,nav.navbar,.primary-navigation,.secondary-navigation,.drawer,.drawer-left,.drawer-right,.moremenu{background:#000!important;border-color:transparent!important;box-shadow:none!important}
      .card,.block,.box,.well,.list-group-item,.popover,.modal-content,.dropdown-menu,.generalbox,.activity-item,.course-content .section,.que .content,.que .info,.bg-white,.bg-light,.table-light{background:#060606!important;border-color:#1c1c1c!important;box-shadow:none!important}
      .card,.block,.well,.list-group-item,.popover,.modal-content,.dropdown-menu,.generalbox,.activity-item{color:#e6e6e6}
      h1,h2,h3,h4,h5,h6,legend,.text-dark,.text-body,.card-title,.breadcrumb-item{color:#e6e6e6!important}
      .text-muted,.text-secondary,small,.small,.dimmed_text,.text-black-50{color:#9a9a9a!important}
      a:not(.btn):not(.nav-link):not(.dropdown-item):not(.page-link):not(.badge){color:#D2B48C}
      input,select,textarea,.form-control,.form-select,.custom-select,.input-group-text{background-color:#060606!important;color:#e6e6e6!important;border-color:#1c1c1c!important}
      .form-check-input{background-color:#060606!important;border-color:#3a3a3a!important}
      .form-check-input:checked{background-color:#D2B48C!important;border-color:#D2B48C!important}
      .btn-primary,.btn-primary:hover,.btn-primary:focus,.btn-primary:active,.bg-primary{background:#D2B48C!important;border-color:#D2B48C!important;color:#000!important}
      .btn-primary *,.bg-primary *,.progress-bar *{color:#000!important}
      .btn-outline-primary,.btn-outline-primary:hover{background:transparent!important;border-color:#D2B48C!important;color:#D2B48C!important}
      .btn-secondary,.btn-light,.btn-outline-secondary,.btn-default{background:#0b0b0b!important;color:#e6e6e6!important;border-color:#1c1c1c!important}
      .btn-secondary *,.btn-light *,.btn-outline-secondary *,.btn-default *{color:#e6e6e6!important}
      .btn-link{color:#D2B48C!important}
      .btn-check:checked+.btn,.btn.active,.btn:active{background:#D2B48C!important;border-color:#D2B48C!important;color:#000!important}
      .badge.bg-primary,.badge-primary{background:#D2B48C!important;color:#000!important}
      .progress{background:#1c1c1c!important}
      .progress-bar{background:#D2B48C!important;color:#000!important}
      .alert{background:#0b0b0b!important;color:#e6e6e6!important;border-color:#1c1c1c!important}
      table,.table,.generaltable{--bs-table-bg:transparent;--bs-table-color:#e6e6e6;--bs-table-striped-bg:#060606;--bs-table-striped-color:#e6e6e6;--bs-table-hover-bg:#0b0b0b;--bs-table-hover-color:#e6e6e6;--bs-table-border-color:#1c1c1c;color:#e6e6e6;border-color:#1c1c1c!important}
      .table>:not(caption)>*>*,.generaltable td,.generaltable th,.generaltable .cell{background-color:transparent!important;border-color:#1c1c1c!important}
      .table-striped>tbody>tr:nth-of-type(odd)>*,.generaltable tbody tr:nth-of-type(odd)>*{background-color:#060606!important}
      .generaltable thead th,.generaltable .header,.table thead th{background-color:#0a0a0a!important}
      .nav-tabs{border-color:#1c1c1c!important}
      .nav-tabs .nav-link,.nav-pills .nav-link{color:#9a9a9a!important;background:transparent!important;border-color:transparent!important}
      .nav-link.active,.nav-tabs .nav-link.active,.nav-pills .nav-link.active{color:#D2B48C!important;background:transparent!important;border-bottom-color:#D2B48C!important}
      .page-link{background:#060606!important;border-color:#1c1c1c!important;color:#D2B48C!important}
      .page-item.active .page-link{background:#D2B48C!important;border-color:#D2B48C!important;color:#000!important}
      .dropdown-item{color:#e6e6e6!important}
      .dropdown-item:hover,.dropdown-item:focus{background:#1c1c1c!important}
      hr{border-color:#1c1c1c!important}
      .navbar-brand,#page-footer,footer{display:none!important}
      *,*::before,*::after{transition:none!important}
      `;
      function put(){ (document.documentElement||document).appendChild(s); }   // re-appending moves it to the end
      put();
      document.addEventListener('DOMContentLoaded', put);
      window.addEventListener('load', put);
    })();
    """#
}
