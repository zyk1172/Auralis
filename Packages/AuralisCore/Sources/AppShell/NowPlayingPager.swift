// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
import SwiftUI
#if DEBUG
import UIKit
#endif

/// One horizontal scroll container for button navigation and interactive swipes. Its vertical
/// child scroll views retain their own native pan velocity and deceleration.
/// Programmatic commands use an independent ScrollPosition value so SwiftUI
/// owns the animated offset without binding intermediate pages to selection.
struct NowPlayingPager<Content: View>: View {
    @Binding var selection: NowPlayingPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialPage: NowPlayingPage
    @State private var scrollPosition: ScrollPosition
    @State private var accessibilityPage: NowPlayingPage
    @State private var userIsScrolling = false
    let content: (NowPlayingPage) -> Content
#if DEBUG
    @State private var hasPageCommand = false
    @State private var observedAnimatedOffset = false
    @State private var sampledOffset = 0
    @State private var presentationSampler = PagerPresentationSampler()
    @State private var firstPresentationOffset: Int?
    @State private var presentationOffset: Int?
    @State private var presentationSamples = 0
    @State private var firstPresentationFrameDelay: Int?
#endif

    init(selection: Binding<NowPlayingPage>, @ViewBuilder content: @escaping (NowPlayingPage) -> Content) {
        self._selection = selection
        self._initialPage = State(initialValue: selection.wrappedValue)
        self._scrollPosition = State(initialValue: .init(id: selection.wrappedValue, anchor: .leading))
        self._accessibilityPage = State(initialValue: selection.wrappedValue)
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
            let pager = ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(NowPlayingPage.allCases, id: \.self) { page in
                        content(page)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(page)
                            .accessibilityHidden(page != accessibilityPage)
                    }
                }
                .scrollTargetLayout()
#if DEBUG
                .background {
                    if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                        PagerPresentationProbe(sampler: presentationSampler) { sample in
                            firstPresentationOffset = sample.first
                            firstPresentationFrameDelay = sample.firstFrameDelay
                            presentationOffset = sample.last
                            presentationSamples = sample.count
                            if sample.observedIntermediate { observedAnimatedOffset = true }
                        }
                        .allowsHitTesting(false)
                    }
                }
#endif
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition($scrollPosition)
            // Initial layout owns its offset: an imperative task can run before the
            // landscape column has laid out its targets and leave the first page visible.
            .defaultScrollAnchor(initialAnchor, for: .initialOffset)
            // Commands flow one way. Binding the selected page directly to the visible
            // target lets intermediate scroll/layout updates write an old page back and
            // interrupt the button's animation, especially in the landscape column.
            .onChange(of: selection) { _, target in
#if DEBUG
                hasPageCommand = true
                if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                    // Arm before scrollTo, not in a later SwiftUI render pass.
                    if let offset = presentationSampler.begin() {
                        firstPresentationOffset = offset
                        presentationOffset = offset
                    }
                }
#endif
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.34, extraBounce: 0)) {
                    scrollPosition.scrollTo(id: target, anchor: .leading)
                }
                if reduceMotion { accessibilityPage = target }
            }
#if DEBUG
            .onScrollGeometryChange(for: Int.self) { scroll in
                guard scroll.containerSize.width > 0 else { return 0 }
                return Int(((scroll.contentOffset.x + scroll.contentInsets.leading) / scroll.containerSize.width * 1_000).rounded())
            } action: { _, offset in
                if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                    let fraction = abs(offset % 1_000)
                    // Do not rebuild the page tree for every measured frame.
                    if fraction <= 5 || fraction >= 995 { sampledOffset = offset }
                    if hasPageCommand, !observedAnimatedOffset, fraction > 40, fraction < 960 { observedAnimatedOffset = true }
                }
            }
#endif
            .onScrollPhaseChange { _, phase, context in
                // Tracking also occurs when tapping an in-page navigation button
                // or touching vertical lyrics. Only a real horizontal pan may
                // write the visible page back or supersede a button command.
                if phase == .interacting {
                    userIsScrolling = true
#if DEBUG
                    hasPageCommand = false
                    presentationSampler.stop()
#endif
                }
                if phase == .idle {
                    let geometry = context.geometry
                    let width = geometry.containerSize.width
                    guard width > 0 else { return }
                    let offset = (geometry.contentOffset.x + geometry.contentInsets.leading) / width
                    let pages = NowPlayingPage.allCases
                    let visible = pages[min(pages.count - 1, max(0, Int(offset.rounded())))]
                    // Keep the initiating control accessible until it has
                    // actually left the viewport. Changing AX pages at command
                    // time can make focus reveal the target with an instant jump.
                    accessibilityPage = visible
                    if userIsScrolling {
                        selection = visible
                        userIsScrolling = false
                    }
                }
            }
            .accessibilityIdentifier("auralis.nowPlaying.pages")
#if DEBUG
            if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
                pager.accessibilityValue(observedAnimatedOffset ? "animated-horizontal-offset"
                    : "waiting-offset:\(sampledOffset),presentation:\(firstPresentationOffset.map(String.init) ?? "none")->\(presentationOffset.map(String.init) ?? "none"),samples:\(presentationSamples),first-frame-ms:\(firstPresentationFrameDelay.map(String.init) ?? "none")")
            } else { pager }
#else
            pager
#endif
        }
    }
}

#if DEBUG
/// Geometry callbacks can coalesce a programmatic scroll to its model endpoint.
/// The smoke test also samples the native presentation bounds, so its existing
/// intermediate-offset assertion measures what is actually drawn. This probe
/// only runs for that test flag, for at most 1.5 seconds after a page command.
private struct PagerPresentationProbe: UIViewRepresentable {
    let sampler: PagerPresentationSampler
    let onResult: @MainActor (PagerPresentationSample) -> Void

    func makeCoordinator() -> PagerPresentationSampler { sampler }

    func makeUIView(context: Context) -> PagerPresentationView {
        let view = PagerPresentationView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        sampler.onResult = onResult
        sampler.attach(view)
        return view
    }

    func updateUIView(_ uiView: PagerPresentationView, context: Context) {
        sampler.onResult = onResult
    }

    static func dismantleUIView(_ uiView: PagerPresentationView, coordinator: PagerPresentationSampler) {
        coordinator.detach(uiView)
    }
}

private struct PagerPresentationSample: Sendable {
    var first: Int?
    var last: Int?
    var count = 0
    var firstFrameDelay: Int?
    var observedIntermediate = false
}

@MainActor
private final class PagerPresentationSampler {
    private weak var view: PagerPresentationView?
    private var requested = false
    private var sample = PagerPresentationSample()
    var onResult: (@MainActor (PagerPresentationSample) -> Void)?

    func attach(_ view: PagerPresentationView) {
        self.view = view
        view.onSample = { [weak self] offset, elapsed in self?.record(offset, elapsed: elapsed) }
        if requested { view.begin() }
    }

    func detach(_ view: PagerPresentationView) {
        view.stop()
        view.onSample = nil
        guard self.view === view else { return }
        self.view = nil
        requested = false
        onResult = nil
    }

    func begin() -> Int? {
        requested = true
        sample = PagerPresentationSample(first: view?.currentOffset())
        view?.begin()
        return sample.first
    }
    func stop() { requested = false; view?.stop() }

    private func record(_ offset: Int?, elapsed: Int) {
        guard requested else { return }
        sample.count += 1
        if sample.first == nil { sample.first = offset }
        sample.last = offset
        if sample.firstFrameDelay == nil { sample.firstFrameDelay = elapsed }
        if let offset {
            let fraction = abs(offset % 1_000)
            sample.observedIntermediate = fraction > 40 && fraction < 960
        }
        if sample.observedIntermediate || elapsed >= 1_500 {
            stop()
            // Publish once: per-frame @State writes would themselves rebuild
            // the SwiftUI page tree and disturb the animation being measured.
            onResult?(sample)
        }
    }
}

private final class PagerPresentationView: UIView {
    var onSample: (@MainActor (Int?, Int) -> Void)?
    private var requested = false
    private var deadline: CFTimeInterval = 0
    private var commandStartedAt: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    func begin() {
        requested = true
        commandStartedAt = CACurrentMediaTime()
        startIfVisible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else if requested { startIfVisible() }
    }

    private func startIfVisible() {
        guard window != nil, displayLink == nil else { return }
        deadline = commandStartedAt + 1.5
        let link = CADisplayLink(target: self, selector: #selector(sample(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        requested = false
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func sample(_ link: CADisplayLink) {
        onSample?(currentOffset(), Int(max(0, (link.timestamp - commandStartedAt) * 1_000)))
        if link.timestamp > deadline { stop() }
    }

    func currentOffset() -> Int? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.bounds.width > 0,
               scroll.contentSize.width > scroll.bounds.width * 1.5 {
                let viewport = scroll.layer.presentation() ?? scroll.layer
                let content = layer.presentation() ?? layer
                let leading = viewport.convert(.zero, from: content).x
                let offset = (viewport.bounds.minX - leading + scroll.adjustedContentInset.left) / scroll.bounds.width
                return Int((offset * 1_000).rounded())
            }
            ancestor = view.superview
        }
        return nil
    }
}
#endif
#endif
