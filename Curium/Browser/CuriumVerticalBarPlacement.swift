import SwiftUI
import UIKit

enum CuriumVerticalBarPlacement: Equatable {
    case none, leading, trailing

    init(_ traits: UITraitCollection) {
        guard #available(iOS 27.1, *) else { self = .none; return }
        switch traits.verticalBarEdge {
        case .leading: self = .leading
        case .trailing: self = .trailing
        default: self = .none
        }
    }
}

struct CuriumVerticalBarReader: UIViewRepresentable {
    let onChange: (CuriumVerticalBarPlacement) -> Void

    func makeUIView(context: Context) -> Reader {
        let reader = Reader()
        reader.onChange = onChange
        return reader
    }

    func updateUIView(_ view: Reader, context: Context) {
        view.onChange = onChange
    }

    final class Reader: UIView {
        var onChange: ((CuriumVerticalBarPlacement) -> Void)?
        private var lastPlacement: CuriumVerticalBarPlacement?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                    (view: Reader, _: UITraitCollection) in view.publish()
                }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init().") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        private func publish() {
            guard window != nil else { return }
            let placement = CuriumVerticalBarPlacement(traitCollection)
            guard placement != lastPlacement else { return }
            lastPlacement = placement
            Task { @MainActor [weak self] in
                guard let self, self.lastPlacement == placement, self.window != nil else { return }
                self.onChange?(placement)
            }
        }
    }
}
