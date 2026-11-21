import CuriumEngineContract
import SwiftUI
import UIKit

/// Mounts the active tab's Blink view and connects it to the address bar.
///
/// With compositor top controls, Blink moves the page under a fixed band and reports
/// how much of it is shown; this host forwards that as the tab's chrome collapse.
/// Without them, the page sits below the band and the bar stays full.
struct CuriumBlinkViewportHost: UIViewControllerRepresentable {
    let tab: CuriumTabModel?
    let restingTopInset: CGFloat
    let viewportSize: CGSize
    let standby: CuriumStandbyPage
    let scheduleSnapshot: (CuriumTabModel) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(
            tab: tab, restingTopInset: restingTopInset, viewportSize: viewportSize, standby: standby,
            scheduleSnapshot: scheduleSnapshot
        )
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.teardown()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private typealias CompositorControls = NSObject & CrIOSTabBrowserControlsV1
        private static let shownRatioKey = #keyPath(CrIOSTabBrowserControlsV1.topControlsShownRatio)
        /// Scroll distance after which a pinned bar yields to the page again.
        private static let unpinTravel: CGFloat = 24

        private weak var browserTab: CuriumTabModel?
        private var mountedTabID: String?
        private weak var mountedEngine: (any CrIOSTabHostingV1)?
        private weak var historyGestureTab: CuriumTabModel?
        private var standbyController: UIHostingController<CuriumStandbyPage>?
        private weak var mountedView: UIView?
        private weak var scrollView: UIScrollView?
        private var backgroundObservation: NSKeyValueObservation?
        private var scrollObservation: NSKeyValueObservation?
        private var compositorControls: CompositorControls?
        private var pinnedScrollY: CGFloat?
        private var mountGeneration = 0
        private var restingTopInset: CGFloat = 0
        private var viewportSize: CGSize = .zero
        private var originalInsets: UIEdgeInsets = .zero
        private var originalIndicatorInsets: UIEdgeInsets = .zero
        private var originalAdjustment: UIScrollView.ContentInsetAdjustmentBehavior = .automatic
        private var originalAutomaticIndicators = true

        override func loadView() {
            let container = UIView()
            container.backgroundColor = .clear
            container.clipsToBounds = true
            view = container

            let historyPan = UIPanGestureRecognizer(target: self, action: #selector(handleHistoryPan))
            historyPan.maximumNumberOfTouches = 1
            historyPan.cancelsTouchesInView = false
            historyPan.delaysTouchesEnded = false
            historyPan.delegate = self
            view.addGestureRecognizer(historyPan)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            syncViewportGeometry()
        }

        func update(
            tab: CuriumTabModel?, restingTopInset: CGFloat, viewportSize: CGSize, standby: CuriumStandbyPage,
            scheduleSnapshot: (CuriumTabModel) -> Void
        ) {
            browserTab = tab
            self.restingTopInset = restingTopInset
            self.viewportSize = viewportSize

            guard let tab, let engine = tab.engine, let webView = tab.webView else {
                if mountedTabID != nil { unmount() }
                self.restingTopInset = 0
                showStandby(standby)
                return
            }
            showStandby(nil)
            let remounted = mountedTabID != tab.id || mountedEngine !== engine
                || mountedView !== webView || scrollView !== tab.scrollView
            if remounted {
                mountedTabID = tab.id
                mountedEngine = engine
                mount(webView, scrollView: tab.scrollView, engine: engine)
                scheduleSnapshot(tab)
            }
            syncViewportGeometry()
        }

        func teardown() {
            unmount()
            showStandby(nil)
        }

        private func unmount() {
            mountedTabID = nil
            mountedEngine = nil
            mount(nil, scrollView: nil, engine: nil)
        }

        private func showStandby(_ content: CuriumStandbyPage?) {
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

        private func mount(
            _ webView: UIView?, scrollView newScrollView: UIScrollView?, engine: (any CrIOSTabHostingV1)?
        ) {
            mountGeneration += 1
            historyGestureTab = nil
            pinnedScrollY = nil
            backgroundObservation?.invalidate()
            backgroundObservation = nil
            scrollObservation?.invalidate()
            scrollObservation = nil
            compositorControls?.removeObserver(self, forKeyPath: Self.shownRatioKey)
            compositorControls = nil
            if let controls = engine as? CompositorControls,
               controls.responds(to: #selector(getter: CrIOSTabBrowserControlsV1.topControlsHeight)),
               controls.responds(to: #selector(setter: CrIOSTabBrowserControlsV1.topControlsHeight)),
               controls.responds(to: #selector(getter: CrIOSTabBrowserControlsV1.topControlsShownRatio)) {
                compositorControls = controls
            }
            if mountedView !== webView {
                mountedView?.removeFromSuperview()
                mountedView = webView
                if let webView {
                    webView.autoresizingMask = []
                    webView.translatesAutoresizingMaskIntoConstraints = true
                    webView.frame = view.bounds
                    view.addSubview(webView)
                }
            }
            if let previous = scrollView {
                previous.contentInset = originalInsets
                previous.verticalScrollIndicatorInsets = originalIndicatorInsets
                previous.contentInsetAdjustmentBehavior = originalAdjustment
                previous.automaticallyAdjustsScrollIndicatorInsets = originalAutomaticIndicators
            }
            scrollView = newScrollView
            if let newScrollView {
                originalInsets = newScrollView.contentInset
                originalIndicatorInsets = newScrollView.verticalScrollIndicatorInsets
                originalAdjustment = newScrollView.contentInsetAdjustmentBehavior
                originalAutomaticIndicators = newScrollView.automaticallyAdjustsScrollIndicatorInsets
                backgroundObservation = newScrollView.observe(\.backgroundColor, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.browserTab?.syncScrollCanvasColor()
                    }
                }
                scrollObservation = newScrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated {
                        self?.releasePinIfScrolled(scrollView)
                    }
                }
            }
            if let controls = compositorControls {
                controls.addObserver(self, forKeyPath: Self.shownRatioKey, options: [.new], context: nil)
            }
            // Mounting runs inside a SwiftUI update; publish the first state after it.
            let generation = mountGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mountGeneration == generation else { return }
                self.reportCollapse()
            }
        }

        nonisolated override func observeValue(
            forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            let handled = MainActor.assumeIsolated {
                guard keyPath == Self.shownRatioKey else { return false }
                self.reportCollapse()
                return true
            }
            if !handled {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
        }

        /// Forwards Blink's shown fraction, every frame it changes, as the tab's collapse.
        private func reportCollapse() {
            guard let tab = browserTab, tab.engine === mountedEngine else { return }
            let collapse = compositorControls.map { 1 - $0.topControlsShownRatio }
            tab.reportChromeCollapse(collapse)
            if tab.chrome.pinnedOpen, pinnedScrollY == nil {
                pinnedScrollY = scrollView?.contentOffset.y
            } else if !tab.chrome.pinnedOpen {
                pinnedScrollY = nil
            }
        }

        /// A bar the reader pinned open yields once they scroll on.
        private func releasePinIfScrolled(_ scrollView: UIScrollView) {
            guard let tab = browserTab, tab.chrome.pinnedOpen else {
                pinnedScrollY = nil
                return
            }
            guard let start = pinnedScrollY else {
                pinnedScrollY = scrollView.contentOffset.y
                return
            }
            if abs(scrollView.contentOffset.y - start) > Self.unpinTravel {
                pinnedScrollY = nil
                tab.unpinChrome(.scrolled)
            }
        }

        /// Only Blink scrolls. With compositor controls the page fills the view and Blink
        /// offsets it by the band; otherwise the page view starts below the band.
        private func syncViewportGeometry() {
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0, let mountedView else { return }
            let scale = max(1, traitCollection.displayScale)
            let band = (max(0, min(restingTopInset, bounds.height * 0.25)) * scale).rounded() / scale
            let top: CGFloat = compositorControls == nil && browserTab?.isFullscreen != true ? band : 0
            let frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
            if mountedView.frame != frame { mountedView.frame = frame }
            syncScrollInsets()
            if let controls = compositorControls, controls.topControlsHeight != band {
                controls.topControlsHeight = band
            }
        }

        private func syncScrollInsets() {
            guard let scrollView else { return }
            guard scrollView.contentInsetAdjustmentBehavior != .never || scrollView.automaticallyAdjustsScrollIndicatorInsets
                    || scrollView.contentInset != .zero || scrollView.verticalScrollIndicatorInsets.top != 0
                    || scrollView.verticalScrollIndicatorInsets.bottom != 0 else { return }
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.automaticallyAdjustsScrollIndicatorInsets = false
            scrollView.contentInset = .zero
            scrollView.verticalScrollIndicatorInsets.top = 0
            scrollView.verticalScrollIndicatorInsets.bottom = 0
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
