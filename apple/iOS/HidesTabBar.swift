import SwiftUI
import UIKit

extension View {
    /// Hides the tab bar on a pushed screen. Going back to the list, the bar slides in with the
    /// pop (and follows a back swipe) rather than appearing after it: SwiftUI's own
    /// `.toolbar(.hidden, for: .tabBar)` only shows it once the pop has finished.
    func hidesTabBarWhenPushed() -> some View {
        toolbar(.hidden, for: .tabBar)
            .background(TabBarReturn().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Watches its screen leave the navigation stack. When that pop lands on the list, it brings the
/// tab bar back alongside the transition, and hides it again if a back swipe is cancelled.
private struct TabBarReturn: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Watcher {
        Watcher()
    }

    func updateUIViewController(_ controller: Watcher, context: Context) {}

    final class Watcher: UIViewController {
        /// Found while on screen: by the time a pop begins, the screen may already be out of
        /// the navigation controller's list.
        private weak var screen: UIViewController?
        private weak var navigation: UINavigationController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            var controller = parent
            while let current = controller {
                if let navigation = current.parent as? UINavigationController {
                    screen = current
                    self.navigation = navigation
                    return
                }
                controller = current.parent
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let screen, let navigation, !navigation.viewControllers.contains(screen),
                  navigation.viewControllers.count == 1,
                  let tabs = navigation.tabBarController, tabs.isTabBarHidden else { return }
            tabs.setTabBarHidden(false, animated: animated)
            navigation.transitionCoordinator?.animate(alongsideTransition: nil) { context in
                if context.isCancelled { tabs.setTabBarHidden(true, animated: false) }
            }
        }
    }
}
