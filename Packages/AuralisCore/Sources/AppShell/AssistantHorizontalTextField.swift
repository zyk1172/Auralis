// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Single-line assistant composer that keeps the existing compact layout while allowing
/// direct horizontal swipes when the draft is wider than the visible input area.
struct AssistantHorizontalTextField: View {
    private static let trailingEdgeID = "assistant-input-trailing-edge"

    @Binding var text: String
    let prompt: String
    let focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        TextField(prompt, text: $text)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .onSubmit(onSubmit)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: geometry.size.width, alignment: .leading)

                        Color.clear
                            .frame(width: 1, height: 1)
                            .id(Self.trailingEdgeID)
                    }
                }
                .onChange(of: text) { _, _ in
                    guard focus.wrappedValue else { return }
                    proxy.scrollTo(Self.trailingEdgeID, anchor: .trailing)
                }
                .onChange(of: focus.wrappedValue) { _, isFocused in
                    guard isFocused else { return }
                    proxy.scrollTo(Self.trailingEdgeID, anchor: .trailing)
                }
            }
        }
        .frame(height: 24)
        .accessibilityIdentifier("assistant.input.horizontal-scroll")
    }
}
