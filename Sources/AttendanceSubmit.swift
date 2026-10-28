import SwiftUI
import WebKit

// MARK: - Self-submitted attendance
//
// Some sessions let students record their own attendance: the site's attendance page then shows a
// "Submit attendance" link on that session's row. These are read from the page and offered as a button
// on the attendance screen; pressing it opens the site's own submit page, picks "Present" and sends it.
// A session that needs a password (or has several status choices without a "Present") is left open
// on the page so it can be finished by hand.

struct AttSubmitLink: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: String { url.absoluteString }
}

enum AttendanceSubmitParse {
    static func links(in html: String, base: URL) -> [AttSubmitLink] {
        guard let re = try? NSRegularExpression(
            pattern: "<a\\b[^>]*href=\"([^\"]*attendance\\.php\\?[^\"]*sessid=\\d+[^\"]*)\"",
            options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var out: [AttSubmitLink] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&")
            guard let u = URL(string: href, relativeTo: base)?.absoluteURL,
                  seen.insert(u.absoluteString).inserted else { continue }
            out.append(AttSubmitLink(url: u, title: rowTitle(ns, at: m.range.location)))
        }
        return out
    }

    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .decodedEntities
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The date / time cell of the table row the link sits in ("Mon 5Oct 2026 9AM - 11AM")
    private static func rowTitle(_ ns: NSString, at loc: Int) -> String {
        let start = ns.range(of: "<tr", options: .backwards, range: NSRange(location: 0, length: loc))
        guard start.location != NSNotFound else { return "" }
        let rest = NSRange(location: loc, length: ns.length - loc)
        let end = ns.range(of: "</tr>", options: [], range: rest)
        guard end.location != NSNotFound else { return "" }
        let row = ns.substring(with: NSRange(location: start.location, length: end.location - start.location))
        guard let re = try? NSRegularExpression(pattern: "<t[dh][^>]*>([\\s\\S]*?)</t[dh]>", options: [.caseInsensitive]) else { return "" }
        let rns = row as NSString
        for m in re.matches(in: row, range: NSRange(location: 0, length: rns.length)) {
            let t = plain(rns.substring(with: m.range(at: 1)))
            if !t.isEmpty { return t }
        }
        return ""
    }
}

/// The site's submit page, shown while it is filled in: picks "Present" and presses save. Goes back when the site accepted it.
struct AttendanceSubmitView: View {
    let link: AttSubmitLink
    let courseName: String
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Opening the session…"
    @State private var ready = false

    var body: some View {
        VStack(spacing: 0) {
            Text(status).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(8).background(Theme.surface)
            if ready {
                AttendanceSubmitWeb(url: link.url, onStatus: { status = $0 }, onDone: { dismiss() })
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Submit attendance")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // the web view has to use the same cookies, not a new sign-in
            await MoodleAPI.shared.syncCookies()
            ready = true
        }
    }
}

private struct AttendanceSubmitWeb: UIViewRepresentable {
    let url: URL
    let onStatus: (String) -> Void
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStatus: onStatus, onDone: onDone) }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onStatus: (String) -> Void
        let onDone: () -> Void
        private var submitted = false
        private var finished = false
        init(onStatus: @escaping (String) -> Void, onDone: @escaping () -> Void) {
            self.onStatus = onStatus; self.onDone = onDone
        }

        // returns ok (sent), password, choose (several statuses, none is "Present"), none (no form on the page)
        private static let fill = """
        (function(){
          var fs = [].slice.call(document.forms).filter(function(f){
            return /attendance\\.php/.test(f.action || '') && f.querySelector('input[type=radio][name=status]');
          });
          if (!fs.length) return 'none';
          var f = fs[0];
          if (f.querySelector('input[name=studentpassword]')) return 'password';
          var radios = [].slice.call(f.querySelectorAll('input[type=radio][name=status]'));
          var pick = null;
          radios.forEach(function(r){
            if (pick) return;
            var l = r.id ? f.querySelector('label[for="' + r.id + '"]') : null;
            var t = ((l && l.textContent) || (r.parentNode && r.parentNode.textContent) || '').toLowerCase();
            if (/present/.test(t)) pick = r;
          });
          if (!pick && radios.length === 1) pick = radios[0];
          if (!pick) return 'choose';
          pick.checked = true;
          var b = f.querySelector('input[type=submit]:not([name=cancel]), button[type=submit]');
          if (b) { b.click(); } else { f.submit(); }
          return 'ok';
        })()
        """

        // still showing the status form after sending = the site did not take it
        private static let stillForm = """
        (function(){ return document.querySelector('input[type=radio][name=status]') ? 'form' : 'gone'; })()
        """

        private func say(_ s: String) { DispatchQueue.main.async { self.onStatus(s) } }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            if w.url?.path.contains("/login/") == true {
                say("You're signed out. Go back, pull down to refresh the attendance page, then try again.")
                return
            }
            if submitted {
                guard !finished else { return }
                w.evaluateJavaScript(Self.stillForm) { [weak self] r, _ in
                    guard let self = self, !self.finished else { return }
                    if (r as? String) == "form" {
                        self.say("The site didn't accept it. Finish it on this page.")
                        self.submitted = false
                    } else {
                        self.finished = true
                        self.say("Attendance submitted")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.onDone() }
                    }
                }
                return
            }
            w.evaluateJavaScript(Self.fill) { [weak self] r, _ in
                guard let self = self else { return }
                switch r as? String {
                case "ok": self.submitted = true; self.say("Submitting…")
                case "password": self.say("This session needs a password. Enter it below.")
                case "choose": self.say("Choose your status below, then save.")
                default: self.say("Nothing to submit on this page (it may be closed or already taken).")
                }
            }
        }
    }
}
