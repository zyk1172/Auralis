#if os(macOS)
import SwiftUI

/// Apple Music 式页面头：大标题 + 右侧少量主操作（Play / Shuffle 等）。
struct MacPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: MacUIVisualTokens.Typography.pageTitle, weight: .bold, design: .default))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) { trailing }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// Apple Music 式主操作按钮（Play / Shuffle）：系统 prominent 风格。
struct MacPrimaryButton: View {
    let title: String
    let systemImage: String
    var prominent = true
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominent {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}
#endif