import AppKit
import SwiftUI

@main
struct AIAwakeApp: App {
    @StateObject private var powerManager = PowerManager()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--force-dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.arguments.contains("--force-light") {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
        #endif
    }

    var body: some Scene {
        Window("AI Awake", id: "main") {
            ContentView()
                .environmentObject(powerManager)
        }
        .defaultSize(width: 440, height: 650)
        .windowResizability(.contentSize)
        .commands {
            AppInfoCommands()
            ProtectionCommands(powerManager: powerManager)
        }

        MenuBarExtra {
            MenuBarContent(powerManager: powerManager)
        } label: {
            Image(systemName: powerManager.isAnyProtectionEnabled ? "infinity.circle.fill" : "infinity.circle")
                .accessibilityLabel(powerManager.isAnyProtectionEnabled ? "AI 运行保护已开启" : "AI 运行保护未开启")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About AI Awake") {
                var options: [NSApplication.AboutPanelOptionKey: Any] = [
                    .applicationName: "AI Awake"
                ]
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    options[.applicationIcon] = icon
                }
                NSApplication.shared.orderFrontStandardAboutPanel(options: options)
            }
        }
    }
}

private struct ProtectionCommands: Commands {
    @ObservedObject var powerManager: PowerManager

    var body: some Commands {
        CommandMenu("保护") {
            Button(powerManager.isProtectionEnabled ? "关闭 AI 运行保护" : "开启 AI 运行保护") {
                powerManager.setProtectionEnabled(!powerManager.isProtectionEnabled)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(powerManager.isLidProtectionEnabled)

            Toggle(
                "保持显示器点亮",
                isOn: Binding(
                    get: { powerManager.keepDisplayAwake },
                    set: { powerManager.setKeepDisplayAwake($0) }
                )
            )
            .disabled(!powerManager.isProtectionEnabled)

            Divider()

            Button("刷新电源状态") {
                powerManager.refresh()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var powerManager: PowerManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if powerManager.isLidProtectionEnabled {
            Text("合盖运行保护已开启")
        } else {
            Text(powerManager.isProtectionEnabled ? "AI 运行保护已开启" : "AI 运行保护未开启")
        }

        Button(powerManager.isProtectionEnabled ? "关闭保护" : "开启保护") {
            powerManager.setProtectionEnabled(!powerManager.isProtectionEnabled)
        }
        .disabled(powerManager.isLidProtectionEnabled)

        Toggle(
            "保持显示器点亮",
            isOn: Binding(
                get: { powerManager.keepDisplayAwake },
                set: { powerManager.setKeepDisplayAwake($0) }
            )
        )
        .disabled(!powerManager.isProtectionEnabled)

        if powerManager.isLidProtectionEnabled {
            Button("关闭合盖运行保护") {
                powerManager.setLidProtectionEnabled(false)
            }
        } else if powerManager.snapshot?.supportsClamshell == true {
            Button("设置合盖运行保护…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("打开 AI Awake") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("退出 AI Awake") {
            NSApp.terminate(nil)
        }
    }
}
