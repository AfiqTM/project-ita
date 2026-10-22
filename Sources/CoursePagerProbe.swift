import SwiftUI
import UIKit

// MARK: - Where the pages really are during a swipe
//
// The top cover (CourseChromeCover) has to slide exactly as far as the pages do. Measuring the finger is not exact: the
// pager's scroll view only starts moving after its own small slop, so the pages trail the finger by a few points and the
// cover ran ahead of them (a black block at the top that did not line up with the page under it).
// This reads the paging scroll view's contentOffset instead, the same way CourseScrollProbe reads the Course list.
// Put it as a .background of each page inside the TabView: it walks up to the paging scroll view that holds the page.

struct CoursePagerProbe: UIViewRepresentable {
    let pager: CoursePagerModel
    let index: Int      // position of the open tab
    let count: Int      // how many tabs there are

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.update(pager: pager, index: index, count: count)
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) {
        v.update(pager: pager, index: index, count: count)
        v.attachIfNeeded()
    }

    final class ProbeView: UIView {
        private var pager: CoursePagerModel?
        private var index = 0
        private var count = 1
        private var observation: NSKeyValueObservation?
        private var fromTouch = false       // the movement going on right now began with a finger (not a tab-strip tap)
        private var wasTouching = false
        private var rest: CGFloat?          // contentOffset.x the pager rested at when this swipe began
        private var last: CGFloat = 0       // the offset last passed on
        private var settleWork: DispatchWorkItem?

        func update(pager: CoursePagerModel, index: Int, count: Int) {
            self.pager = pager
            self.index = index
            self.count = count
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                observation = nil
                settleWork?.cancel()
            } else {
                attachIfNeeded()
                // the pager may not be in place yet during the first layout pass
                DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
            }
        }

        func attachIfNeeded() {
            guard observation == nil, window != nil else { return }
            var view: UIView? = superview
            while let v = view {
                if let sv = v as? UIScrollView, sv.isPagingEnabled {
                    pager?.followsPages = true
                    observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                        self?.report(s)
                    }
                    return
                }
                view = v.superview
            }
        }

        private func report(_ s: UIScrollView) {
            guard let pager else { return }
            let w = s.bounds.width
            guard w > 0 else { return }

            let touching = s.isTracking || s.isDragging
            if touching && !wasTouching { fromTouch = true; rest = nil; last = 0 }     // a new swipe begins
            wasTouching = touching
            // a page change started by tapping a tab animates by itself (the cover moves with the tab): only follow a swipe
            guard fromTouch else { return }
            guard touching || s.isDecelerating else {                                   // the swipe is over
                fromTouch = false
                rest = nil
                scheduleSettle()
                return
            }

            let base = rest ?? (s.contentOffset.x / w).rounded() * w
            rest = base
            let x = base - s.contentOffset.x
            // the pager re-centres its scroll view when a page change completes: a jump of a whole page, not movement
            if abs(x - last) > w * 0.6 { return }
            last = x
            pager.follow(x, index: index, count: count, width: w)
            scheduleSettle()
        }

        // fires once the offset has stopped changing (reports come every frame while it moves)
        private func scheduleSettle() {
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.pager?.settle() }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
}
