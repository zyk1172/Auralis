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
            _ = Task { @MainActor in
                guard !isUISmokeLaunch else { return }
                await AuralisAppModel.shared.prepareForApplicationLaunch()
            }

            // The static system launch screen has system-owned timing. Once
            // SwiftUI owns the first frame, keep this handoff deterministic:
            // 1.8s of solid artwork followed by a 0.2s fade. Restoration and
            // warm-up continue in `startup` without delaying or extending the
            // visual experience.
            try? await Task.sleep(for: .milliseconds(1_800))

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
            Color(red: 0.0, green: 0.53333, blue: 1.0)

            Image("LaunchAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            VStack(spacing: 8) {
                Spacer()
                Text("Auralis · 让你的音乐，只属于你")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("私人曲库 · 离线播放 · 隐私优先 AI")
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
