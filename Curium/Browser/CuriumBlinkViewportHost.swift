import SwiftUI
import UIKit

struct CuriumBlinkViewportHost: UIViewControllerRepresentable {
    let tab: CuriumTabModel?
    let topOverlayHeight: CGFloat
    let standby: CuriumStandbyPage

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.browserTab = tab
        let engine = tab?.engine
        if let engine {
            controller.showStandby(nil)
            controller.mount(engine.webView, scrollView: engine.scrollView, topInset: topOverlayHeight)
        } else {
            controller.mount(nil, scrollView: nil, topInset: 0)
            controller.showStandby(standby)
        }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.mount(nil, scrollView: nil, topInset: 0)
        controller.showStandby(nil)
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        weak var browserTab: CuriumTabModel?
        private weak var historyGestureTab: CuriumTabModel?
        private var standbyController: UIHostingController<CuriumStandbyPage>?
        private weak var mountedView: UIView?
        private weak var scrollView: UIScrollView?
        private var originalTop: CGFloat = 0
        private var originalIndicatorTop: CGFloat = 0
        private var originalAdjustment: UIScrollView.ContentInsetAdjustmentBehavior = .automatic
        private var originalAutomaticIndicators = true

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHistoryPan))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delaysTouchesEnded = false
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        func showStandby(_ content: CuriumStandbyPage?) {
            if let content {
                if let standbyController {
                    standbyController.rootView = content
                } else {
                    let controller = UIHostingController(rootView: content)
                    addChild(controller)
                    controller.view.backgroundColor = .clear
                    controller.view.frame = view.bounds
                    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    view.addSubview(controller.view)
                    controller.didMove(toParent: self)
                    standbyController = controller
                }
            } else if let standbyController {
                standbyController.willMove(toParent: nil)
                standbyController.view.removeFromSuperview()
                standbyController.removeFromParent()
                self.standbyController = nil
            }
        }

        func mount(_ webView: UIView?, scrollView newScrollView: UIScrollView?, topInset: CGFloat) {
            if mountedView !== webView {
                mountedView?.removeFromSuperview()
                mountedView = webView
                if let webView {
                    webView.frame = view.bounds
                    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    webView.translatesAutoresizingMaskIntoConstraints = true
                    view.addSubview(webView)
                }
            }
            if scrollView !== newScrollView {
                if let previous = scrollView {
                    apply(top: originalTop, indicatorTop: originalIndicatorTop, to: previous)
                    previous.contentInsetAdjustmentBehavior = originalAdjustment
                    previous.automaticallyAdjustsScrollIndicatorInsets = originalAutomaticIndicators
                }
                scrollView = newScrollView
                if let newScrollView {
                    originalTop = newScrollView.contentInset.top
                    originalIndicatorTop = newScrollView.verticalScrollIndicatorInsets.top
                    originalAdjustment = newScrollView.contentInsetAdjustmentBehavior
                    originalAutomaticIndicators = newScrollView.automaticallyAdjustsScrollIndicatorInsets
                }
            }
            guard let scrollView else { return }
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.automaticallyAdjustsScrollIndicatorInsets = false
            apply(top: topInset, indicatorTop: topInset, to: scrollView)
        }

        private func apply(top: CGFloat, indicatorTop: CGFloat, to scrollView: UIScrollView) {
            // Blink consumes explicit top insets. The vertical indicator API preserves
            // the horizontal scrollbar, and the keyboard never changes the bottom inset.
            if scrollView.contentInset.top != top { scrollView.contentInset.top = top }
            if scrollView.verticalScrollIndicatorInsets.top != indicatorTop {
                scrollView.verticalScrollIndicatorInsets.top = indicatorTop
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let x = touch.location(in: view).x
            let edgeWidth = min(24, view.bounds.width / 4)
            return x <= edgeWidth || x >= view.bounds.width - edgeWidth
        }

        private func startsOnLeft(_ pan: UIPanGestureRecognizer) -> Bool {
            let startX = pan.location(in: view).x - pan.translation(in: view).x
            return startX < view.bounds.midX
        }

        private func goesBack(_ pan: UIPanGestureRecognizer) -> Bool {
            startsOnLeft(pan) == (view.effectiveUserInterfaceLayoutDirection == .leftToRight)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let tab = browserTab, !tab.isFullscreen else { return false }
            let movement = pan.translation(in: view)
            return abs(movement.x) > abs(movement.y) * 1.35
                && (startsOnLeft(pan) ? movement.x > 0 : movement.x < 0)
                && (goesBack(pan) ? tab.canGoBack : tab.canGoForward)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            (other.view as? UIScrollView)?.panGestureRecognizer === other
        }

        @objc private func handleHistoryPan(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                historyGestureTab = browserTab
            case .ended:
                defer { historyGestureTab = nil }
                guard let tab = historyGestureTab, tab === browserTab else { return }
                let direction: CGFloat = startsOnLeft(pan) ? 1 : -1
                let advance = direction * pan.translation(in: view).x
                let speed = direction * pan.velocity(in: view).x
                guard advance >= 64 || (advance >= 24 && speed >= 550) else { return }
                if goesBack(pan) { tab.goBack() } else { tab.goForward() }
            case .cancelled, .failed:
                historyGestureTab = nil
            default:
                break
            }
        }
    }
}
