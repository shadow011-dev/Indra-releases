import AppKit
import SwiftUI

/// Keeps a list on its own axis. A vertical list only moves up and down; a horizontal strip only moves sideways.
/// A trackpad swipe that is a little diagonal used to drag the list sideways (or rubber-band it) as well.
///
/// SwiftUI draws a ScrollView with an NSScrollView. This finds that one and turns off the elastic bounce on the
/// other axis, and also puts the position back on that axis if anything still moves it.
private struct AxisLockedScroll: ViewModifier {
    let axis: Axis

    func body(content: Content) -> some View {
        content.background(AxisLockFinder(axis: axis))
    }
}

private struct AxisLockFinder: NSViewRepresentable {
    let axis: Axis

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.axis = axis
        return view
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.axis = axis
        view.attach()
    }

    final class FinderView: NSView {
        var axis: Axis = .vertical
        private weak var scroll: NSScrollView?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            // The list may not be in the window's view tree yet on the first pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attach() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach() {
            guard window != nil, let found = findScrollView() else { return }
            if scroll === found { apply(found); return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            scroll = found
            apply(found)
            found.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                              object: found.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdAxis() }
            }
        }

        private func apply(_ found: NSScrollView) {
            // A swipe that is only a little diagonal moves the list along its own axis and nothing else.
            found.usesPredominantAxisScrolling = true
            if axis == .vertical {
                found.horizontalScrollElasticity = .none
                found.hasHorizontalScroller = false
            } else {
                found.verticalScrollElasticity = .none
                found.hasVerticalScroller = false
            }
        }

        private func holdAxis() {
            guard let clip = scroll?.contentView else { return }
            var origin = clip.bounds.origin
            if axis == .vertical, origin.x != 0 { origin.x = 0 }
            else if axis == .horizontal, origin.y != 0 { origin.y = 0 }
            else { return }
            clip.scroll(to: origin)
            scroll?.reflectScrolledClipView(clip)
        }

        /// The scroll view this one was placed behind: the NSScrollView, near the same spot, that overlaps it most.
        private func findScrollView() -> NSScrollView? {
            var ancestor: NSView? = superview
            while let level = ancestor {
                var best: (NSScrollView, CGFloat)?
                collect(in: level) { candidate in
                    let mine = self.convert(self.bounds, to: nil)
                    let theirs = candidate.convert(candidate.bounds, to: nil)
                    let overlap = mine.intersection(theirs)
                    guard !overlap.isNull else { return }
                    let area = overlap.width * overlap.height
                    if area > (best?.1 ?? 0) { best = (candidate, area) }
                }
                if let best { return best.0 }
                ancestor = level.superview
            }
            return nil
        }

        private func collect(in view: NSView, _ visit: (NSScrollView) -> Void) {
            for sub in view.subviews {
                if let scroll = sub as? NSScrollView { visit(scroll) }
                collect(in: sub, visit)
            }
        }
    }
}

extension View {
    /// The list scrolls on `axis` only (see `AxisLockedScroll`).
    func lockScrollAxis(_ axis: Axis = .vertical) -> some View {
        modifier(AxisLockedScroll(axis: axis))
    }
}
