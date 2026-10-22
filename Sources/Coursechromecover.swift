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
