import Foundation

enum LidProtectionConstants {
    static let daemonPlistName = "com.carbin.AIAwake.LidHelper.plist"
    static let machServiceName = "com.carbin.AIAwake.LidHelper"
    static let appBundleIdentifier = "com.carbin.AIAwake"
    static let helperBundleIdentifier = "com.carbin.AIAwake.LidHelper"
    static let teamIdentifier = "KS2MXK543H"

    static let minimumLeaseDuration: TimeInterval = 5 * 60
    static let maximumLeaseDuration: TimeInterval = 4 * 60 * 60
    static let heartbeatInterval: TimeInterval = 20
    static let heartbeatTimeout: TimeInterval = 75

    static let appCodeSigningRequirement = """
    anchor apple generic and identifier "\(appBundleIdentifier)" and certificate leaf[subject.OU] = "\(teamIdentifier)"
    """

    static let helperCodeSigningRequirement = """
    anchor apple generic and identifier "\(helperBundleIdentifier)" and certificate leaf[subject.OU] = "\(teamIdentifier)"
    """
}

enum LidHelperStateCode: Int {
    case inactive = 0
    case active = 1
    case recoveryRequired = 2
}

@objc protocol LidProtectionXPCProtocol {
    func status(withReply reply: @escaping (Int, NSDate?, NSString?) -> Void)

    func beginLease(
        token: NSString,
        duration: TimeInterval,
        withReply reply: @escaping (Bool, NSDate?, NSString?) -> Void
    )

    func renewLease(
        token: NSString,
        withReply reply: @escaping (Bool, NSString?) -> Void
    )

    func endLease(
        token: NSString,
        withReply reply: @escaping (Bool, NSString?) -> Void
    )
}

enum LidProtectionPolicy {
    static func isValidToken(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString == value.uppercased()
    }

    static func isValidDuration(_ value: TimeInterval) -> Bool {
        value.isFinite
            && value >= LidProtectionConstants.minimumLeaseDuration
            && value <= LidProtectionConstants.maximumLeaseDuration
    }

    static func sleepDisabled(from output: String) -> Bool? {
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let parts = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard parts.count == 2,
                  parts[0].lowercased() == "sleepdisabled",
                  let value = Int(parts[1]),
                  value == 0 || value == 1 else {
                continue
            }
            return value == 1
        }
        return nil
    }

    static func isOnACPower(from output: String) -> Bool {
        output.localizedCaseInsensitiveContains("AC Power")
    }
}
