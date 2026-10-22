import SwiftUI
import UIKit

// MARK: - Where the pages really are during a swipe
//
// The top cover (CourseChromeCover) has to slide exactly as far as the pages do. Measuring the finger is not exact: the
// pager's scroll view only starts moving after its own small slop, so the pages trail the finger by a few points and the
// cover ran ahead of them (a black block at the top that did not line up with the page under it).
// This reads the paging scroll view's contentOffset instead, the same way CourseScrollProbe reads the Course list.
//
// Put CoursePagerProbe as a .background of each page inside the TabView. It walks up to the paging scroll view that holds
// the page and hands it to ONE PagerFollower (stored on the scroll view), however many pages carry a probe.

struct CoursePagerProbe: UIViewRepresentable {
    let pager: CoursePagerModel
    let index: Int      // position of the open tab
    let count: Int      // how many tabs there are

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.pager = pager
        v.index = index
        v.count = count
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) {
        v.pager = pager
        v.index = index
        v.count = count
        v.attachIfNeeded()
    }

    final class ProbeView: UIView {
        var pager: CoursePagerModel?
        var index = 0
        var count = 1

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            attachIfNeeded()
            // the pager may not be in place yet during the first layout pass
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }

        func attachIfNeeded() {
            guard window != nil, let pager else { return }
            var view: UIView? = superview
            while let v = view {
                if let sv = v as? UIScrollView, sv.isPagingEnabled {
                    PagerFollower.attach(to: sv, pager: pager, index: index, count: count)
                    return
                }
                view = v.superview
            }
        }
    }
}

private var pagerFollowerKey: UInt8 = 0

/// Follows one paging scroll view and tells the CoursePagerModel how far a swipe has moved the pages.
final class PagerFollower: NSObject {
    private var pager: CoursePagerModel
    private var index: Int              // the open tab (kept up to date by the probes)
    private var count: Int
    private weak var scroll: UIScrollView?
    private var observation: NSKeyValueObservation?

    private var fromTouch = false       // the movement going on right now began with a finger (not a tab-strip tap)
    private var wasTouching = false
    private var startIndex = 0          // the open tab when the swipe began (the pager flips the open tab halfway through)
    private var rest: CGFloat = 0       // contentOffset.x the pager rested at when the swipe began
    private var last: CGFloat = 0       // the offset last passed on
    private var endWork: DispatchWorkItem?

    static func attach(to sv: UIScrollView, pager: CoursePagerModel, index: Int, count: Int) {
        if let f = objc_getAssociatedObject(sv, &pagerFollowerKey) as? PagerFollower {
            f.pager = pager
            f.index = index
            f.count = count
            return
        }
        let f = PagerFollower(scroll: sv, pager: pager, index: index, count: count)
        objc_setAssociatedObject(sv, &pagerFollowerKey, f, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private init(scroll: UIScrollView, pager: CoursePagerModel, index: Int, count: Int) {
        self.scroll = scroll
        self.pager = pager
        self.index = index
        self.count = count
        super.init()
        pager.followsPages = true
        observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
            self?.report(s)
        }
        // lets us know when the finger lifts, even if the pages then have nowhere to move
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
    }

    deinit {
        observation?.invalidate()
        endWork?.cancel()
        scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
    }

    @objc private func panChanged(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: endWork?.cancel()
        case .ended, .cancelled, .failed: scheduleEnd()
        default: break
        }
    }

    private func report(_ s: UIScrollView) {
        let w = s.bounds.width
        guard w > 0 else { return }

        let touching = s.isTracking || s.isDragging
        if touching && !wasTouching {                       // a finger came down: a new swipe begins
            pager.swipeEnded()                              // (closes one still open from before)
            fromTouch = true
            startIndex = index
            rest = (s.contentOffset.x / w).rounded() * w
            last = 0
            endWork?.cancel()
        }
        wasTouching = touching
        // a page change started by tapping a tab animates by itself (the cover moves with the tab): only follow a swipe
        guard fromTouch else { return }
        guard touching || s.isDecelerating else {           // the pages have stopped
            fromTouch = false
            scheduleEnd()
            return
        }

        let x = rest - s.contentOffset.x                    // + = pages moved right
        // the pager re-centres its scroll view at times (a jump of a whole page that does not move the pages): carry on from there
        if abs(x - last) > w * 0.6 {
            rest = s.contentOffset.x + last
            return
        }
        last = x
        pager.swipeMoved(x, from: startIndex, count: count, width: w)
        // the next page has fully arrived: hand the cover back to the open tab right now (no waiting for the timer), so the
        // old tab's solid strip doesn't linger over the Course photo
        if !touching && abs(abs(x) - w) < 1 {
            fromTouch = false
            endWork?.cancel()
            pager.swipeEnded()
            return
        }
        if !touching { scheduleEnd() }                      // finger is up: the end comes once the pages stop moving
    }

    // fires once nothing has moved for a moment (reports come every frame while the pages move)
    private func scheduleEnd() {
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pager.swipeEnded() }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
