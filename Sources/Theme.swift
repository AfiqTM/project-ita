import SwiftUI
import UIKit

// Colours taken 1:1 from the "iTa'leem AMOLED Dark" userscript
enum Theme {
    static let bg       = Color(hex: 0x000000)
    static let surface  = Color(hex: 0x060606)
    static let surface2 = Color(hex: 0x0b0b0b)
    static let titleBar = Color(hex: 0x0a0a0a)   // "General" title bar / table headers
    static let line     = Color(hex: 0x1c1c1c)
    static let txt      = Color(hex: 0xe6e6e6)
    static let muted    = Color(hex: 0x9a9a9a)
    static let accent   = Color(hex: 0xD2B48C)

    static func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .black
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(txt)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(txt)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = .black
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

// Soft dark glow behind cards (the 10/30/64px rgba(28,28,28) shadows from the userscript)
struct GlowCard: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        let g = Color(white: 28.0 / 255.0)
        content
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: g.opacity(0.85), radius: 5)
            .shadow(color: g.opacity(0.5), radius: 15)
            .shadow(color: g.opacity(0.25), radius: 32)
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
