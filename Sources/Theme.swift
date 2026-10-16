import SwiftUI
import UIKit

// The colours of one theme, as 0xRRGGBB values. The dark one is taken 1:1 from the "iTa'leem AMOLED Dark" userscript.
// Themes.swift lists the themes the user can pick; each one needs a palette here.
struct Palette {
    let bg, surface, surface2, titleBar, line, txt, muted, accent, onAccent: UInt32

    static let amoledDark = Palette(bg: 0x000000, surface: 0x060606, surface2: 0x0b0b0b, titleBar: 0x0a0a0a,
                                    line: 0x1c1c1c, txt: 0xe6e6e6, muted: 0x9a9a9a, accent: 0xD2B48C,
                                    onAccent: 0x000000)
    // Warm off-white page with white cards. The accent is a deeper tan so it stays readable on light
    // backgrounds (about 5:1 against white), and text on accent buttons is white.
    static let light = Palette(bg: 0xF7F4EF, surface: 0xFFFFFF, surface2: 0xF1EDE6, titleBar: 0xEEE9E0,
                               line: 0xE3DDD2, txt: 0x1F1B16, muted: 0x6B6458, accent: 0x8A6A3B,
                               onAccent: 0xFFFFFF)
}

// Every colour resolves by itself for the current look (light / dark), so switching theme re-colours
// the whole app without rebuilding any screen. (Dark is also what an unspecified style means.)
enum Theme {
    static func dyn(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) }
    }

    // UIKit versions (navigation bar, tab bar, tab badges)
    static let uiBg       = dyn(Palette.amoledDark.bg, Palette.light.bg)
    static let uiTxt      = dyn(Palette.amoledDark.txt, Palette.light.txt)
    static let uiAccent   = dyn(Palette.amoledDark.accent, Palette.light.accent)
    static let uiOnAccent = dyn(Palette.amoledDark.onAccent, Palette.light.onAccent)

    static let bg       = Color(uiColor: uiBg)
    static let surface  = Color(uiColor: dyn(Palette.amoledDark.surface, Palette.light.surface))
    static let surface2 = Color(uiColor: dyn(Palette.amoledDark.surface2, Palette.light.surface2))
    static let titleBar = Color(uiColor: dyn(Palette.amoledDark.titleBar, Palette.light.titleBar))   // "General" title bar / table headers
    static let line     = Color(uiColor: dyn(Palette.amoledDark.line, Palette.light.line))
    static let txt      = Color(uiColor: uiTxt)
    static let muted    = Color(uiColor: dyn(Palette.amoledDark.muted, Palette.light.muted))
    static let accent   = Color(uiColor: uiAccent)
    /// Text / icons drawn on top of an accent-coloured background (black on the tan, white on the deeper tan)
    static let onAccent = Color(uiColor: uiOnAccent)

    static func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: uiTxt]
        nav.largeTitleTextAttributes = [.foregroundColor: uiTxt]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiBg
        tab.shadowColor = .clear
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

// Dark: soft glow behind cards (the 10/30/64px rgba(28,28,28) shadows from the userscript).
// Light: a gentle drop shadow and a thin outline instead, since a glow doesn't show on a light page.
struct GlowCard: ViewModifier {
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // One fixed structure (only the values change), so switching theme never rebuilds what is inside the card
        let light = scheme == .light
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let g = Color(white: 28.0 / 255.0)
        return content
            .background(Theme.surface)
            .clipShape(shape)
            .overlay(shape.stroke(Theme.line, lineWidth: light ? 1 : 0))
            .shadow(color: light ? Color.black.opacity(0.06) : g.opacity(0.85), radius: light ? 6 : 5, y: light ? 2 : 0)
            .shadow(color: light ? Color.black.opacity(0.04) : g.opacity(0.5), radius: light ? 18 : 15, y: light ? 6 : 0)
            .shadow(color: light ? Color.clear : g.opacity(0.25), radius: 32)
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
