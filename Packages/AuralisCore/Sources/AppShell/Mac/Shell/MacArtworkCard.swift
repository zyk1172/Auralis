#if os(macOS)
import DesignSystem
import SwiftUI
import ThemeEngine

/// 右键 / 更多菜单的单个动作（新 UI 统一使用，避免散落业务逻辑）。
struct MacMenuAction: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String? = nil
    var destructive = false
    var disabled = false
    let action: () -> Void
}

/// Apple Music 式 Section 头：左标题 + 右「查看全部」。
struct MacSectionHeader: View {
    let title: String
    var actionTitle: String? = "查看全部"
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: MacLayout.sectionTitleSize, weight: .bold, design: .default))
            Spacer()
            if let onAction, let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.link)
                    .font(.body)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Apple Music 式 Artwork Card：Artwork + Title + Subtitle，hover 出现 Play / More。
/// 无 Card 底板、无发光、无重阴影。
struct MacArtworkCard: View {
    let title: String
    let subtitle: String?
    let artworkKey: String?
    let size: CGFloat
    let colors: ThemeColors
    var cornerRadius: CGFloat = MacLayout.artworkCornerRadius
    var onOpen: () -> Void = {}
    var onPlay: (() -> Void)? = nil
    var moreActions: [MacMenuAction] = []
    var showShadow = true

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            artwork
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(subtitle.map { "，\($0)" } ?? "")")
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            ArtworkView(
                title: title,
                artworkKey: artworkKey,
                colors: colors,
                size: size,
                cornerRadius: cornerRadius
            )
            .shadow(color: showShadow ? .black.opacity(0.14) : .clear, radius: 3, y: 1)
            .accessibilityHidden(true)

            if isHovering {
                HStack(spacing: 6) {
                    if let onPlay {
                        Button {
                            onPlay()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("播放")
                        .accessibilityLabel("播放")
                    }
                    if !moreActions.isEmpty {
                        Menu {
                            ForEach(moreActions) { action in
                                Button {
                                    action.action()
                                } label: {
                                    Label(action.title, systemImage: action.systemImage ?? "circle")
                                }
                                .disabled(action.disabled)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.thinMaterial, in: Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("更多操作")
                        .accessibilityLabel("更多操作")
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
    }
}
#endif
