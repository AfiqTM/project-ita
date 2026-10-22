import SwiftUI

// MARK: - Top bar cover that moves with the pages
//
// The cover behind the status bar, the navigation bar AND the tab strip is drawn as one strip per tab, side by side,
// exactly like the pages below it. While you swipe between tabs the strips slide sideways by the same distance as the
// pages, so the black top area of the next tab arrives together with its page (not before it).
//   Course tab strip : clear at the top (the photo shows through), solid once the photo has scrolled away
//   every other tab  : solid
//
// The distance comes from the pager's real scroll position (see CoursePagerProbe). The pager switches the open tab
// halfway through a swipe, long before the next page has arrived, so while a swipe is going on the strips are placed
// from the tab the swipe STARTED on (`anchor`), not from the open tab. Otherwise the cover would jump to solid black
// at the halfway point while the page below it is still sliding in.

/// How far a swipe between tabs has moved (in points). Kept in its own object so only the cover redraws while swiping.
final class CoursePagerModel: ObservableObject {
    /// How far the cover strips are shifted sideways.
    @Published private(set) var shown: CGFloat = 0
    /// While a swipe is being followed: the index of the tab it started from. nil when no swipe is going on.
    @Published private(set) var anchor: Int? = nil
    /// True once CoursePagerProbe is reading the real page position; the finger-based fallback in CourseDetailView stands down.
    var followsPages = false

    /// Shift of the cover strips. Writes are ignored while a swipe is followed (the pager decides then): that covers
    /// the reset CourseDetailView does when the open tab changes, which happens halfway through a swipe.
    var dragX: CGFloat {
        get { shown }
        set { if anchor == nil { shown = newValue } }
    }

    /// The pages are `x` points from where they were when the swipe began (+ = moved right).
    func swipeMoved(_ x: CGFloat, from index: Int, count: Int, width: CGFloat) {
        let a = anchor ?? index
        var dx = max(-width, min(width, x))
        if a == 0 { dx = min(dx, 0) }                      // no page before the first tab
        if a == count - 1 { dx = max(dx, 0) }              // none after the last
        if anchor == nil { anchor = a }
        if abs(dx - shown) > 0.01 { shown = dx }
    }

    /// The swipe has finished and the open tab has caught up: the strips go back to being placed from the open tab.
    func swipeEnded() {
        guard anchor != nil else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            anchor = nil
            shown = 0
        }
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
            let i = pager.anchor ?? (tabs.firstIndex(of: current) ?? 0)
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
