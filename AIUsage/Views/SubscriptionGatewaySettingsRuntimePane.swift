import SwiftUI

// MARK: - CPA Runtime 设置
// 主界面：常规 / 选号策略 / 网络。
// 高级：对齐 CPA config.example 的 request-retry / max-retry-interval / max-retry-credentials。
// 订阅与 CPA 账号池彼此独立，不在此做隐藏联动。

struct SubscriptionGatewaySettingsRuntimePane: View {
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var draftSettings: CLIProxyGatewaySettings
    let onApply: () -> Void

    @State private var showAdvanced = false

    private var hasUnappliedChanges: Bool {
        draftSettings.normalized != runtime.settings.normalized
    }

    private var needsRestart: Bool {
        draftSettings.requiresCPAProcessRestart(comparedTo: runtime.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    GatewayCard(padding: 0) {
                        VStack(spacing: 0) {
                            groupLabel(L("General", "常规"))
                            compactToggle(L("Launch with app", "随应用启动"), isOn: $draftSettings.autoStart)
                            rowDivider
                            compactPortRow
                            rowDivider
                            compactToggle(L("LAN access", "局域网访问"), isOn: $draftSettings.allowLANAccess)
                            if draftSettings.allowLANAccess {
                                lanHint.padding(.horizontal, 14).padding(.bottom, 12)
                            }
                        }
                    }

                    GatewayCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            groupLabel(L("Account picking", "账号选择"))
                            compactPickerRow
                            Text(L(
                                "Fill first keeps using one available account until it cools down, then moves on. Round robin spreads requests.",
                                "优先用满：一直打同一个可用号，额度冷却后再换下一个。轮询：请求分散到各账号。"
                            ))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        }
                    }

                    GatewayCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            groupLabel(L("Health check", "健康检查"))
                            compactToggle(
                                L("Auto refresh account status", "自动刷新账号状态"),
                                isOn: $draftSettings.accountModelProbeEnabled
                            )
                            if draftSettings.accountModelProbeEnabled {
                                rowDivider
                                advancedNumberRow(
                                    title: L("Every (sec)", "每隔（秒）"),
                                    subtitle: L(
                                        "Updates cooling flags and credential reachability",
                                        "更新冷却标记与凭据是否可达"
                                    ),
                                    value: $draftSettings.accountModelProbeIntervalSeconds,
                                    range: 15...3600,
                                    placeholder: "60"
                                )
                            } else {
                                Text(L(
                                    "Manual only · use Check all in Accounts.",
                                    "仅手动 · 在账号页使用「检测全部」。"
                                ))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                            }
                        }
                    }

                    GatewayCard(padding: 0) {
                        VStack(spacing: 0) {
                            groupLabel(L("Network", "网络"))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Upstream proxy", "上游代理"))
                                    .font(.subheadline.weight(.medium))
                                TextField("http://127.0.0.1:7890", text: $draftSettings.proxyURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout.monospaced())
                            }
                            .padding(14)
                            rowDivider
                            compactToggle(L("Official plugins", "官方插件"), isOn: $draftSettings.enablePlugins)
                        }
                    }

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(spacing: 0) {
                            advancedNumberRow(
                                title: L("max-retry-credentials", "max-retry-credentials"),
                                subtitle: L(
                                    "Max accounts to try in one round · 0 = all",
                                    "一轮里最多试几个账号 · 0 = 全部可用"
                                ),
                                value: $draftSettings.maxRetryCredentials,
                                range: 0...64,
                                placeholder: "0"
                            )
                            rowDivider
                            advancedNumberRow(
                                title: L("request-retry", "request-retry"),
                                subtitle: L(
                                    "Max cooldown-wait rounds after accounts are busy",
                                    "账号都忙时，最多再等几轮冷却后重试"
                                ),
                                value: $draftSettings.requestRetry,
                                range: 0...10,
                                placeholder: "3"
                            )
                            rowDivider
                            advancedNumberRow(
                                title: L("max-retry-interval", "max-retry-interval"),
                                subtitle: L(
                                    "Max seconds for each cooldown wait · not total request time",
                                    "每一次等冷却最多几秒 · 不是整次请求总时长"
                                ),
                                value: $draftSettings.maxRetryInterval,
                                range: 1...300,
                                placeholder: "30"
                            )
                        }
                    } label: {
                        Text(L("Advanced", "高级"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 28)
                }
            }

            if hasUnappliedChanges {
                stickyApplyBar
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Runtime", "运行"))
                .font(.title3.weight(.semibold))
            if hasUnappliedChanges {
                GatewayQuietBadge(
                    text: needsRestart ? L("Restart needed", "需重启") : L("Unsaved", "未保存"),
                    tint: .orange
                )
            }
            Spacer()
        }
    }

    private var stickyApplyBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(L("Reset", "还原")) { draftSettings = runtime.settings }
                    .buttonStyle(.borderless)
                Spacer()
                if needsRestart, runtime.state.isRunning {
                    Text(L("CPA will restart", "将重启 CPA"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(action: onApply) {
                    Label(
                        applyButtonTitle,
                        systemImage: needsRestart && runtime.state.isRunning
                            ? "arrow.triangle.2.circlepath"
                            : "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runtime.state.isTransitioning)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var applyButtonTitle: String {
        if needsRestart, runtime.state.isRunning {
            return L("Apply & Restart", "应用并重启")
        }
        return L("Apply", "应用")
    }

    private var compactPortRow: some View {
        HStack {
            Text(L("Port", "端口"))
                .font(.subheadline.weight(.medium))
            Spacer()
            TextField(
                "14420",
                value: $draftSettings.port,
                format: IntegerFormatStyle<Int>.number.grouping(.never)
            )
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 88)
            .font(.body.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var compactPickerRow: some View {
        HStack {
            Text(L("Strategy", "策略"))
                .font(.subheadline.weight(.medium))
            Spacer()
            Picker("", selection: $draftSettings.routingStrategy) {
                Text(L("Round robin", "轮询")).tag(CLIProxyRoutingStrategy.roundRobin)
                Text(L("Fill first", "优先用满")).tag(CLIProxyRoutingStrategy.fillFirst)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func advancedNumberRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        placeholder: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium).monospaced())
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            TextField(
                placeholder,
                value: value,
                format: IntegerFormatStyle<Int>.number.grouping(.never)
            )
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .font(.body.monospacedDigit())
            .onChange(of: value.wrappedValue) { _, newValue in
                value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    private var lanHint: some View {
        let addresses = runtime.detectedLANBaseURLs(port: draftSettings.normalized.port)
        return VStack(alignment: .leading, spacing: 3) {
            if addresses.isEmpty {
                Text(L("No private IPv4 detected.", "未检测到私有 IPv4。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addresses, id: \.absoluteString) { address in
                    Text(address.absoluteString)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}
