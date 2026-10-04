// SPDX-License-Identifier: GPL-3.0-only
import AIKit
import SwiftUI

struct AICompatibilitySettingsFields: View {
    @AppStorage(AIConnectionSettings.Keys.anthropicReasoningDialect) private var dialect = AnthropicReasoningDialect.manual.rawValue
    @AppStorage(AIConnectionSettings.Keys.assumesImplicitStreamTermination) private var implicitTermination = false
    @AppStorage(AIConnectionSettings.Keys.implicitStreamTerminationScope) private var storedScope = ""

    private var settings: AIConnectionSettings { AIConnectionSettings() }

    var body: some View {
        Group {
            if settings.effectiveEndpointMode == .anthropicMessages {
                Picker(label("思考方式"), selection: $dialect) {
                    Text(label("固定思考预算")).tag(AnthropicReasoningDialect.manual.rawValue)
                    Text(label("自适应思考")).tag(AnthropicReasoningDialect.adaptive.rawValue)
                }
                Text(label("选择与你的模型兼容的思考方式。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(label("允许接口以连接结束表示完成"), isOn: $implicitTermination)
            Text(label("仅在服务明确采用此方式时启用；意外断开的响应也可能被视为完整结果。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { synchronizeScope() }
        .onChange(of: settings.endpointFingerprint) { _, _ in synchronizeScope() }
        .onChange(of: implicitTermination) { _, enabled in
            if enabled { storedScope = settings.endpointFingerprint }
        }
    }

    private func synchronizeScope() {
        if storedScope != settings.endpointFingerprint { implicitTermination = false }
    }

    private func label(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "AICompatibility", bundle: .module)
    }
}
