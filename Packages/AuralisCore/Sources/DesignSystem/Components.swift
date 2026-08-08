import SwiftUI

public struct AuralisArtwork: View {
    private let title: String
    private let colors: ThemeColors
    private let size: CGFloat
    private let cornerRadius: CGFloat

    public init(title: String, colors: ThemeColors, size: CGFloat, cornerRadius: CGFloat = AuralisRadius.artwork) {
        self.title = title
        self.colors = colors
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [colors.accent.color, colors.accentSecondary.color, colors.background.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(colors.primaryText.color.opacity(0.12))
                .frame(width: size * 0.78)
                .offset(x: size * 0.36, y: -size * 0.28)
            Text(monogram)
                .font(.system(size: max(18, size * 0.19), weight: .bold, design: .rounded))
                .foregroundStyle(colors.primaryText.color.opacity(0.88))
                .padding(size * 0.1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel("\(title) 封面")
    }

    private var monogram: String {
        String(title.prefix(2)).uppercased()
    }
}

public struct AuralisPill: View {
    private let title: String
    private let colors: ThemeColors
    private let systemImage: String?

    public init(_ title: String, systemImage: String? = nil, colors: ThemeColors) {
        self.title = title
        self.systemImage = systemImage
        self.colors = colors
    }

    public var body: some View {
        HStack(spacing: AuralisSpacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(colors.primaryText.color)
        .padding(.horizontal, AuralisSpacing.medium)
        .padding(.vertical, AuralisSpacing.small)
        .background(colors.surface.color)
        .clipShape(Capsule())
    }
}

public struct AuralisEmptyState: View {
    private let icon: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let colors: ThemeColors
    private let action: (() -> Void)?

    public init(icon: String, title: String, message: String, actionTitle: String? = nil, colors: ThemeColors, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.colors = colors
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(HapticProminentButtonStyle())
                    .tint(colors.accent.color)
            }
        }
    }
}
