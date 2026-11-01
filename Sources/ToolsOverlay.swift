import SwiftUI

// MARK: - Full-screen layer for the Noticeboard's tool tiles
//
// Same idea as the Messages layer (Messages.swift): the tool's screen sits in its own layer above the whole TabView,
// slides in from the right, and slides back out to the right (a back arrow, or a swipe to the right from anywhere on
// the screen). It is not pushed onto the Noticeboard's navigation stack, so leaving it never depends on the pager
// underneath, and the Noticeboard is exactly as it was when the layer is gone.

final class ToolPresenter: ObservableObject {
    static let shared = ToolPresenter()
    @Published var tool: DailyTool?
    /// The layer's own navigation stack: when a screen inside the tool is open, the swipe belongs to that stack's back gesture
    weak var nav: UINavigationController?

    func open(_ t: DailyTool) { withAnimation(.easeOut(duration: 0.28)) { tool = t } }
    func close() { withAnimation(.easeOut(duration: 0.25)) { tool = nil } }
}

extension DailyTool {
    @ViewBuilder var screen: some View {
        switch self {
        case .todo: TodoListView()
        case .calculator: CAMSCalculatorScreen()
        case .drive: MyDriveView()
        case .attendance: AutoAttendanceView()
        case .studyPlan: StudyPlanTrackerView()
        case .resources: SemesterResourcesView()
        }
    }
}

/// Finds the navigation stack it sits in, so the layer knows whether a screen inside the tool is open
private struct NavGrab: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Grab { Grab() }
    func updateUIViewController(_ vc: Grab, context: Context) {}
    final class Grab: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            ToolPresenter.shared.nav = navigationController
        }
    }
}

struct ToolsOverlay: View {
    @ObservedObject private var presenter = ToolPresenter.shared
    @State private var dragX: CGFloat = 0
    @State private var horizontal: Bool?

    var body: some View {
        GeometryReader { geo in
            if let tool = presenter.tool {
                NavigationStack {
                    tool.screen
                        .background(NavGrab())
                        .toolbar {
                            if ThemeStore.shared.theme == .notebook {
                                NotebookBackToolbar { presenter.close() }
                            } else {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button { presenter.close() } label: {
                                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                                    }
                                    .accessibilityLabel("Back")
                                }
                            }
                        }
                }
                .background(Theme.bg.ignoresSafeArea())
                .offset(x: dragX)
                .shadow(color: .black.opacity(dragX > 0 ? 0.35 : 0), radius: 10)
                .transition(.move(edge: .trailing))
                .simultaneousGesture(swipeBack(width: geo.size.width))
            }
        }
        .allowsHitTesting(presenter.tool != nil)
    }

    private var nested: Bool { (presenter.nav?.viewControllers.count ?? 1) > 1 }

    private func swipeBack(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                guard !nested else { return }
                if horizontal == nil {   // decided once, so scrolling up and down never drags the page
                    horizontal = g.translation.width > 0 && abs(g.translation.width) > abs(g.translation.height) * 1.3
                }
                if horizontal == true { dragX = max(0, g.translation.width) }
            }
            .onEnded { g in
                let wasHorizontal = horizontal == true
                horizontal = nil
                guard wasHorizontal, !nested else { dragX = 0; return }
                let far = g.translation.width > width * 0.33 || g.predictedEndTranslation.width > width * 0.6
                if far {
                    let remaining = max(0, width - dragX) / max(width, 1)
                    let dur = 0.12 + 0.10 * Double(remaining)
                    withAnimation(.easeOut(duration: dur)) { dragX = width }
                    DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { presenter.tool = nil; dragX = 0 }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { dragX = 0 }
                }
            }
    }
}
