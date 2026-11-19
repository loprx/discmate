import AppKit
import SwiftUI

struct FloatingScrollView<Content: View>: View {
    let axes: Axis.Set
    @ViewBuilder let content: () -> Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.content = content
    }

    var body: some View {
        ScrollView(axes) {
            content().floatingScrollbars()
        }
    }
}

extension View {
    /// Attach to content inside a native SwiftUI Form or ScrollView.
    func floatingScrollbars() -> some View {
        background(ScrollBarAnchor().allowsHitTesting(false).accessibilityHidden(true))
    }
}

private struct ScrollBarAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.verticalScroller?.controlSize = .small
                scrollView.horizontalScroller?.controlSize = .small
                scrollView.autohidesScrollers = true
            }
        }
    }
}
