import AppShell
import Foundation
import SwiftUI

private final class LaunchStartupDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

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

            if isPresented {
                LaunchOverlay()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            let startup = Task { @MainActor in
                guard !isUISmokeLaunch else { return }
                await AuralisAppModel.shared.prepareForApplicationLaunch()
            }

            // Keep the handoff from the static launch screen intentional, even
            // when local restoration is already warm.  The deadline gate is a
            // hard cap so a slow server or damaged cache never holds the app
            // behind the launch artwork.
            try? await Task.sleep(for: .milliseconds(380))
            await waitForStartupOrDeadline(startup)

            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                isPresented = false
            }
        }
        .accessibilityIdentifier("auralis.launch.experience")
    }

    private func waitForStartupOrDeadline(_ startup: Task<Void, Never>) async {
        let gate = LaunchStartupDeadlineGate()
        Task { @MainActor [gate] in
            await startup.value
            gate.finish()
        }
        let deadline = Task { @MainActor [gate] in
            do {
                try await Task.sleep(for: .milliseconds(820))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            gate.finish()
        }
        await withTaskCancellationHandler(operation: {
            await gate.wait()
        }, onCancel: {
            gate.finish()
        })
        deadline.cancel()
    }
}

private struct LaunchOverlay: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.533, blue: 1.0),
                    Color(red: 0.0, green: 0.498, blue: 0.949),
                    Color(red: 0.0, green: 0.435, blue: 0.847),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 58, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)

                Text("Auralis")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Auralis · 让你的音乐，只属于你")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.96))

                Text("私人曲库 · 离线播放 · 隐私优先 AI")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("auralis.launch.overlay")
    }
}
