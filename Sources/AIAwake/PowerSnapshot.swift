import Foundation

enum PowerSource: Equatable, Sendable {
    case ac
    case battery
    case ups
    case unknown

    var displayName: String {
        switch self {
        case .ac: return "电源适配器"
        case .battery: return "电池"
        case .ups: return "UPS"
        case .unknown: return "未知电源"
        }
    }

    var profileHeader: String? {
        switch self {
        case .ac: return "AC Power"
        case .battery: return "Battery Power"
        case .ups: return "UPS Power"
        case .unknown: return nil
        }
    }

    var pmsetFlag: String? {
        switch self {
        case .ac: return "-c"
        case .battery: return "-b"
        case .ups: return "-u"
        case .unknown: return nil
        }
    }
}

struct PowerSnapshot: Equatable, Sendable {
    let source: PowerSource
    let systemSleepMinutes: Int?
    let displaySleepMinutes: Int?
    let diskSleepMinutes: Int?
    let standbyEnabled: Bool?
    let powerNapEnabled: Bool?
    let lidWakeEnabled: Bool?
    let lidOpen: Bool?
    let sleepDisabled: Bool?
    let systemIdleSleepBlocked: Bool
    let displayIdleSleepBlocked: Bool

    var supportsClamshell: Bool {
        lidOpen != nil || lidWakeEnabled != nil
    }

    static func load() throws -> PowerSnapshot {
        let batteryOutput = try CommandRunner.run("/usr/bin/pmset", arguments: ["-g", "batt"])
        let customOutput = try CommandRunner.run("/usr/bin/pmset", arguments: ["-g", "custom"])
        let ioregOutput = (try? CommandRunner.run(
            "/usr/sbin/ioreg",
            arguments: ["-r", "-k", "AppleClamshellState", "-d", "4"]
        )) ?? ""
        let assertionsOutput = (try? CommandRunner.run(
            "/usr/bin/pmset",
            arguments: ["-g", "assertions"]
        )) ?? ""
        let globalOutput = (try? CommandRunner.run("/usr/bin/pmset", arguments: ["-g"])) ?? ""

        return parse(
            batteryOutput: batteryOutput,
            customOutput: customOutput,
            ioregOutput: ioregOutput,
            assertionsOutput: assertionsOutput,
            globalOutput: globalOutput
        )
    }

    static func parse(
        batteryOutput: String,
        customOutput: String,
        ioregOutput: String,
        assertionsOutput: String,
        globalOutput: String = ""
    ) -> PowerSnapshot {
        let source = parsePowerSource(batteryOutput)
        let sections = parsePowerSections(customOutput)
        let values: [String: Int]

        if let header = source.profileHeader, let matching = sections[header] {
            values = matching
        } else {
            values = sections.values.first ?? [:]
        }

        return PowerSnapshot(
            source: source,
            systemSleepMinutes: values["sleep"],
            displaySleepMinutes: values["displaysleep"],
            diskSleepMinutes: values["disksleep"],
            standbyEnabled: values["standby"].map { $0 == 1 },
            powerNapEnabled: values["powernap"].map { $0 == 1 },
            lidWakeEnabled: values["lidwake"].map { $0 == 1 },
            lidOpen: parseLidOpen(ioregOutput),
            sleepDisabled: LidProtectionPolicy.sleepDisabled(from: globalOutput),
            systemIdleSleepBlocked: assertionIsActive("PreventUserIdleSystemSleep", in: assertionsOutput),
            displayIdleSleepBlocked: assertionIsActive("PreventUserIdleDisplaySleep", in: assertionsOutput)
        )
    }

    private static func parsePowerSource(_ output: String) -> PowerSource {
        if output.contains("Battery Power") { return .battery }
        if output.contains("AC Power") { return .ac }
        if output.contains("UPS Power") { return .ups }
        return .unknown
    }

    private static func parsePowerSections(_ output: String) -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        var currentSection: String?
        let knownHeaders = ["AC Power", "Battery Power", "UPS Power"]

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasSuffix(":"), knownHeaders.contains(String(line.dropLast())) {
                currentSection = String(line.dropLast())
                result[currentSection!] = [:]
                continue
            }

            guard let currentSection else { continue }
            let parts = line.split(whereSeparator: \Character.isWhitespace)
            guard parts.count >= 2, let value = Int(parts.last!) else { continue }
            let key = parts.dropLast().joined(separator: " ")
            result[currentSection]?[key] = value
        }

        return result
    }

    private static func parseLidOpen(_ output: String) -> Bool? {
        guard let stateLine = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { $0.contains("\"AppleClamshellState\"") }) else {
            return nil
        }

        if stateLine.contains("= Yes") { return false }
        if stateLine.contains("= No") { return true }
        return nil
    }

    private static func assertionIsActive(_ key: String, in output: String) -> Bool {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { line in
                let parts = line.split(whereSeparator: \Character.isWhitespace)
                return parts.count == 2 && parts[0] == Substring(key) && parts[1] == "1"
            }
    }
}

enum CommandRunnerError: LocalizedError {
    case failedToLaunch(String)
    case failed(executable: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message):
            return "无法启动系统命令：\(message)"
        case .failed(_, _, let message):
            return message.isEmpty ? "系统命令执行失败。" : message
        }
    }
}

enum CommandRunner {
    static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.failedToLaunch(error.localizedDescription)
        }

        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw CommandRunnerError.failed(
                executable: executable,
                status: process.terminationStatus,
                message: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return output
    }
}
