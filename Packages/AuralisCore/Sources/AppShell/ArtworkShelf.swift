// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import DesignSystem
import SwiftUI

/// Keep the viewport at the available window width. Only the scrollable
/// content gets an inset, so cards can travel all the way to either edge.
/// Parents must inset their headers separately rather than padding this view.
struct ArtworkShelf<Content: View>: View {
    var horizontalInset: CGFloat = AuralisSpacing.large
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
        }
        .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
        .frame(maxWidth: .infinity)
    }
}
