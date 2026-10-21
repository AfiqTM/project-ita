import SwiftUI
import UIKit

// The colours of one theme, as 0xRRGGBB values. The Dark one is taken 1:1 from the "iTa'leem AMOLED Dark" userscript.
// Themes.swift lists the themes the user can pick; each one needs a palette here.
struct Palette {
    /// How cards are lifted off the page: a soft glow (dark), a drop shadow + outline (light),
    /// a glow + outline like a terminal window, hard pixel edges with an offset block shadow (8-bit),
    /// or flat black with a red top strip and a dark drop shadow (western, Red Dead)
    enum Card { case glow, soft, terminal, pixel, western }

    let bg, surface, surface2, titleBar, line, txt, muted, accent, onAccent: UInt32
    let green, red, amber, blue: UInt32     // status colours (present / absent / late / info)
    let glow: UInt32                        // colour of the glow behind cards
    let card: Card

    static let dark = Palette(bg: 0x000000, surface: 0x060606, surface2: 0x0b0b0b, titleBar: 0x0a0a0a,
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
    static let terminal = Palette(bg: 0x020805, surface: 0x06120B, surface2: 0x0A1B11, titleBar: 0x08160E,
                                  line: 0x15402A, txt: 0xA9F5BC, muted: 0x5FA777, accent: 0x39FF6E,
                                  onAccent: 0x02140A,
                                  green: 0x39FF6E, red: 0xFF5C5C, amber: 0xFFC83D, blue: 0x4FB3FF,
                                  glow: 0x0C3D20, card: .terminal)

    // Old arcade: black with dark olive tiles, warm white text, yellow accent. Hard dim-yellow outlines and an
    // offset block shadow instead of a glow (card: .pixel).
    static let retro = Palette(bg: 0x000000, surface: 0x0E0D00, surface2: 0x1A1800, titleBar: 0x141200,
                               line: 0x5A5100, txt: 0xF3EEC4, muted: 0x9B9560, accent: 0xFFE628,
                               onAccent: 0x000000,
                               green: 0x7CFF6B, red: 0xFF5A4F, amber: 0xFFA928, blue: 0x58B4FF,
                               glow: 0x4A4300, card: .pixel)

    // Red Dead (after the game's own artwork and website): black, rockstar red, off-white text. Flat black cards with
    // a dark-red outline and a red banner strip on top (card: .western).
    static let redDead = Palette(bg: 0x020202, surface: 0x080808, surface2: 0x101010, titleBar: 0x050505,
                                 line: 0x2E100C, txt: 0xE8E2D8, muted: 0x8E8882, accent: 0xC8281C,
                                 onAccent: 0xFFFFFF,
                                 green: 0x8FA35A, red: 0xFF5440, amber: 0xFF8040, blue: 0x7C9BB0,
                                 glow: 0x000000, card: .western)
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

    private static let styleSizes: [(Font, CGFloat, Font.TextStyle, Bool)] = [   // font, size, scales with, Chinese Rocks?
        (.largeTitle, 34, .largeTitle, true), (.title, 28, .title, true), (.title2, 22, .title2, true),
        (.title3, 20, .title3, true), (.headline, 17, .headline, true), (.subheadline, 15, .subheadline, true),
        (.body, 17, .body, false), (.footnote, 13, .footnote, false),
        (.caption, 12, .caption, false), (.caption2, 11, .caption2, false)]

    /// A text style in the current theme: the system one, or in Red Dead Redemption 2 Chinese Rocks for titles and
    /// sub-titles (largeTitle ... subheadline) and Zilla Slab for running text (body, footnote, caption).
    /// (`.weight()` and `.bold()` can still be chained on the result; the fonts have one weight here.)
    static func font(_ style: Font) -> Font {
        guard ThemeStore.shared.theme.westernHeadings,
              let m = styleSizes.first(where: { $0.0 == style }) else { return style }
        if m.3 {
            let f = Face.display
            guard f.available else { return style }
            return .custom(f.name, size: m.1 * f.scale, relativeTo: m.2)
        }
        let f = Face.body
        guard f.available else { return style }
        return .custom(f.name, size: m.1 * f.scale, relativeTo: m.2)
    }

    /// Like `font`, but always the readable body font in Red Dead Redemption 2, even for the title/sub-title styles:
    /// for longer text that happens to be set in a sub-title size (descriptions, previews, page text).
    static func read(_ style: Font, bold: Bool = false) -> Font {
        let f = Face.body
        guard ThemeStore.shared.theme.westernHeadings, f.available,
              let m = styleSizes.first(where: { $0.0 == style }) else { return bold ? style.bold() : style }
        return .custom(bold ? f.bold : f.name, size: m.1 * f.scale, relativeTo: m.2)
    }

    /// Corner radius for cards: every theme keeps the rounded shape of the Dark theme
    static func cardRadius(_ r: CGFloat) -> CGFloat { r }

    /// Navigation bar, tab bar and tab badges. Bars that already exist keep the old look, so call this
    /// before the screens are rebuilt for a new theme (ThemeStore.select does).
    static func applyAppearance() {
        let theme = ThemeStore.shared.theme
        let mono = theme.mono

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBg
        nav.shadowColor = .clear
        var title: [NSAttributedString.Key: Any] = [.foregroundColor: uiTxt]
        var large: [NSAttributedString.Key: Any] = [.foregroundColor: uiTxt]
        if mono {
            title[.font] = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
            large[.font] = UIFont.monospacedSystemFont(ofSize: 34, weight: .bold)
            if theme.glowsText {
                let glow = NSShadow()
                glow.shadowColor = uiAccent.withAlphaComponent(0.6)
                glow.shadowBlurRadius = 6
                glow.shadowOffset = .zero
                title[.shadow] = glow
                large[.shadow] = glow
            } else if theme.pixelHeadings {
                // arcade title: hard block shadow and the pixel font
                let hard = NSShadow()
                hard.shadowColor = UIColor(hex: p.glow)
                hard.shadowBlurRadius = 0
                hard.shadowOffset = CGSize(width: 2, height: 2)
                title[.shadow] = hard
                large[.shadow] = hard
                if let f = UIFont(name: PixelFont.bold, size: 14) { title[.font] = f }
                if let f = UIFont(name: PixelFont.bold, size: 28) { large[.font] = f }
            }
        }
        if theme.westernHeadings {
            // the game's lettering, a little bigger than the system sizes (17 / 34) since the letters are narrow
            // Chinese Rocks Rg, with a little letter spacing
            let face = Face.display
            if let f = face.ui(face.navTitle) ?? UIFont(name: Face.body.name, size: 26) { title[.font] = f; title[.kern] = face.navKern }
            if let f = face.ui(face.navLarge) ?? UIFont(name: Face.body.name, size: 44) { large[.font] = f; large[.kern] = face.navKern * 1.3 }
        }
        nav.titleTextAttributes = title
        nav.largeTitleTextAttributes = large
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        if #available(iOS 26.0, *) {
            // iOS 26's tab bar is a floating glass pill: no painted background behind it, so screens
            // scroll underneath instead of ending in a solid band (the pill itself stays glass)
            tab.configureWithTransparentBackground()
        } else {
            tab.configureWithOpaqueBackground()
            tab.backgroundColor = uiBg
        }
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
        // UIKit controls that SwiftUI wraps (segmented pickers, bar buttons) need the font set here as well
        let seg = UISegmentedControl.appearance()
        let barButton = UIBarButtonItem.appearance()
        if theme.westernHeadings, let f = Face.display.ui(Face.display.bar) ?? UIFont(name: Face.body.name, size: 17) {
            seg.setTitleTextAttributes([.font: f], for: .normal)
            seg.setTitleTextAttributes([.font: f], for: .selected)
            barButton.setTitleTextAttributes([.font: f], for: .normal)
            barButton.setTitleTextAttributes([.font: f], for: .highlighted)
        } else if theme.pixelHeadings, let f = UIFont(name: PixelFont.bold, size: 11) {
            // Retro: pixel font on the segmented pickers (All / Unread, ...) and bar buttons
            seg.setTitleTextAttributes([.font: f], for: .normal)
            seg.setTitleTextAttributes([.font: f], for: .selected)
            barButton.setTitleTextAttributes([.font: f], for: .normal)
            barButton.setTitleTextAttributes([.font: f], for: .highlighted)
        } else if theme.mono {
            // Terminal: monospaced
            let f = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            seg.setTitleTextAttributes([.font: f], for: .normal)
            seg.setTitleTextAttributes([.font: f], for: .selected)
            barButton.setTitleTextAttributes([.font: f], for: .normal)
            barButton.setTitleTextAttributes([.font: f], for: .highlighted)
        } else {
            seg.setTitleTextAttributes(nil, for: .normal)
            seg.setTitleTextAttributes(nil, for: .selected)
            barButton.setTitleTextAttributes(nil, for: .normal)
            barButton.setTitleTextAttributes(nil, for: .highlighted)
        }
        if theme.westernHeadings, let f = Face.display.ui(Face.display.tab) ?? UIFont(name: Face.body.name, size: 15) {
            // tab bar labels: Chinese Rocks Rg; the kern keeps the narrow capitals from touching and
            // "Assignments" still fits its slot (about 71 pt wide at this size)
            for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
                item.normal.titleTextAttributes = [.font: f, .kern: Face.display.tabKern, .foregroundColor: UIColor(hex: p.muted)]
                item.selected.titleTextAttributes = [.font: f, .kern: Face.display.tabKern, .foregroundColor: uiAccent]
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

// Card background. Dark: soft glow (the 10/30/64px rgba(28,28,28) shadows from the userscript).
// Light: a gentle drop shadow and a thin outline, since a glow doesn't show on a light page.
// Terminal: a green glow and a thin green outline, like a terminal window.
// Red Dead: flat black card, dark-red outline, red strip on top and a dark drop shadow, like the game's banners.
// Retro: the usual rounded corners with a thick outline and a hard offset block shadow, like an arcade bezel.
struct GlowCard: ViewModifier {
    var radius: CGFloat = 14
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        // One fixed structure (only the values change), so switching theme never rebuilds what is inside the card
        let p = themes.theme.palette
        let pixel = p.card == .pixel
        let western = p.card == .western
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius(radius), style: .continuous)
        let g = Color(hex: p.glow)
        // three shadow layers: colour, blur, x offset, y offset
        let layers: [(Color, CGFloat, CGFloat, CGFloat)]
        switch p.card {
        case .glow, .terminal:
            layers = [(g.opacity(0.85), 5, 0, 0), (g.opacity(0.5), 15, 0, 0), (g.opacity(0.25), 32, 0, 0)]
        case .soft:
            layers = [(Color.black.opacity(0.06), 6, 0, 2), (Color.black.opacity(0.04), 18, 0, 6), (Color.clear, 0, 0, 0)]
        case .pixel:
            layers = [(g, 0, 3, 3), (Color.clear, 0, 0, 0), (Color.clear, 0, 0, 0)]
        case .western:
            layers = [(Color.black.opacity(0.7), 6, 0, 3), (Color.black.opacity(0.45), 18, 0, 8), (Color.clear, 0, 0, 0)]
        }
        return content
            .background(Color(hex: p.surface))
            // western: a red banner along the top edge with a torn-paper lower edge (inside the rounded corners)
            .overlay(alignment: .top) { TornBand().fill(Color(hex: p.accent)).frame(height: western ? 9 : 0) }
            .clipShape(shape)
            .overlay(shape.stroke(Color(hex: p.line), lineWidth: p.card == .glow ? 0 : (pixel ? 2 : 1)))

            .shadow(color: layers[0].0, radius: layers[0].1, x: layers[0].2, y: layers[0].3)
            .shadow(color: layers[1].0, radius: layers[1].1, x: layers[1].2, y: layers[1].3)
            .shadow(color: layers[2].0, radius: layers[2].1, x: layers[2].2, y: layers[2].3)
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
