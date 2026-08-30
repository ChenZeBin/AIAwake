import XCTest
@testable import AIAwake

final class PowerSnapshotTests: XCTestCase {
    func testParsesActiveACProfileAndAssertions() {
        let snapshot = PowerSnapshot.parse(
            batteryOutput: "Now drawing from 'AC Power'\n",
            customOutput: """
            AC Power:
             standby              0
             powernap             1
             displaysleep         15
             sleep                1
             disksleep            10
            """,
            ioregOutput: "",
            assertionsOutput: """
            Assertion status system-wide:
               PreventUserIdleDisplaySleep    0
               PreventUserIdleSystemSleep     1
            """,
            globalOutput: """
            System-wide power settings:
             SleepDisabled        0
            """
        )

        XCTAssertEqual(snapshot.source, .ac)
        XCTAssertEqual(snapshot.systemSleepMinutes, 1)
        XCTAssertEqual(snapshot.displaySleepMinutes, 15)
        XCTAssertEqual(snapshot.diskSleepMinutes, 10)
        XCTAssertEqual(snapshot.standbyEnabled, false)
        XCTAssertEqual(snapshot.powerNapEnabled, true)
        XCTAssertTrue(snapshot.systemIdleSleepBlocked)
        XCTAssertFalse(snapshot.displayIdleSleepBlocked)
        XCTAssertEqual(snapshot.sleepDisabled, false)
        XCTAssertFalse(snapshot.supportsClamshell)
    }

    func testParsesPortableBatteryProfileAndOpenLid() {
        let snapshot = PowerSnapshot.parse(
            batteryOutput: "Now drawing from 'Battery Power'\n",
            customOutput: """
            Battery Power:
             lidwake              1
             displaysleep         5
             sleep                10
            AC Power:
             lidwake              1
             displaysleep         15
             sleep                0
            """,
            ioregOutput: "  |   \"AppleClamshellState\" = No\n",
            assertionsOutput: ""
        )

        XCTAssertEqual(snapshot.source, .battery)
        XCTAssertEqual(snapshot.systemSleepMinutes, 10)
        XCTAssertEqual(snapshot.displaySleepMinutes, 5)
        XCTAssertEqual(snapshot.lidWakeEnabled, true)
        XCTAssertEqual(snapshot.lidOpen, true)
        XCTAssertTrue(snapshot.supportsClamshell)
    }

    func testBuildsAllowlistedPMSetCommand() throws {
        let command = try PrivilegedPowerSettings.pmsetCommand(
            profileFlag: "-c",
            systemSleepMinutes: 0,
            displaySleepMinutes: 15,
            lidWakeEnabled: true
        )

        XCTAssertEqual(command, "/usr/bin/pmset -c sleep 0 displaysleep 15 lidwake 1")
    }

    func testKeepsPortableLidStateUnknownWhenIORegCannotReadIt() {
        let snapshot = PowerSnapshot.parse(
            batteryOutput: "Now drawing from 'Battery Power'\n",
            customOutput: """
            Battery Power:
             lidwake              1
             displaysleep         5
             sleep                10
            """,
            ioregOutput: "",
            assertionsOutput: ""
        )

        XCTAssertTrue(snapshot.supportsClamshell)
        XCTAssertNil(snapshot.lidOpen)
    }

    func testRejectsUnsafeProfileFlag() {
        XCTAssertThrowsError(
            try PrivilegedPowerSettings.pmsetCommand(
                profileFlag: "-a; reboot",
                systemSleepMinutes: 0,
                displaySleepMinutes: 0,
                lidWakeEnabled: nil
            )
        )
    }

    func testParsesSystemWideSleepDisabledOverride() {
        XCTAssertEqual(
            LidProtectionPolicy.sleepDisabled(from: "System-wide power settings:\n SleepDisabled\t\t1\n"),
            true
        )
        XCTAssertEqual(
            LidProtectionPolicy.sleepDisabled(from: "System-wide power settings:\n SleepDisabled 0\n"),
            false
        )
        XCTAssertNil(LidProtectionPolicy.sleepDisabled(from: "Currently in use:\n sleep 0\n"))
    }

    func testValidatesBoundedLidLeaseInputs() {
        let token = UUID().uuidString
        XCTAssertTrue(LidProtectionPolicy.isValidToken(token))
        XCTAssertFalse(LidProtectionPolicy.isValidToken("not-a-token"))
        XCTAssertTrue(LidProtectionPolicy.isValidDuration(5 * 60))
        XCTAssertTrue(LidProtectionPolicy.isValidDuration(4 * 60 * 60))
        XCTAssertFalse(LidProtectionPolicy.isValidDuration(4 * 60 * 60 + 1))
        XCTAssertFalse(LidProtectionPolicy.isValidDuration(.infinity))
    }

    func testRequiresACPowerForLidProtection() {
        XCTAssertTrue(LidProtectionPolicy.isOnACPower(from: "Now drawing from 'AC Power'"))
        XCTAssertFalse(LidProtectionPolicy.isOnACPower(from: "Now drawing from 'Battery Power'"))
    }
}
