// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
import SwiftUI

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
                    if phase == .tracking || phase == .interacting {
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
                    pager.accessibilityValue(observedAnimatedOffset ? "animated-horizontal-offset" : "waiting-offset:\(sampledOffset)")
                } else { pager }
#else
                pager
#endif
            }
        }
    }
}
#endif
