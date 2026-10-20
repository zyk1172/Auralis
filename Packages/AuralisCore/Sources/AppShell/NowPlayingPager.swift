// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
import SwiftUI
#if DEBUG
import UIKit
#endif

/// One horizontal scroll container for button navigation and interactive swipes. Its vertical
/// child scroll views retain their own native pan velocity and deceleration.
struct NowPlayingPager<Content: View>: View {
    @Binding var selection: NowPlayingPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialPage: NowPlayingPage
    @State private var userIsScrolling = false
    @State private var nearestPage = NowPlayingPage.player
    let content: (NowPlayingPage) -> Content
#if DEBUG
    @State private var hasPageCommand = false
    @State private var observedAnimatedOffset = false
    @State private var sampledOffset = 0
    @State private var presentationOffset: Int?
    @State private var presentationSamples = 0
#endif

    init(selection: Binding<NowPlayingPage>, @ViewBuilder content: @escaping (NowPlayingPage) -> Content) {
        self._selection = selection
        self._initialPage = State(initialValue: selection.wrappedValue)
        self.content = content
    }

    private var initialAnchor: UnitPoint {
        switch initialPage {
        case .lyrics: .leading
        case .player: .center
        case .queue: .trailing
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                let pager = ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(NowPlayingPage.allCases, id: \.self) { page in
                            content(page)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .id(page)
                                .accessibilityHidden(page != selection)
                        }
                    }
                    .scrollTargetLayout()
#if DEBUG
                    .background {
                        if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                            PagerPresentationProbe(enabled: hasPageCommand && !observedAnimatedOffset) { offset in
                                presentationOffset = offset
                                presentationSamples += 1
                                let fraction = abs(offset % 1_000)
                                if hasPageCommand, fraction > 40, fraction < 960 { observedAnimatedOffset = true }
                            }
                            .allowsHitTesting(false)
                        }
                    }
#endif
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                // Initial layout owns its offset: an imperative task can run before the
                // landscape column has laid out its targets and leave the first page visible.
                .defaultScrollAnchor(initialAnchor, for: .initialOffset)
                // Commands flow one way. Binding the selected page directly to the visible
                // target lets intermediate scroll/layout updates write an old page back and
                // interrupt the button's animation, especially in the landscape column.
                .onChange(of: selection) { _, target in
#if DEBUG
                    hasPageCommand = true
#endif
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.34, extraBounce: 0)) {
                        proxy.scrollTo(target, anchor: .leading)
                    }
                }
                .onScrollGeometryChange(for: Int.self) { scroll in
                    guard scroll.containerSize.width > 0 else { return 0 }
                    return Int(((scroll.contentOffset.x + scroll.contentInsets.leading) / scroll.containerSize.width * 1_000).rounded())
                } action: { _, offset in
                    let pages = NowPlayingPage.allCases
                    let index = min(pages.count - 1, max(0, Int((Double(offset) / 1_000).rounded())))
                    nearestPage = pages[index]
#if DEBUG
                    if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                        sampledOffset = offset
                        let fraction = abs(offset % 1_000)
                        if hasPageCommand, fraction > 40, fraction < 960 { observedAnimatedOffset = true }
                    }
#endif
                }
                .onScrollPhaseChange { _, phase in
                    // Tracking also occurs when tapping an in-page navigation button
                    // or touching vertical lyrics. Only a real horizontal pan may
                    // write the visible page back or supersede a button command.
                    if phase == .interacting {
                        userIsScrolling = true
#if DEBUG
                        hasPageCommand = false
#endif
                    }
                    if phase == .idle, userIsScrolling {
                        selection = nearestPage
                        userIsScrolling = false
                    }
                }
                .accessibilityIdentifier("auralis.nowPlaying.pages")
#if DEBUG
                if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                    pager.accessibilityValue(observedAnimatedOffset ? "animated-horizontal-offset"
                        : "waiting-offset:\(sampledOffset),presentation:\(presentationOffset.map(String.init) ?? "none"),samples:\(presentationSamples)")
                } else { pager }
#else
                pager
#endif
            }
        }
    }
}

#if DEBUG
/// Geometry callbacks can coalesce a programmatic scroll to its model endpoint.
/// The smoke test also samples the native presentation bounds, so its existing
/// intermediate-offset assertion measures what is actually drawn. This probe
/// only runs for that test flag, for at most 1.5 seconds after a page command.
private struct PagerPresentationProbe: UIViewRepresentable {
    let enabled: Bool
    let onSample: @MainActor (Int) -> Void

    func makeUIView(context: Context) -> PagerPresentationView {
        let view = PagerPresentationView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: PagerPresentationView, context: Context) {
        uiView.onSample = onSample
        uiView.setEnabled(enabled)
    }

    static func dismantleUIView(_ uiView: PagerPresentationView, coordinator: ()) {
        uiView.stop()
    }
}

private final class PagerPresentationView: UIView {
    var onSample: (@MainActor (Int) -> Void)?
    private var requested = false
    private var deadline: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    func setEnabled(_ enabled: Bool) {
        guard requested != enabled else { return }
        requested = enabled
        if enabled { startIfVisible() } else { stop() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if requested { startIfVisible() }
    }

    private func startIfVisible() {
        guard window != nil, displayLink == nil else { return }
        deadline = CACurrentMediaTime() + 1.5
        let link = CADisplayLink(target: self, selector: #selector(sample(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func sample(_ link: CADisplayLink) {
        guard link.timestamp <= deadline else { stop(); return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.bounds.width > 0,
               scroll.contentSize.width > scroll.bounds.width * 1.5 {
                let bounds = scroll.layer.presentation()?.bounds ?? scroll.bounds
                let offset = (bounds.minX + scroll.adjustedContentInset.left) / scroll.bounds.width
                onSample?(Int((offset * 1_000).rounded()))
                return
            }
            ancestor = view.superview
        }
    }
}
#endif
#endif
