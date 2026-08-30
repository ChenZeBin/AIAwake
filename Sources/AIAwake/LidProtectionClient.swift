import Foundation
import ServiceManagement

enum LidHelperRegistrationStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var needsSystemApproval: Bool { self == .requiresApproval }
}

struct LidHelperStatus: Equatable {
    let state: LidHelperStateCode
    let expiresAt: Date?
    let message: String?
}

struct LidLeaseResult: Equatable {
    let expiresAt: Date
}

enum LidProtectionClientError: LocalizedError {
    case serviceNotEnabled(LidHelperRegistrationStatus)
    case unavailable(String)
    case rejected(String)
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .serviceNotEnabled(.requiresApproval):
            return "后台组件需要在“系统设置 → 通用 → 登录项与扩展”中批准。"
        case .serviceNotEnabled:
            return "合盖运行后台组件尚未启用。"
        case .unavailable(let message):
            return message.isEmpty ? "无法连接合盖运行后台组件。" : message
        case .rejected(let message):
            return message.isEmpty ? "后台组件拒绝了这次操作。" : message
        case .invalidReply:
            return "后台组件返回了无效状态。"
        }
    }
}

@MainActor
final class LidProtectionClient {
    private let service = SMAppService.daemon(plistName: LidProtectionConstants.daemonPlistName)
    private var connection: NSXPCConnection?

    var registrationStatus: LidHelperRegistrationStatus {
        Self.registrationStatus(from: service.status)
    }

    func registerIfNeeded() throws -> LidHelperRegistrationStatus {
        if service.status == .notRegistered {
            do {
                try service.register()
            } catch {
                let refreshed = registrationStatus
                if refreshed == .requiresApproval {
                    return refreshed
                }
                throw LidProtectionClientError.unavailable(error.localizedDescription)
            }
        }
        return registrationStatus
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func status() async throws -> LidHelperStatus {
        let activeConnection = try connectionForRequest()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply(continuation)
            armTimeout(reply, after: 5)
            guard let proxy = remoteProxy(for: activeConnection, reply: reply) else {
                reply.resume(throwing: LidProtectionClientError.unavailable(""))
                return
            }
            proxy.status { rawState, expiresAt, message in
                guard let state = LidHelperStateCode(rawValue: rawState) else {
                    reply.resume(throwing: LidProtectionClientError.invalidReply)
                    return
                }
                reply.resume(returning: LidHelperStatus(
                    state: state,
                    expiresAt: expiresAt as Date?,
                    message: message as String?
                ))
            }
        }
    }

    func beginLease(token: String, duration: TimeInterval) async throws -> LidLeaseResult {
        let activeConnection = try connectionForRequest()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply(continuation)
            armTimeout(reply, after: 20)
            guard let proxy = remoteProxy(for: activeConnection, reply: reply) else {
                reply.resume(throwing: LidProtectionClientError.unavailable(""))
                return
            }
            proxy.beginLease(token: token as NSString, duration: duration) { success, expiresAt, message in
                guard success, let expiresAt else {
                    reply.resume(throwing: LidProtectionClientError.rejected(message as String? ?? ""))
                    return
                }
                reply.resume(returning: LidLeaseResult(expiresAt: expiresAt as Date))
            }
        }
    }

    func renewLease(token: String) async throws {
        let activeConnection = try connectionForRequest()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply<Void>(continuation)
            armTimeout(reply, after: 10)
            guard let proxy = remoteProxy(for: activeConnection, reply: reply) else {
                reply.resume(throwing: LidProtectionClientError.unavailable(""))
                return
            }
            proxy.renewLease(token: token as NSString) { success, message in
                if success {
                    reply.resume(returning: ())
                } else {
                    reply.resume(throwing: LidProtectionClientError.rejected(message as String? ?? ""))
                }
            }
        }
    }

    func endLease(token: String) async throws {
        let activeConnection = try connectionForRequest()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply<Void>(continuation)
            armTimeout(reply, after: 10)
            guard let proxy = remoteProxy(for: activeConnection, reply: reply) else {
                reply.resume(throwing: LidProtectionClientError.unavailable(""))
                return
            }
            proxy.endLease(token: token as NSString) { success, message in
                if success {
                    reply.resume(returning: ())
                } else {
                    reply.resume(throwing: LidProtectionClientError.rejected(message as String? ?? ""))
                }
            }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func connectionForRequest() throws -> NSXPCConnection {
        guard registrationStatus == .enabled else {
            throw LidProtectionClientError.serviceNotEnabled(registrationStatus)
        }

        let activeConnection: NSXPCConnection
        if let connection {
            activeConnection = connection
        } else {
            let newConnection = NSXPCConnection(
                machServiceName: LidProtectionConstants.machServiceName,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(with: LidProtectionXPCProtocol.self)
            newConnection.setCodeSigningRequirement(LidProtectionConstants.helperCodeSigningRequirement)
            newConnection.invalidationHandler = { [weak self, weak newConnection] in
                Task { @MainActor in
                    guard let self, let newConnection, self.connection === newConnection else { return }
                    self.connection = nil
                }
            }
            newConnection.activate()
            connection = newConnection
            activeConnection = newConnection
        }

        return activeConnection
    }

    private func remoteProxy<Value>(
        for activeConnection: NSXPCConnection,
        reply: XPCReply<Value>
    ) -> LidProtectionXPCProtocol? {
        let proxy = activeConnection.remoteObjectProxyWithErrorHandler {
            [weak self, weak activeConnection] error in
            reply.resume(throwing: LidProtectionClientError.unavailable(error.localizedDescription))
            Task { @MainActor in
                guard let self,
                      let activeConnection,
                      self.connection === activeConnection else { return }
                self.invalidate()
            }
        }
        return proxy as? LidProtectionXPCProtocol
    }

    private func armTimeout<Value>(_ reply: XPCReply<Value>, after seconds: TimeInterval) {
        reply.fail(
            after: seconds,
            with: LidProtectionClientError.unavailable("后台组件响应超时。")
        ) { [weak self] in
            Task { @MainActor in
                self?.invalidate()
            }
        }
    }

    private static func registrationStatus(from status: SMAppService.Status) -> LidHelperRegistrationStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
}

private final class XPCReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        guard let continuation = takeContinuation() else { return false }
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard let continuation = takeContinuation() else { return false }
        continuation.resume(throwing: error)
        return true
    }

    func fail(
        after seconds: TimeInterval,
        with error: Error,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.resume(throwing: error) == true {
                onTimeout()
            }
        }
    }

    private func takeContinuation() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let result = continuation
        continuation = nil
        return result
    }
}
