import DesignSystem
import Observability
import SwiftUI
import ThemeEngine

/// 崩溃日志查看页面：显示上次崩溃的日志信息。
struct CrashLogView: View {
    let theme: BuiltInTheme
    @State private var crashLog: String?
    @State private var showingClearAlert = false

    var body: some View {
        ScrollView {
            if let log = crashLog {
                VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
                    Text("上次崩溃日志")
                        .font(.headline)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text(log)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                        .textSelection(.enabled)
                        .padding()
                        .background(theme.colorTokens.surface.color)
                        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                    HStack {
                        Button("复制日志") {
                            #if os(iOS)
                            UIPasteboard.general.string = log
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(log, forType: .string)
                            #endif
                        }
                        .buttonStyle(HapticButtonStyle())
                        Spacer()
                        Button("清除日志", role: .destructive) {
                            showingClearAlert = true
                        }
                        .buttonStyle(HapticButtonStyle())
                    }
                }
                .padding()
            } else {
                VStack(spacing: AuralisSpacing.medium) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(theme.colorTokens.success.color)
                    Text("没有崩溃日志")
                        .font(.headline)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("上次启动没有发生崩溃。")
                        .font(.subheadline)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(theme.colorTokens.background.color)
        .navigationTitle("崩溃日志")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            crashLog = CrashLog.shared.readLastCrashLog()
        }
        .alert("确认清除", isPresented: $showingClearAlert) {
            Button("清除", role: .destructive) {
                CrashLog.shared.clearCrashLog()
                crashLog = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要清除崩溃日志吗？")
        }
    }
}
