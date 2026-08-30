import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var powerManager: PowerManager
    @State private var isShowingSettings = false
    @State private var isShowingLidConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            protectionCard
            policyCard
            lidCard
            footer
        }
        .padding(20)
        .frame(width: 440)
        .sheet(isPresented: $isShowingSettings) {
            SleepSettingsSheet(powerManager: powerManager)
        }
        .alert("开启实验性合盖运行？", isPresented: $isShowingLidConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开启 4 小时") {
                Task { await powerManager.enableLidProtection() }
            }
        } message: {
            Text("仅限接入电源适配器时使用。合盖会降低散热，请保持通风，切勿放入包中。后台组件会在 4 小时、断电、过热或 AIAwake 失联时自动恢复系统设置。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: powerManager.isAnyProtectionEnabled ? "infinity.circle.fill" : "infinity.circle")
                .font(.system(size: 28))
                .foregroundStyle(powerManager.isAnyProtectionEnabled ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Awake")
                    .font(.title2.weight(.semibold))
                Text("让本地 AI 任务持续运行")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(powerManager.isAnyProtectionEnabled ? "保护中" : "未保护")
                .font(.callout.weight(.medium))
                .foregroundStyle(powerManager.isAnyProtectionEnabled ? Color.green : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    private var protectionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    isOn: Binding(
                        get: { powerManager.isProtectionEnabled },
                        set: { powerManager.setProtectionEnabled($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 运行保护")
                            .font(.headline)
                        Text("阻止系统因空闲而休眠")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(
                    "同时保持显示器点亮",
                    isOn: Binding(
                        get: { powerManager.keepDisplayAwake },
                        set: { powerManager.setKeepDisplayAwake($0) }
                    )
                )
                .toggleStyle(.switch)
                .disabled(powerManager.isLidProtectionEnabled)
                .disabled(!powerManager.isProtectionEnabled)

                if let startedAt = powerManager.protectionStartedAt {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                        Text("已持续")
                        Text(startedAt, style: .timer)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var policyCard: some View {
        GroupBox("当前休眠策略") {
            if let snapshot = powerManager.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    policyRow(
                        icon: "powerplug",
                        title: "当前供电",
                        value: snapshot.source.displayName
                    )
                    policyRow(
                        icon: "moon.zzz",
                        title: "电脑休眠",
                        value: durationText(snapshot.systemSleepMinutes)
                    )
                    policyRow(
                        icon: "display",
                        title: "显示器关闭",
                        value: durationText(snapshot.displaySleepMinutes)
                    )
                }
                .padding(.top, 4)
            } else if powerManager.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                Text("暂时无法读取休眠策略。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var lidCard: some View {
        if let snapshot = powerManager.snapshot {
            GroupBox("MacBook 盖子") {
                if snapshot.supportsClamshell {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("当前状态", systemImage: "laptopcomputer")
                            Spacer()
                            Text(lidStateText(snapshot.lidOpen))
                                .foregroundStyle(.secondary)
                        }

                        if let lidWakeEnabled = snapshot.lidWakeEnabled {
                            HStack {
                                Label("开盖自动唤醒", systemImage: "sunrise")
                                Spacer()
                                Text(lidWakeEnabled ? "开启" : "关闭")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        Toggle(
                            isOn: Binding(
                                get: { powerManager.isLidProtectionEnabled },
                                set: { enabled in
                                    if enabled {
                                        isShowingLidConfirmation = true
                                    } else {
                                        powerManager.setLidProtectionEnabled(false)
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("合盖继续运行")
                                        .font(.headline)
                                    Text("实验性")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.orange.opacity(0.12), in: Capsule())
                                }
                                Text("仅接电、最长 4 小时；需要系统后台组件")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(
                            powerManager.isLidProtectionApplying
                                || (!powerManager.isLidProtectionEnabled && snapshot.source != .ac)
                                || powerManager.hasUnownedSleepDisabledOverride
                                || powerManager.lidProtectionRecoveryRequired
                        )

                        if powerManager.isLidProtectionApplying {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在验证系统状态…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let expiresAt = powerManager.lidProtectionExpiresAt {
                            Label {
                                Text("将在 ") + Text(expiresAt, style: .relative) + Text("自动停止")
                            } icon: {
                                Image(systemName: "timer")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }

                        if powerManager.lidHelperRegistrationStatus.needsSystemApproval {
                            Button("打开“登录项与扩展”…") {
                                powerManager.openLidHelperApprovalSettings()
                            }
                            .controlSize(.small)
                        }

                        if powerManager.lidProtectionRecoveryRequired {
                            Label(
                                "SleepDisabled 仍为 1。请重新批准后台组件，或执行 sudo pmset -a disablesleep 0。",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                        } else if powerManager.hasUnownedSleepDisabledOverride {
                            Label(
                                "SleepDisabled 已由其他工具开启；AIAwake 不会接管或关闭它。",
                                systemImage: "exclamationmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            Label(
                                powerManager.isLidProtectionEnabled
                                    ? "合盖会降低散热；保持通风，切勿放入包中。"
                                    : "普通 AI 运行保护不能阻止合盖休眠。",
                                systemImage: powerManager.isLidProtectionEnabled
                                    ? "exclamationmark.triangle"
                                    : "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Label("这台 Mac 没有可管理的内置屏幕盖。", systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lastError = powerManager.lastError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(lastError)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        powerManager.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭错误提示")
                }
                .font(.callout)
                .foregroundStyle(.red)
            }

            HStack {
                Button("修改休眠设置…") {
                    isShowingSettings = true
                }
                .disabled(powerManager.snapshot?.source.pmsetFlag == nil || powerManager.isApplying)

                if powerManager.restorablePolicy != nil {
                    Button("恢复上次设置…") {
                        powerManager.restorePreviousPolicy()
                    }
                    .disabled(powerManager.isApplying)
                }

                Spacer()

                Button {
                    powerManager.refresh()
                } label: {
                    if powerManager.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("刷新电源状态")
                .accessibilityLabel("刷新电源状态")
                .disabled(
                    powerManager.isRefreshing
                        || powerManager.isApplying
                        || powerManager.isLidProtectionApplying
                )
            }
        }
    }

    private func policyRow(icon: String, title: String, value: String) -> some View {
        GridRow {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
            Text(value)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func durationText(_ minutes: Int?) -> String {
        guard let minutes else { return "未知" }
        if minutes == 0 { return "永不" }
        return "\(minutes) 分钟"
    }

    private func lidStateText(_ lidOpen: Bool?) -> String {
        guard let lidOpen else { return "未知" }
        return lidOpen ? "打开" : "合上"
    }
}

private struct SleepSettingsSheet: View {
    @ObservedObject var powerManager: PowerManager
    @Environment(\.dismiss) private var dismiss

    @State private var systemSleepMinutes: Int
    @State private var displaySleepMinutes: Int
    @State private var lidWakeEnabled: Bool
    private let baseline: PowerPolicyBaseline?

    init(powerManager: PowerManager) {
        self.powerManager = powerManager
        let baseline = powerManager.snapshot.flatMap(PowerPolicyBaseline.init(snapshot:))
        self.baseline = baseline
        _systemSleepMinutes = State(initialValue: baseline?.systemSleepMinutes ?? 0)
        _displaySleepMinutes = State(initialValue: baseline?.displaySleepMinutes ?? 0)
        _lidWakeEnabled = State(initialValue: baseline?.lidWakeEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("修改休眠设置")
                    .font(.title2.weight(.semibold))
                Text("仅修改打开窗口时的电源方案：\(baseline?.sourceName ?? "未知")")
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("电脑休眠", selection: $systemSleepMinutes) {
                    ForEach(timerOptions, id: \.self) { value in
                        Text(timerLabel(value)).tag(value)
                    }
                }

                Picker("显示器关闭", selection: $displaySleepMinutes) {
                    ForEach(timerOptions, id: \.self) { value in
                        Text(timerLabel(value)).tag(value)
                    }
                }

                if baseline?.lidWakeEnabled != nil {
                    Toggle("开盖时自动唤醒 MacBook", isOn: $lidWakeEnabled)
                }
            }
            .formStyle(.grouped)

            Label("应用时 macOS 会请求管理员授权。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let lastError = powerManager.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("应用") {
                    guard let baseline else { return }
                    Task {
                        let success = await powerManager.applyPolicy(
                            systemSleepMinutes: systemSleepMinutes,
                            displaySleepMinutes: displaySleepMinutes,
                            lidWakeEnabled: baseline.lidWakeEnabled == nil ? nil : lidWakeEnabled,
                            baseline: baseline
                        )
                        if success { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(powerManager.isApplying || baseline == nil || !hasChanges)
            }
        }
        .padding(22)
        .frame(width: 400)
        .interactiveDismissDisabled(powerManager.isApplying)
    }

    private var timerOptions: [Int] {
        Array(Set([0, 1, 5, 10, 15, 30, 60, 120, systemSleepMinutes, displaySleepMinutes])).sorted()
    }

    private var hasChanges: Bool {
        guard let baseline else { return false }
        return systemSleepMinutes != baseline.systemSleepMinutes
            || displaySleepMinutes != baseline.displaySleepMinutes
            || (baseline.lidWakeEnabled != nil && lidWakeEnabled != baseline.lidWakeEnabled)
    }

    private func timerLabel(_ minutes: Int) -> String {
        minutes == 0 ? "永不" : "\(minutes) 分钟"
    }
}
