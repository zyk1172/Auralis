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
                    Text(String(localized: "上次崩溃日志", bundle: .module))
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
                        Button(String(localized: "复制日志", bundle: .module)) {
                            #if os(iOS)
                            UIPasteboard.general.string = log
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(log, forType: .string)
                            #endif
                        }
                        .buttonStyle(HapticButtonStyle())
                        Spacer()
                        Button(String(localized: "清除日志", bundle: .module), role: .destructive) {
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
                    Text(String(localized: "没有崩溃日志", bundle: .module))
                        .font(.headline)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text(String(localized: "上次启动没有发生崩溃。", bundle: .module))
                        .font(.subheadline)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(theme.colorTokens.background.color)
        .navigationTitle(String(localized: "崩溃日志", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            crashLog = CrashLog.shared.readLastCrashLog()
        }
        .alert(String(localized: "确认清除", bundle: .module), isPresented: $showingClearAlert) {
            Button(String(localized: "清除", bundle: .module), role: .destructive) {
                CrashLog.shared.clearCrashLog()
                crashLog = nil
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "确定要清除崩溃日志吗？", bundle: .module))
        }
    }
}