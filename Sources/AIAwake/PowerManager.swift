import Combine
import Foundation
import IOKit.pwr_mgt

struct PowerPolicyBackup: Codable, Equatable, Sendable {
    let profileFlag: String
    let systemSleepMinutes: Int
    let displaySleepMinutes: Int
    let lidWakeEnabled: Bool?
    let appliedSystemSleepMinutes: Int
    let appliedDisplaySleepMinutes: Int
    let appliedLidWakeEnabled: Bool?
}

struct PowerPolicyBaseline: Equatable, Sendable {
    let profileFlag: String
    let sourceName: String
    let systemSleepMinutes: Int
    let displaySleepMinutes: Int
    let lidWakeEnabled: Bool?

    init?(snapshot: PowerSnapshot) {
        guard let profileFlag = snapshot.source.pmsetFlag,
              let systemSleepMinutes = snapshot.systemSleepMinutes,
              let displaySleepMinutes = snapshot.displaySleepMinutes else {
            return nil
        }

        self.profileFlag = profileFlag
        sourceName = snapshot.source.displayName
        self.systemSleepMinutes = systemSleepMinutes
        self.displaySleepMinutes = displaySleepMinutes
        lidWakeEnabled = snapshot.lidWakeEnabled
    }
}

enum PrivilegedPowerSettingsError: LocalizedError {
    case invalidValue
    case cancelled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "休眠设置值无效。"
        case .cancelled:
            return "已取消管理员授权，设置未更改。"
        case .commandFailed(let message):
            return message.isEmpty ? "无法修改休眠设置。" : message
        }
    }
}

enum PrivilegedPowerSettings {
    static func pmsetCommand(
        profileFlag: String,
        systemSleepMinutes: Int,
        displaySleepMinutes: Int,
        lidWakeEnabled: Bool?
    ) throws -> String {
        guard ["-b", "-c", "-u"].contains(profileFlag),
              (0...1_440).contains(systemSleepMinutes),
              (0...1_440).contains(displaySleepMinutes) else {
            throw PrivilegedPowerSettingsError.invalidValue
        }

        var arguments = [
            profileFlag,
            "sleep", String(systemSleepMinutes),
            "displaysleep", String(displaySleepMinutes)
        ]

        if let lidWakeEnabled {
            arguments.append(contentsOf: ["lidwake", lidWakeEnabled ? "1" : "0"])
        }

        return (["/usr/bin/pmset"] + arguments).joined(separator: " ")
    }

    static func apply(
        profileFlag: String,
        systemSleepMinutes: Int,
        displaySleepMinutes: Int,
        lidWakeEnabled: Bool?
    ) throws {
        let command = try pmsetCommand(
            profileFlag: profileFlag,
            systemSleepMinutes: systemSleepMinutes,
            displaySleepMinutes: displaySleepMinutes,
            lidWakeEnabled: lidWakeEnabled
        )
        try runWithAdministratorPrivileges(command)
    }

    private static func runWithAdministratorPrivileges(_ command: String) throws {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"

        do {
            _ = try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", script])
        } catch let error as CommandRunnerError {
            let message = error.localizedDescription
            if message.contains("(-128)") || message.localizedCaseInsensitiveContains("canceled") {
                throw PrivilegedPowerSettingsError.cancelled
            }
            throw PrivilegedPowerSettingsError.commandFailed(message)
        } catch {
            throw PrivilegedPowerSettingsError.commandFailed(error.localizedDescription)
        }
    }
}

@MainActor
final class PowerManager: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isApplying = false
    @Published private(set) var isProtectionEnabled = false
    @Published private(set) var protectionStartedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var restorablePolicy: PowerPolicyBackup?
    @Published private(set) var keepDisplayAwake: Bool
    @Published private(set) var isLidProtectionEnabled = false
    @Published private(set) var isLidProtectionApplying = false
    @Published private(set) var lidProtectionExpiresAt: Date?
    @Published private(set) var lidHelperRegistrationStatus: LidHelperRegistrationStatus = .notRegistered
    @Published private(set) var lidProtectionRecoveryRequired = false

    private var activeAssertionID: IOPMAssertionID?
    private var refreshGeneration = 0
    private var lidLeaseToken: String?
    private var lidHeartbeatTask: Task<Void, Never>?
    private let lidProtectionClient = LidProtectionClient()

    private let policyBackupKey = "powerPolicyBackup"

    init() {
        let defaults = UserDefaults.standard
        keepDisplayAwake = false
        if let data = defaults.data(forKey: policyBackupKey) {
            restorablePolicy = try? JSONDecoder().decode(PowerPolicyBackup.self, from: data)
        }
        lidHelperRegistrationStatus = lidProtectionClient.registrationStatus
        refresh()
    }

    deinit {
        lidHeartbeatTask?.cancel()
        if let activeAssertionID {
            IOPMAssertionRelease(activeAssertionID)
        }
    }

    var isAnyProtectionEnabled: Bool {
        isProtectionEnabled || isLidProtectionEnabled
    }

    var hasUnownedSleepDisabledOverride: Bool {
        snapshot?.sleepDisabled == true
            && !isLidProtectionEnabled
            && !lidProtectionRecoveryRequired
    }

    func setProtectionEnabled(_ enabled: Bool) {
        guard enabled != isProtectionEnabled else { return }
        lastError = nil

        if !enabled, isLidProtectionEnabled {
            lastError = "请先关闭“合盖继续运行”，再关闭 AI 运行保护。"
            return
        }

        if enabled {
            guard let assertionID = createAssertion(preventDisplaySleep: keepDisplayAwake) else { return }
            activeAssertionID = assertionID
            isProtectionEnabled = true
            protectionStartedAt = Date()
        } else {
            releaseActiveAssertion()
            isProtectionEnabled = false
            protectionStartedAt = nil
            keepDisplayAwake = false
        }
    }

    func setKeepDisplayAwake(_ enabled: Bool) {
        guard isProtectionEnabled, enabled != keepDisplayAwake else { return }

        // Acquire the replacement first so a failed mode change never drops protection.
        guard let replacementID = createAssertion(preventDisplaySleep: enabled) else { return }
        let previousID = activeAssertionID
        activeAssertionID = replacementID
        keepDisplayAwake = enabled

        if let previousID {
            IOPMAssertionRelease(previousID)
        }
    }

    func refresh() {
        guard !isApplying, !isLidProtectionApplying else { return }
        Task { await refreshNow() }
    }

    @discardableResult
    func refreshNow() async -> Bool {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        do {
            let freshSnapshot = try await Task.detached(priority: .userInitiated) {
                try PowerSnapshot.load()
            }.value

            if generation == refreshGeneration {
                snapshot = freshSnapshot
                lidHelperRegistrationStatus = lidProtectionClient.registrationStatus
                if isLidProtectionEnabled, freshSnapshot.sleepDisabled == false {
                    transitionToLidProtectionInactive()
                    lastError = "系统已停止合盖运行保护；可能是电源断开、温度过高或租约到期。"
                } else if lidProtectionRecoveryRequired, freshSnapshot.sleepDisabled == false {
                    lidProtectionRecoveryRequired = false
                    lastError = nil
                } else if lidProtectionRecoveryRequired {
                    // Preserve the only actionable recovery instructions while the global override remains.
                } else {
                    lastError = nil
                }
                isRefreshing = false
                return true
            }
            return false
        } catch {
            if generation == refreshGeneration {
                lastError = "无法读取电源状态：\(error.localizedDescription)"
                isRefreshing = false
            }
            return false
        }
    }

    func applyPolicy(
        systemSleepMinutes: Int,
        displaySleepMinutes: Int,
        lidWakeEnabled: Bool?,
        baseline: PowerPolicyBaseline
    ) async -> Bool {
        guard !isApplying else {
            lastError = "另一项电源设置操作正在进行。"
            return false
        }

        isApplying = true
        lastError = nil
        defer { isApplying = false }
        guard await refreshNow() else { return false }

        guard currentPolicyMatchesBaseline(baseline) else {
            lastError = "电源方案或休眠设置已发生变化。请关闭此窗口并重新打开后再试。"
            return false
        }

        let previousJournal = restorablePolicy
        let previousValues = previousValuesForChainedChange(
            baseline: baseline,
            previousJournal: previousJournal
        )
        let backup = PowerPolicyBackup(
            profileFlag: baseline.profileFlag,
            systemSleepMinutes: previousValues.systemSleepMinutes,
            displaySleepMinutes: previousValues.displaySleepMinutes,
            lidWakeEnabled: previousValues.lidWakeEnabled,
            appliedSystemSleepMinutes: systemSleepMinutes,
            appliedDisplaySleepMinutes: displaySleepMinutes,
            appliedLidWakeEnabled: lidWakeEnabled
        )
        guard saveBackup(backup) else {
            lastError = "无法保存恢复记录，休眠设置未更改。"
            return false
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try PrivilegedPowerSettings.apply(
                    profileFlag: baseline.profileFlag,
                    systemSleepMinutes: systemSleepMinutes,
                    displaySleepMinutes: displaySleepMinutes,
                    lidWakeEnabled: lidWakeEnabled
                )
            }.value
            guard await refreshNow() else {
                lastError = "设置可能已应用，但无法读回验证；已保留旧值，可尝试恢复。"
                return false
            }

            guard currentPolicyMatchesAppliedValues(in: backup) else {
                lastError = "系统没有完整应用新设置；已保留旧值，可尝试恢复。"
                return false
            }
            return true
        } catch PrivilegedPowerSettingsError.cancelled {
            if let previousJournal {
                _ = saveBackup(previousJournal)
            } else {
                clearBackup()
            }
            lastError = PrivilegedPowerSettingsError.cancelled.localizedDescription
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restorePreviousPolicy() {
        guard let backup = restorablePolicy, !isApplying else { return }
        isApplying = true

        Task {
            lastError = nil
            defer { isApplying = false }

            do {
                guard await refreshNow() else { return }
                guard currentPolicyMatchesAppliedValues(in: backup) else {
                    lastError = "休眠设置之后已在其他位置发生变化。为避免覆盖，请手动确认后再修改。"
                    return
                }

                try await Task.detached(priority: .userInitiated) {
                    try PrivilegedPowerSettings.apply(
                        profileFlag: backup.profileFlag,
                        systemSleepMinutes: backup.systemSleepMinutes,
                        displaySleepMinutes: backup.displaySleepMinutes,
                        lidWakeEnabled: backup.lidWakeEnabled
                    )
                }.value
                guard await refreshNow() else {
                    lastError = "恢复命令已执行，但无法读回验证。"
                    return
                }

                guard currentPolicyMatchesPreviousValues(in: backup) else {
                    lastError = "旧设置没有完整恢复，请检查系统电源设置。"
                    return
                }
                clearBackup()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    @discardableResult
    func enableLidProtection() async -> Bool {
        guard !isLidProtectionApplying else { return false }
        guard !isLidProtectionEnabled else { return true }

        isLidProtectionApplying = true
        lastError = nil
        lidProtectionRecoveryRequired = false
        var enabledIdleProtectionForAttempt = false
        var succeeded = false
        defer {
            isLidProtectionApplying = false
            if !succeeded, enabledIdleProtectionForAttempt {
                let preservedError = lastError
                setProtectionEnabled(false)
                lastError = preservedError
            }
        }

        guard await refreshNow(), let snapshot else { return false }
        guard snapshot.supportsClamshell else {
            lastError = "这台 Mac 没有可管理的内置屏幕盖。"
            return false
        }
        guard snapshot.source == .ac else {
            lastError = "合盖继续运行仅在接入电源适配器时可开启。"
            return false
        }
        guard applicationIsInstalledForLidHelper else {
            lastError = "请先将 AIAwake 移到 /Applications，重新打开后再启用合盖运行。"
            return false
        }
        guard snapshot.sleepDisabled != true else {
            lastError = "SleepDisabled 已被其他工具开启；AIAwake 不会覆盖或接管它。"
            return false
        }

        if !isProtectionEnabled {
            setProtectionEnabled(true)
            guard isProtectionEnabled else { return false }
            enabledIdleProtectionForAttempt = true
        }

        do {
            let registrationStatus = try lidProtectionClient.registerIfNeeded()
            lidHelperRegistrationStatus = registrationStatus
            guard registrationStatus == .enabled else {
                throw LidProtectionClientError.serviceNotEnabled(registrationStatus)
            }

            let helperStatus = try await lidProtectionClient.status()
            switch helperStatus.state {
            case .inactive:
                break
            case .active:
                throw LidProtectionClientError.rejected("后台组件已有活动租约；请关闭其他 AIAwake 实例后重试。")
            case .recoveryRequired:
                lidProtectionRecoveryRequired = true
                throw LidProtectionClientError.rejected(
                    helperStatus.message ?? "后台组件需要先恢复系统状态。"
                )
            }

            let token = UUID().uuidString
            let result = try await lidProtectionClient.beginLease(
                token: token,
                duration: LidProtectionConstants.maximumLeaseDuration
            )
            lidLeaseToken = token
            isLidProtectionEnabled = true
            lidProtectionExpiresAt = result.expiresAt
            startLidHeartbeat(token: token)

            guard await refreshNow(), self.snapshot?.sleepDisabled == true else {
                try? await lidProtectionClient.endLease(token: token)
                transitionToLidProtectionInactive()
                throw LidProtectionClientError.rejected("系统没有读回 SleepDisabled=1，保护已撤销。")
            }

            succeeded = true
            return true
        } catch {
            lastError = error.localizedDescription
            lidHelperRegistrationStatus = lidProtectionClient.registrationStatus
            return false
        }
    }

    func disableLidProtection() async {
        guard !isLidProtectionApplying else { return }
        guard let token = lidLeaseToken else {
            transitionToLidProtectionInactive()
            return
        }

        isLidProtectionApplying = true
        lastError = nil
        lidHeartbeatTask?.cancel()

        var endError: Error?
        do {
            try await lidProtectionClient.endLease(token: token)
        } catch {
            endError = error
            // Disconnecting is also a helper-side fail-safe and requests immediate restoration.
            lidProtectionClient.invalidate()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        transitionToLidProtectionInactive()
        _ = await refreshNow()
        isLidProtectionApplying = false

        if snapshot?.sleepDisabled == true {
            lidProtectionRecoveryRequired = true
            lastError = "SleepDisabled 仍为 1。请重新启用后台组件让它恢复，或执行 sudo pmset -a disablesleep 0。"
        } else if let endError {
            lastError = "后台连接已中断，但系统状态已恢复：\(endError.localizedDescription)"
        }
    }

    func setLidProtectionEnabled(_ enabled: Bool) {
        Task {
            if enabled {
                _ = await enableLidProtection()
            } else {
                await disableLidProtection()
            }
        }
    }

    func openLidHelperApprovalSettings() {
        lidProtectionClient.openApprovalSettings()
    }

    private func createAssertion(preventDisplaySleep: Bool) -> IOPMAssertionID? {
        let assertionType = preventDisplaySleep
            ? kIOPMAssertPreventUserIdleDisplaySleep
            : kIOPMAssertPreventUserIdleSystemSleep
        let reason = preventDisplaySleep
            ? "AI Awake: keeping the AI task and display active"
            : "AI Awake: keeping a local AI task active"
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            lastError = "无法建立休眠保护（IOKit 错误 \(result)）。"
            return nil
        }
        return assertionID
    }

    private func releaseActiveAssertion() {
        if let activeAssertionID {
            IOPMAssertionRelease(activeAssertionID)
            self.activeAssertionID = nil
        }
    }

    private func startLidHeartbeat(token: String) {
        lidHeartbeatTask?.cancel()
        lidHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(LidProtectionConstants.heartbeatInterval * 1_000_000_000)
                    )
                    guard !Task.isCancelled, let self, self.lidLeaseToken == token else { return }
                    try await self.lidProtectionClient.renewLease(token: token)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.lidProtectionClient.invalidate()
                    self.transitionToLidProtectionInactive()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    _ = await self.refreshNow()
                    if self.snapshot?.sleepDisabled == true {
                        self.lidProtectionRecoveryRequired = true
                        self.lastError = "后台组件连接中断且 SleepDisabled 仍为 1。请在“登录项与扩展”重新批准后台组件，或执行 sudo pmset -a disablesleep 0。"
                    } else {
                        self.lastError = "合盖运行已停止：\(error.localizedDescription)"
                    }
                    return
                }
            }
        }
    }

    private func transitionToLidProtectionInactive() {
        lidHeartbeatTask?.cancel()
        lidHeartbeatTask = nil
        lidLeaseToken = nil
        isLidProtectionEnabled = false
        lidProtectionExpiresAt = nil
    }

    private var applicationIsInstalledForLidHelper: Bool {
        let path = Bundle.main.bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return path.hasPrefix("/Applications/")
    }

    private func currentPolicyMatchesAppliedValues(in backup: PowerPolicyBackup) -> Bool {
        guard let snapshot, snapshot.source.pmsetFlag == backup.profileFlag else { return false }
        return snapshot.systemSleepMinutes == backup.appliedSystemSleepMinutes
            && snapshot.displaySleepMinutes == backup.appliedDisplaySleepMinutes
            && (backup.appliedLidWakeEnabled == nil
                || snapshot.lidWakeEnabled == backup.appliedLidWakeEnabled)
    }

    private func currentPolicyMatchesBaseline(_ baseline: PowerPolicyBaseline) -> Bool {
        guard let snapshot, snapshot.source.pmsetFlag == baseline.profileFlag else { return false }
        return snapshot.systemSleepMinutes == baseline.systemSleepMinutes
            && snapshot.displaySleepMinutes == baseline.displaySleepMinutes
            && (baseline.lidWakeEnabled == nil || snapshot.lidWakeEnabled == baseline.lidWakeEnabled)
    }

    private func currentPolicyMatchesPreviousValues(in backup: PowerPolicyBackup) -> Bool {
        guard let snapshot, snapshot.source.pmsetFlag == backup.profileFlag else { return false }
        return snapshot.systemSleepMinutes == backup.systemSleepMinutes
            && snapshot.displaySleepMinutes == backup.displaySleepMinutes
            && (backup.lidWakeEnabled == nil || snapshot.lidWakeEnabled == backup.lidWakeEnabled)
    }

    private func previousValuesForChainedChange(
        baseline: PowerPolicyBaseline,
        previousJournal: PowerPolicyBackup?
    ) -> (systemSleepMinutes: Int, displaySleepMinutes: Int, lidWakeEnabled: Bool?) {
        guard let previousJournal,
              previousJournal.profileFlag == baseline.profileFlag,
              previousJournal.appliedSystemSleepMinutes == baseline.systemSleepMinutes,
              previousJournal.appliedDisplaySleepMinutes == baseline.displaySleepMinutes,
              (previousJournal.appliedLidWakeEnabled == nil
                || previousJournal.appliedLidWakeEnabled == baseline.lidWakeEnabled) else {
            return (
                baseline.systemSleepMinutes,
                baseline.displaySleepMinutes,
                baseline.lidWakeEnabled
            )
        }

        return (
            previousJournal.systemSleepMinutes,
            previousJournal.displaySleepMinutes,
            previousJournal.lidWakeEnabled
        )
    }

    @discardableResult
    private func saveBackup(_ backup: PowerPolicyBackup) -> Bool {
        guard let data = try? JSONEncoder().encode(backup) else { return false }
        UserDefaults.standard.set(data, forKey: policyBackupKey)
        guard UserDefaults.standard.synchronize() else { return false }
        restorablePolicy = backup
        return true
    }

    private func clearBackup() {
        restorablePolicy = nil
        UserDefaults.standard.removeObject(forKey: policyBackupKey)
    }
}
