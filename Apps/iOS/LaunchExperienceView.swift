import AppShell
import Foundation
import SwiftUI

/// Keeps the first SwiftUI frame visually continuous with the static system
/// launch screen while local state restoration happens in the background.
struct LaunchExperienceView: View {
    @State private var isPresented = true

    private var isUISmokeLaunch: Bool {
        let arguments = Set(CommandLine.arguments)
        return arguments.contains("-auralis-ui-smoke")
            || arguments.contains("-auralis-ui-smoke-now-playing")
            || arguments.contains("-auralis-ui-smoke-assistant")
            || arguments.contains("-auralis-ui-smoke-dock-home")
            || arguments.contains("-auralis-ui-smoke-dock-library")
            || arguments.contains("-auralis-ui-smoke-dock-clearance-home")
            || arguments.contains("-auralis-ui-smoke-dock-clearance-library")
    }

    var body: some View {
        ZStack {
            AuralisRootView()

            if isPresented && !isUISmokeLaunch {
                LaunchOverlay()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            guard !isUISmokeLaunch else { return }

            // The static storyboard owns the first system frame. Once
            // SwiftUI takes over, keep the same artwork visible until both
            // the minimum display interval and the process-wide critical
            // launch restoration have completed. Catalog refresh remains in
            // the scene-active background path and is not part of this gate.
            async let startup: Void = AuralisAppModel.shared.prepareForApplicationLaunch()
            async let minimumDuration: Void = Task.sleep(for: .seconds(2))

            do {
                try await minimumDuration
            } catch {
                return
            }
            await startup

            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                isPresented = false
            }
        }
        .accessibilityIdentifier("auralis.launch.experience")
    }
}

private struct LaunchOverlay: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")

            GeometryReader { geometry in
                Image("LaunchGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    // Match LaunchScreen.storyboard: centerY is 0.8 of the
                    // view center, i.e. 40% of the full screen height.
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height * 0.40
                    )
            }

            VStack(spacing: 8) {
                Spacer()
                Text(String(localized: "Auralis · 让你的音乐，只属于你"))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(String(localized: "私人曲库 · 离线播放 · 隐私优先 AI"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 54)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("auralis.launch.overlay")
    }
}
