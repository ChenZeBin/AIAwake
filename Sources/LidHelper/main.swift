import Darwin
import Foundation
import SystemConfiguration

private struct ClientIdentity: Equatable {
    let userID: uid_t
    let processID: pid_t
}

private final class ClientSession: @unchecked Sendable {
    let identifier = UUID()
    let identity: ClientIdentity
    private let lock = NSLock()
    private var cancelled = false

    init(identity: ClientIdentity) {
        self.identity = identity
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct LeaseJournal: Codable {
    enum Phase: String, Codable {
        case prepared
        case active
    }

    let token: String
    let ownerUserID: UInt32
    let ownerProcessID: Int32
    let baselineSleepDisabled: Bool
    let startedAt: Date
    let expiresAt: Date
    var lastHeartbeatAt: Date
    var phase: Phase

    func belongs(to client: ClientIdentity, token candidate: String) -> Bool {
        ownerUserID == client.userID
            && ownerProcessID == client.processID
            && token == candidate
    }
}

private enum HelperError: LocalizedError {
    case invalidJournal(String)
    case invalidRequest(String)
    case unsafeState(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJournal(let message),
             .invalidRequest(let message),
             .unsafeState(let message),
             .commandFailed(let message):
            return message
        }
    }
}

private final class LeaseJournalStore {
    private let directoryURL = URL(fileURLWithPath: "/var/db/com.carbin.AIAwake", isDirectory: true)
    private var journalURL: URL { directoryURL.appendingPathComponent("LidProtection.json") }

    init() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw HelperError.invalidJournal("安全日志路径不是目录。")
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let attributes = try fileManager.attributesOfItem(atPath: directoryURL.path)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard ownerID == 0, attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw HelperError.invalidJournal("安全日志目录必须由 root 所有。")
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    func load() throws -> LeaseJournal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }

        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        guard ownerID == 0,
              attributes[.type] as? FileAttributeType == .typeRegular,
              permissions & 0o077 == 0 else {
            throw HelperError.invalidJournal("安全日志的所有者或权限无效。")
        }

        do {
            let data = try Data(contentsOf: journalURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LeaseJournal.self, from: data)
        } catch {
            throw HelperError.invalidJournal("安全日志损坏，无法自动确认恢复范围。")
        }
    }

    func save(_ journal: LeaseJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(journal)
        try data.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        try fullySynchronizeJournal()
        synchronizeDirectory()
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.removeItem(at: journalURL)
        synchronizeDirectory()
    }

    private func fullySynchronizeJournal() throws {
        let descriptor = open(journalURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw HelperError.invalidJournal("无法打开安全日志进行持久化。")
        }
        defer { close(descriptor) }

        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw HelperError.invalidJournal("无法将安全日志持久化到磁盘。")
        }
    }

    private func synchronizeDirectory() {
        let descriptor = open(directoryURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }
}

private enum HelperCommandRunner {
    private static let commandTimeout: TimeInterval = 2

    static func runPMSet(_ arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in terminationSemaphore.signal() }

        do {
            try process.run()
        } catch {
            throw HelperError.commandFailed("无法启动 pmset：\(error.localizedDescription)")
        }

        guard terminationSemaphore.wait(timeout: .now() + commandTimeout) == .success else {
            process.terminate()
            if terminationSemaphore.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 1)
            }
            throw HelperError.commandFailed("pmset 响应超时。")
        }

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw HelperError.commandFailed(errorOutput.isEmpty ? "pmset 执行失败。" : errorOutput)
        }
        return output
    }

    static func sleepDisabled() throws -> Bool {
        let output = try runPMSet(["-g"])
        guard let result = LidProtectionPolicy.sleepDisabled(from: output) else {
            throw HelperError.commandFailed("无法读回 SleepDisabled 状态。")
        }
        return result
    }

    static func setSleepDisabled(_ enabled: Bool) throws {
        _ = try runPMSet(["-a", "disablesleep", enabled ? "1" : "0"])
    }

    static func isOnACPower() throws -> Bool {
        LidProtectionPolicy.isOnACPower(from: try runPMSet(["-g", "batt"]))
    }
}

private final class LidProtectionService {
    private let queue = DispatchQueue(label: "com.carbin.AIAwake.LidHelper.state")
    private let store: LeaseJournalStore
    private var activeLease: LeaseJournal?
    private var activeSessionIdentifier: UUID?
    private var recoveryMessage: String?
    private var safetyTimer: DispatchSourceTimer?

    init() throws {
        store = try LeaseJournalStore()
        recoverAtStartup()
        startSafetyTimer()
    }

    func status(reply: @escaping (Int, NSDate?, NSString?) -> Void) {
        queue.async {
            if let recoveryMessage = self.recoveryMessage {
                reply(
                    LidHelperStateCode.recoveryRequired.rawValue,
                    self.activeLease?.expiresAt as NSDate?,
                    recoveryMessage as NSString
                )
            } else if let activeLease = self.activeLease {
                reply(LidHelperStateCode.active.rawValue, activeLease.expiresAt as NSDate, nil)
            } else {
                reply(LidHelperStateCode.inactive.rawValue, nil, nil)
            }
        }
    }

    func beginLease(
        session: ClientSession,
        token: String,
        duration: TimeInterval,
        reply: @escaping (Bool, NSDate?, NSString?) -> Void
    ) {
        queue.async {
            do {
                guard !session.isCancelled else {
                    throw HelperError.invalidRequest("客户端连接已结束。")
                }
                guard self.recoveryMessage == nil else {
                    throw HelperError.unsafeState(self.recoveryMessage ?? "后台组件需要先恢复系统状态。")
                }
                guard self.activeLease == nil else {
                    throw HelperError.invalidRequest("已有合盖运行租约，不能重复开启。")
                }
                guard LidProtectionPolicy.isValidToken(token),
                      LidProtectionPolicy.isValidDuration(duration) else {
                    throw HelperError.invalidRequest("租约参数无效。")
                }
                guard Self.isActiveConsoleUser(session.identity.userID) else {
                    throw HelperError.invalidRequest("只有当前登录到桌面的用户可以开启合盖运行。")
                }
                guard try HelperCommandRunner.isOnACPower() else {
                    throw HelperError.unsafeState("仅接入电源适配器时可开启合盖运行。")
                }
                guard !session.isCancelled else {
                    throw HelperError.invalidRequest("客户端连接已结束。")
                }
                guard self.thermalStateIsSafe else {
                    throw HelperError.unsafeState("Mac 当前温度过高，不能开启合盖运行。")
                }
                guard try !HelperCommandRunner.sleepDisabled() else {
                    throw HelperError.unsafeState("SleepDisabled 已被其他工具开启；AIAwake 不会接管该设置。")
                }
                guard !session.isCancelled else {
                    throw HelperError.invalidRequest("客户端连接已结束。")
                }

                let now = Date()
                var journal = LeaseJournal(
                    token: token,
                    ownerUserID: session.identity.userID,
                    ownerProcessID: session.identity.processID,
                    baselineSleepDisabled: false,
                    startedAt: now,
                    expiresAt: now.addingTimeInterval(duration),
                    lastHeartbeatAt: now,
                    phase: .prepared
                )
                try self.store.save(journal)

                do {
                    guard !session.isCancelled else {
                        throw HelperError.invalidRequest("客户端连接已结束。")
                    }
                    try HelperCommandRunner.setSleepDisabled(true)
                    guard !session.isCancelled else {
                        throw HelperError.invalidRequest("客户端连接已结束，正在恢复系统设置。")
                    }
                    guard try HelperCommandRunner.sleepDisabled() else {
                        throw HelperError.commandFailed("系统没有应用 SleepDisabled=1。")
                    }
                    guard !session.isCancelled else {
                        throw HelperError.invalidRequest("客户端连接已结束，正在恢复系统设置。")
                    }

                    journal.phase = .active
                    try self.store.save(journal)
                    guard !session.isCancelled else {
                        throw HelperError.invalidRequest("客户端连接已结束，正在恢复系统设置。")
                    }
                    self.activeLease = journal
                    self.activeSessionIdentifier = session.identifier
                    reply(true, journal.expiresAt as NSDate, nil)
                } catch {
                    let originalMessage = error.localizedDescription
                    let recoveryFailure = self.restoreOwnedSetting(journal: journal)
                    let message = recoveryFailure.map {
                        "\(originalMessage) 自动恢复也失败：\($0)"
                    } ?? originalMessage
                    reply(false, nil, message as NSString)
                }
            } catch {
                reply(false, nil, error.localizedDescription as NSString)
            }
        }
    }

    func renewLease(
        session: ClientSession,
        token: String,
        reply: @escaping (Bool, NSString?) -> Void
    ) {
        queue.async {
            guard var lease = self.activeLease,
                  self.activeSessionIdentifier == session.identifier,
                  lease.belongs(to: session.identity, token: token) else {
                reply(false, "找不到属于当前进程的合盖运行租约。")
                return
            }

            guard !session.isCancelled else {
                _ = self.restoreOwnedSetting(journal: lease)
                reply(false, "客户端连接已结束。")
                return
            }

            do {
                let now = Date()
                guard now < lease.expiresAt else {
                    _ = self.restoreOwnedSetting(journal: lease)
                    throw HelperError.unsafeState("合盖运行已达到 4 小时上限。")
                }
                guard try HelperCommandRunner.isOnACPower() else {
                    _ = self.restoreOwnedSetting(journal: lease)
                    throw HelperError.unsafeState("电源适配器已断开，合盖运行已停止。")
                }
                guard !session.isCancelled else {
                    _ = self.restoreOwnedSetting(journal: lease)
                    throw HelperError.invalidRequest("客户端连接已结束。")
                }
                guard self.thermalStateIsSafe else {
                    _ = self.restoreOwnedSetting(journal: lease)
                    throw HelperError.unsafeState("Mac 温度过高，合盖运行已停止。")
                }

                lease.lastHeartbeatAt = now
                do {
                    try self.store.save(lease)
                    self.activeLease = lease
                    reply(true, nil)
                } catch {
                    _ = self.restoreOwnedSetting(journal: lease)
                    throw HelperError.invalidJournal("无法更新安全心跳，合盖运行已停止。")
                }
            } catch {
                reply(false, error.localizedDescription as NSString)
            }
        }
    }

    func endLease(
        session: ClientSession,
        token: String,
        reply: @escaping (Bool, NSString?) -> Void
    ) {
        queue.async {
            guard let lease = self.activeLease,
                  self.activeSessionIdentifier == session.identifier,
                  lease.belongs(to: session.identity, token: token) else {
                reply(false, "找不到属于当前进程的合盖运行租约。")
                return
            }

            if let failure = self.restoreOwnedSetting(journal: lease) {
                reply(false, failure as NSString)
            } else {
                reply(true, nil)
            }
        }
    }

    func connectionInvalidated(_ session: ClientSession) {
        queue.async {
            guard let lease = self.activeLease,
                  self.activeSessionIdentifier == session.identifier else {
                return
            }
            _ = self.restoreOwnedSetting(journal: lease)
        }
    }

    private var thermalStateIsSafe: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }

    private static func isActiveConsoleUser(_ userID: uid_t) -> Bool {
        var consoleUserID: uid_t = 0
        var consoleGroupID: gid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(
            nil,
            &consoleUserID,
            &consoleGroupID
        ) as String?, consoleUser != "loginwindow" else {
            return false
        }
        return userID == consoleUserID
    }

    private func recoverAtStartup() {
        do {
            guard let journal = try store.load() else { return }
            activeLease = journal
            _ = restoreOwnedSetting(journal: journal)
        } catch {
            recoveryMessage = error.localizedDescription
        }
    }

    private func startSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.performSafetyCheck()
        }
        timer.activate()
        safetyTimer = timer
    }

    private func performSafetyCheck() {
        guard let lease = activeLease else { return }

        if recoveryMessage != nil {
            _ = restoreOwnedSetting(journal: lease)
            return
        }

        let now = Date()
        let heartbeatExpired = now.timeIntervalSince(lease.lastHeartbeatAt)
            > LidProtectionConstants.heartbeatTimeout
        let leaseExpired = now >= lease.expiresAt
        let powerIsUnsafe = (try? HelperCommandRunner.isOnACPower()) != true

        if heartbeatExpired || leaseExpired || powerIsUnsafe || !thermalStateIsSafe {
            _ = restoreOwnedSetting(journal: lease)
            return
        }

        if (try? HelperCommandRunner.sleepDisabled()) == false {
            activeLease = nil
            activeSessionIdentifier = nil
            recoveryMessage = nil
            try? store.remove()
        }
    }

    @discardableResult
    private func restoreOwnedSetting(journal: LeaseJournal) -> String? {
        do {
            if try HelperCommandRunner.sleepDisabled() {
                try HelperCommandRunner.setSleepDisabled(journal.baselineSleepDisabled)
            }
            guard try HelperCommandRunner.sleepDisabled() == journal.baselineSleepDisabled else {
                throw HelperError.commandFailed("无法验证 SleepDisabled 已恢复。")
            }
            try store.remove()
            activeLease = nil
            activeSessionIdentifier = nil
            recoveryMessage = nil
            return nil
        } catch {
            activeLease = journal
            recoveryMessage = "无法自动恢复 SleepDisabled=0：\(error.localizedDescription)"
            return recoveryMessage
        }
    }
}

private final class LidProtectionEndpoint: NSObject, LidProtectionXPCProtocol {
    private let service: LidProtectionService
    private let session: ClientSession

    init(service: LidProtectionService, session: ClientSession) {
        self.service = service
        self.session = session
    }

    func status(withReply reply: @escaping (Int, NSDate?, NSString?) -> Void) {
        service.status(reply: reply)
    }

    func beginLease(
        token: NSString,
        duration: TimeInterval,
        withReply reply: @escaping (Bool, NSDate?, NSString?) -> Void
    ) {
        service.beginLease(session: session, token: token as String, duration: duration, reply: reply)
    }

    func renewLease(token: NSString, withReply reply: @escaping (Bool, NSString?) -> Void) {
        service.renewLease(session: session, token: token as String, reply: reply)
    }

    func endLease(token: NSString, withReply reply: @escaping (Bool, NSString?) -> Void) {
        service.endLease(session: session, token: token as String, reply: reply)
    }
}

private final class LidProtectionListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: LidProtectionService

    init(service: LidProtectionService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = ClientIdentity(
            userID: connection.effectiveUserIdentifier,
            processID: connection.processIdentifier
        )
        let session = ClientSession(identity: client)
        let endpoint = LidProtectionEndpoint(service: service, session: session)
        connection.exportedInterface = NSXPCInterface(with: LidProtectionXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak service] in
            session.cancel()
            service?.connectionInvalidated(session)
        }
        connection.activate()
        return true
    }
}

guard geteuid() == 0 else {
    fputs("AIAwakeLidHelper must run as root.\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    let service = try LidProtectionService()
    let listenerDelegate = LidProtectionListenerDelegate(service: service)
    let listener = NSXPCListener(machServiceName: LidProtectionConstants.machServiceName)
    listener.setConnectionCodeSigningRequirement(LidProtectionConstants.appCodeSigningRequirement)
    listener.delegate = listenerDelegate
    listener.activate()
    withExtendedLifetime((service, listenerDelegate, listener)) {
        RunLoop.current.run()
    }
} catch {
    fputs("AIAwakeLidHelper failed to start: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
