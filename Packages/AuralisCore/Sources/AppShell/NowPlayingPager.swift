// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
import SwiftUI

/// One horizontal scroll container for button navigation and interactive swipes. Its vertical
/// child scroll views retain their own native pan velocity and deceleration.
struct NowPlayingPager<Content: View>: View {
    @Binding var selection: NowPlayingPage
    let content: (NowPlayingPage) -> Content
#if DEBUG
    @State private var isAnimating = false
    @State private var observedAnimatedOffset = false
#endif

    init(selection: Binding<NowPlayingPage>, @ViewBuilder content: @escaping (NowPlayingPage) -> Content) {
        self._selection = selection; self.content = content
    }

    private var position: Binding<NowPlayingPage?> {
        .init(get: { selection }, set: { if let page = $0 { selection = page } })
    }

    var body: some View {
        let pager = ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(NowPlayingPage.allCases) { page in
                    content(page)
                        .containerRelativeFrame(.horizontal)
                        .frame(maxHeight: .infinity)
                        .id(page)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: position)
        .accessibilityIdentifier("auralis.nowPlaying.pages")
#if DEBUG
        if CommandLine.arguments.contains("-auralis-ui-smoke-page-motion") {
            pager
                .onScrollPhaseChange { _, phase in isAnimating = phase == .animating }
                .onScrollGeometryChange(for: Int.self) { geometry in
                    guard geometry.containerSize.width > 0 else { return 0 }
                    return Int((geometry.contentOffset.x / geometry.containerSize.width * 1_000).rounded())
                } action: { _, offset in
                    let fraction = abs(offset % 1_000)
                    if isAnimating, fraction > 40, fraction < 960 { observedAnimatedOffset = true }
                }
                .accessibilityValue(observedAnimatedOffset ? "animated-horizontal-offset" : "waiting")
        } else { pager }
#else
        pager
#endif
    }
}
#endif
