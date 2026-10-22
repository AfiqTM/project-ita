import SwiftUI
import UIKit

// MARK: - Scroll position of the Course list
//
// Reports how far the Course tab's list has scrolled, read straight from the list's UIScrollView (contentOffset), so the
// header photo can move up with it. Put it as a .background of the list's content. It finds the scroll view it sits in,
// so it needs no coordinate space and no preference key (those can silently stop reporting inside a paged TabView).
// 0 = list at the top; grows as the list is scrolled down; negative while pulling down past the top.
//
// onDetach: called when the list leaves the window (the paged TabView unloads pages that are not next to the open one, and a
// pushed screen hides it too). A list that comes back is a fresh UIScrollView at the top, so whoever keeps the last position
// must forget it then, otherwise the header keeps drawing for a scroll position the list no longer has.

struct CourseScrollProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void
    var onDetach: () -> Void = {}

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.onChange = onChange
        v.onDetach = onDetach
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) {
        v.onChange = onChange
        v.onDetach = onDetach
        v.attachIfNeeded()
    }

    final class ProbeView: UIView {
        var onChange: (CGFloat) -> Void = { _ in }
        var onDetach: () -> Void = {}
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                let hadObservation = observation != nil
                observation = nil
                if hadObservation {
                    // async: not in the middle of a layout / view update
                    DispatchQueue.main.async { [weak self] in self?.onDetach() }
                }
            } else {
                attachIfNeeded()
            }
        }

        func attachIfNeeded() {
            guard observation == nil, window != nil else { return }
            var view: UIView? = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            guard let sv = view as? UIScrollView else { return }
            observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                self?.report(s)
            }
            // the position it is at right now (async: not in the middle of a layout pass)
            DispatchQueue.main.async { [weak self, weak sv] in
                if let sv { self?.report(sv) }
            }
        }

        private func report(_ s: UIScrollView) {
            onChange(s.contentOffset.y + s.adjustedContentInset.top)
        }
    }
}
