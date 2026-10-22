import SwiftUI

// MARK: - Top bar cover that moves with the pages
//
// The cover behind the status bar, the navigation bar AND the tab strip is drawn as one strip per tab, side by side,
// exactly like the pages below it. While you swipe between tabs the strips slide sideways by the same distance as the
// pages, so the black top area of the next tab arrives together with its page (not before it).
//   Course tab strip : clear at the top (the photo shows through), solid once the photo has scrolled away
//   every other tab  : solid

/// How far a swipe between tabs has moved (in points). Kept in its own object so only the cover redraws while swiping.
final class CoursePagerModel: ObservableObject {
    @Published var dragX: CGFloat = 0
    /// True once CoursePagerProbe is reading the real page position; the finger-based fallback in CourseDetailView stands down.
    var followsPages = false

    /// The pages are `x` points from where they rest (+ = moved right). Called by CoursePagerProbe on every scroll step.
    func follow(_ x: CGFloat, index: Int, count: Int, width: CGFloat) {
        var dx = max(-width, min(width, x))
        if index == 0 { dx = min(dx, 0) }                  // no page before the first tab
        if index == count - 1 { dx = max(dx, 0) }          // none after the last
        if abs(dx - dragX) > 0.01 { dragX = dx }
    }

    /// The swipe has stopped moving. A finished page change already put the cover back (CourseDetailView resets it when the
    /// tab changes); a swipe that snapped back may leave a hair of offset, so clear it.
    func settle() {
        guard dragX != 0 else { return }
        withAnimation(.easeOut(duration: 0.15)) { dragX = 0 }
    }
}

struct CourseChromeCover: View {
    @ObservedObject var scroll: CourseScrollModel
    @ObservedObject var pager: CoursePagerModel
    let tabs: [CourseTab]
    let current: CourseTab

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let i = tabs.firstIndex(of: current) ?? 0
            let scrolled = min(max(scroll.y / 260, 0), 1)
            ZStack(alignment: .topLeading) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { n, t in
                    Theme.bg
                        .opacity(t == .course ? scrolled : 1)
                        .frame(width: w)
                        .offset(x: CGFloat(n - i) * w + pager.dragX)
                }
            }
            .frame(width: w, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}
