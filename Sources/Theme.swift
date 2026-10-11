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
    var plainText: String {
        var s = replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n",
                                     options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let ents: [(String, String)] = [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                                        ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")]
        for (a, b) in ents { s = s.replacingOccurrences(of: a, with: b) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
// (trimmed port of the userscript's stylesheet)
enum WebTheme {
    static let js = #"""
    (function(){
      var s=document.createElement('style');
      s.textContent=`
      :root{--amoled-bg:#000;--amoled-surface:#060606;--amoled-surface-2:#0b0b0b;--amoled-border:#1c1c1c;
        --amoled-text:#e6e6e6;--amoled-muted:#9a9a9a;--amoled-accent:#D2B48C;
        --bs-body-bg:#000;--bs-body-color:#e6e6e6;--bs-border-color:#1c1c1c;--bs-link-color:#D2B48C;
        --bs-primary:#D2B48C;--bs-primary-rgb:210,180,140;color-scheme:dark}
      html,body,#page,#page-wrapper,#page-content,#region-main,#topofscroll,.main-inner{background:#000!important;color:#e6e6e6!important}
      .navbar,nav.navbar,.primary-navigation,.secondary-navigation,.drawer,.drawer-left,.drawer-right,.moremenu{background:#000!important;border-color:transparent!important;box-shadow:none!important}
      .card,.block,.box,.well,.list-group-item,.popover,.modal-content,.dropdown-menu,.generalbox,.activity-item,.course-content .section,.que .content,.que .info,.bg-white,.bg-light{background:#060606!important;color:#e6e6e6!important;border-color:#1c1c1c!important;box-shadow:none!important}
      h1,h2,h3,h4,h5,h6,p,span,label,td,th,li,.text-dark,.breadcrumb-item{color:#e6e6e6!important}
      .text-muted,.text-secondary,small,.small,.dimmed_text{color:#9a9a9a!important}
      a,a:visited{color:#D2B48C}
      input,select,textarea,.form-control,.form-select,.input-group-text{background:#060606!important;color:#e6e6e6!important;border-color:#1c1c1c!important}
      .btn-primary,.bg-primary,.progress-bar{background:#D2B48C!important;border-color:#D2B48C!important;color:#000!important}
      .btn-secondary,.btn-light,.btn-outline-secondary{background:#0b0b0b!important;color:#e6e6e6!important;border-color:#1c1c1c!important}
      table,.table,.generaltable,.table td,.table th{background:transparent!important;color:#e6e6e6!important;border-color:#1c1c1c!important}
      .generaltable thead th{background:#0a0a0a!important}
      .nav-link.active,.nav-tabs .nav-link.active{color:#D2B48C!important;background:transparent!important;border-color:transparent!important}
      .navbar-brand,#page-footer,footer{display:none!important}
      *,*::before,*::after{transition:none!important}
      `;
      document.documentElement.appendChild(s);
    })();
    """#
}
