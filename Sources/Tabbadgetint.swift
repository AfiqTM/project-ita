import SwiftUI
import UIKit

// Colours the tab badges (Assignments, Alerts) in the app's accent without a custom UITabBarAppearance.
//
// On iOS 26 a custom UITabBarAppearance makes the glass tab bar lay its items out unevenly, so there the
// appearance is left alone (see Theme.applyAppearance) and the badge colour is set on the UITabBarItems here.
// SwiftUI's own .badge draws the badge and may reset the colour, so it is applied again:
//   - on every layout pass of the tab bar controller (before the frame is drawn, so no red flash), and
//   - whenever an item's badgeValue changes (key-value observing, in the same run-loop pass as the change).
//
// Put it as a .background of a tab that is loaded at launch (the first tab); it finds the UITabBarController
// that SwiftUI built through its parent chain.
struct TabBadgeTint: UIViewControllerRepresentable {
    let color: UIColor
    let text: UIColor

    func makeUIViewController(context: Context) -> TabBadgeProbe { TabBadgeProbe() }

    func updateUIViewController(_ vc: TabBadgeProbe, context: Context) {
        vc.color = color
        vc.text = text
        vc.apply()
    }
}

final class TabBadgeProbe: UIViewController {
    var color: UIColor = .systemRed
    var text: UIColor = .white
    private var observers: [NSKeyValueObservation] = []
    private var observedItems: [ObjectIdentifier] = []

    override func loadView() {
        let v = UIView()
        v.isUserInteractionEnabled = false
        view = v
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        apply()
    }

    func apply() {
        guard let items = tabBarController?.tabBar.items else { return }
        for item in items { paint(item) }

        // Watch each item's badge so a new count is painted straight away. Only re-created when the items change
        // (a theme switch rebuilds the whole TabView).
        let ids = items.map { ObjectIdentifier($0) }
        guard ids != observedItems else { return }
        observedItems = ids
        observers = items.map { item in
            item.observe(\.badgeValue, options: [.new]) { [weak self] item, _ in
                self?.paint(item)
            }
        }
    }

    private func paint(_ item: UITabBarItem) {
        if item.badgeColor != color { item.badgeColor = color }
        item.setBadgeTextAttributes([.foregroundColor: text], for: .normal)
        item.setBadgeTextAttributes([.foregroundColor: text], for: .selected)
    }
}
