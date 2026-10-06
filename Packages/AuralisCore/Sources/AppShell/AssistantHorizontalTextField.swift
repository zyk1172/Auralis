// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftUI

/// Single-line assistant composer that keeps the compact layout and relies on
/// TextField's native caret scrolling for drafts wider than the visible input area.
struct AssistantHorizontalTextField: View {
    @Binding var text: String
    let prompt: String
    let focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        // Single-line TextField already scrolls its caret horizontally. The former
        // nested horizontal ScrollView forced the trailing anchor after every edit;
        // at the left edge that could leave the first glyph outside the viewport.
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .focused(focus)
            .onSubmit(onSubmit)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .accessibilityIdentifier("assistant.input.horizontal-scroll")
    }
}
