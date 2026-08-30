# AI Awake 验收记录

日期：2026-08-30
环境：macOS 15.5（24F74）、Apple Silicon、2× scale、Xcode 16.0
签名 Debug 产物：`.build-signed/Build/Products/Debug/AIAwake.app`

## 当前结论

**Build-verified；“Agent 持续执行”应用图标 v3 与窗口/菜单栏图形语言已统一并 rendered/launched；About 面板、accessory 后台运行与桌面机普通保护 interaction-verified；实验性合盖保护尚未完成特权实机验收。**

当前机器没有内置屏幕盖；Debug 产物使用 Apple Development 签名、未经公证且不在 `/Applications`。因此本轮没有登记 LaunchDaemon、没有执行 `pmset -a disablesleep 1`。AIAwake 当前以 `.accessory` 策略在菜单栏后台运行，主窗口已关闭、普通 AI 保护保持开启，`SleepDisabled=0`。最新签名产物已包含 `AppIcon.icns`、`Assets.car` 和完整 10 个 macOS `AppIcon` rendition。

## 证据清单

| 实际检查的证据 | 支持的判断 | 尚未覆盖 |
| --- | --- | --- |
| `project.yml` 与 app bundle 内容 | `LSUIElement=true`；helper 位于 `Contents/MacOS`，plist 位于 `Contents/Library/LaunchDaemons` | Developer ID 发布归档 |
| `Design/AIAwakeIcon-master-v3.png`、`Sources/AIAwake/Assets.xcassets` | 绿色连续轨道 + Agent 星点的 1024×1024 RGBA 原图与 16–1024 px 的 10 个 macOS 图标槽位齐全；v1 盾牌、v2 月亮电脑仅保留为历史稿 | Finder 图标缓存跨版本表现 |
| `Assets.car`、`AppIcon.icns`、Info.plist 与 `xcrun assetutil --info` | `CFBundleIconName=AppIcon`；10 个图像 rendition 与 1 条图标元数据实际进入最新签名 `.app` | Developer ID Archive |
| `Sources/AIAwake/AIAwakeApp.swift`、`ContentView.swift` | About 命令继续调用系统面板并通过 AppKit `.applicationIcon` 从当前包传入图标；窗口和菜单栏均用 `infinity.circle` / `infinity.circle.fill` 表达 Agent 持续执行 | Finder 的系统级缓存不由 App 内命令控制 |
| `Sources/Shared/LidProtectionXPC.swift` | XPC 只有 4 个固定方法；app/helper 使用精确 bundle ID 与 Team ID `KS2MXK543H` 双向校验 | 公证后 XPC 实连 |
| `Sources/LidHelper/main.swift` | root journal、AC/热/期限/心跳、2 秒命令超时、连接取消、启动恢复、当前控制台用户限制 | 拔电、过热、App/helper `SIGKILL`、重启故障注入 |
| `Sources/AIAwake/LidProtectionClient.swift`、`PowerManager.swift` | `SMAppService` 登记、20 秒开启超时、读回验证、外部 override 与 recovery 状态区分 | 管理员批准/撤销实机路径 |
| `Sources/AIAwake/ContentView.swift` | 实验标签、开启前确认、4 小时/散热警告、批准与人工恢复入口 | 真 MacBook 上的 idle/active/recovery UI |
| `.build-test/Logs/Test/Test-AIAwake-2026.08.30_18-21-14-+0800.xcresult` | 8/8 解析、白名单与租约输入测试通过；v3 Asset Catalog 与最终 UI 语义改动同步编译成功 | fake `pmset` 时序测试 |
| `codesign --verify --deep --strict` 与两条 `codesign -R` | 最新 app/helper 嵌套签名、Hardened Runtime、双向 requirement 有效 | Developer ID、notary、staple |
| `spctl -a -vv`、`stapler validate` | 当前 Debug 明确 `rejected` 且无 ticket，不能冒充可分发版本 | 正式归档 |
| 实际启动 `.app` + Computer Use + `pmset -g assertions` | 普通保护建立/释放具名 IOKit assertion，菜单和 sheet 可操作 | MacBook 专属开关 |
| `runtime-2026-08-30-icon/about-agent-infinite-v3.png` | 系统 About 面板实际渲染绿色连续轨道 + Agent 星点图标，标题为 `AI Awake` | Dark appearance 的 About 面板 |
| `runtime-2026-08-30-icon/main-agent-infinite-v3.png` | 主窗口使用绿色无限运行状态，突出 Agent 持续执行而非安全或设备语义 | Dark appearance 的当前 build |
| `NSRunningApplication` 与 `CGWindowListCopyWindowInfo` | 运行时 `isAccessory=true`；关闭主窗口后 `normalWindows=0`、`menuBarItems=1` | 菜单栏弹出菜单截图 |

## Apple reference prototype — observed

参照面：macOS 15.5 输入法/输入源状态项、系统菜单栏 extra，以及“系统设置 → 能耗”“通用 → 登录项与扩展”，实机观察日期 2026-08-30。类比只用于后台常驻、系统术语、审批路径和风险层级；AIAwake 仍是单用途长任务保护工具。

| Adopt | Adapt | Avoid |
| --- | --- | --- |
| accessory app 不占 Dock/`⌘Tab`、菜单栏保留状态与控制、SF Symbols 的清晰状态轮廓、后台项由系统设置批准 | 点击应用时可显示设置窗口，关闭窗口后任务由 app-wide `PowerManager` 继续持有；图标用原创连续轨道 + Agent 星点表达“任务一直跑” | 完全无入口的 headless 进程、暗中永久改写、一次性 `osascript + pmset disablesleep`、盾牌/锁/闪电等安全软件语义、月亮/电脑等只强调休眠设备的主视觉、模仿公司商标或在小尺寸堆叠文字与细节 |

状态：通过。

## Runtime screenshot matrix — partial

**Evidence source: actual launched signed `.app` only.** 当前机器无盖子，MacBook 专属状态不能由 mockup 或 preview 填充。

| Window/state | Width | Appearance | Activation | Build/macOS/scale | Evidence path | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 主窗口/accessory/普通保护/Agent 持续执行语义 v3 | 固定 440 pt | Light | Active | signed Debug / macOS 15.5 / 2× | `runtime-2026-08-30-icon/main-agent-infinite-v3.png` | passed |
| About 面板/Agent 持续执行图标 v3 | fixed system dialog | Light | Active | signed Debug / macOS 15.5 / 2× | `runtime-2026-08-30-icon/about-agent-infinite-v3.png` | passed |
| 主窗口/桌面机/未保护 | 固定 440 pt | Light | Active | signed Debug / macOS 15.5 / 2× | `runtime-2026-08-30-lid/main-light-desktop.png` | passed |
| 主窗口/桌面机/普通保护 | 固定 440 pt | Light | Active | signed Debug / macOS 15.5 / 2× | `runtime-2026-08-30-lid/main-light-protected.png` | passed |
| 后台角色/主窗口关闭 | menu-bar item | Light | Inactive | signed Debug / macOS 15.5 / 2× | none—CGWindow 诊断为 `normalWindows=0, menuBarItems=1` | pending screenshot |
| 菜单栏展开 | compact menu | Light | Active | signed Debug / macOS 15.5 / 2× | none—SystemUIServer AX timeout | pending |
| 主窗口/accessory/普通保护 | 固定 440 pt | Dark | Active | signed Debug / macOS 15.5 / 2× | none—未捕获当前 accessory build | pending |
| MacBook/合盖保护未开启 | 固定 440 pt | Light | Active | none—无真 MacBook | none—无真 MacBook | pending |
| MacBook/确认/保护中/recovery | 固定 440 pt | Light | Active | none—无公证测试构建与专用 MacBook | none—无公证测试构建与专用 MacBook | pending |

状态：部分通过。

## Interaction verification record — partial

| Path/command | Input | Expected | Observed | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| 签名 Debug 构建 | `xcodebuild ... build` | app/helper 编译并正确嵌入 | `BUILD SUCCEEDED` | build output + app bundle | passed |
| 自动化测试 | `xcodebuild ... test` | 新旧解析与输入边界均通过 | 8 tests、0 failures | `Test-AIAwake-2026.08.30_18-21-14-+0800.xcresult` | passed |
| Asset Catalog → app bundle | 构建后检查 Info.plist、`Assets.car` 与 `AppIcon.icns` | 10 个尺寸进入实际产物 | `CFBundleIconName=AppIcon`；`assetutil` 返回 10 个 rendition | signed Debug app bundle | passed |
| AIAwake → About AI Awake | 点击应用菜单中的 About | 系统 About 面板显示连续执行图标 | AX 返回 `image AIAwake icon`；截图与包内 v3 `AppIcon.icns` 一致 | `runtime-2026-08-30-icon/about-agent-infinite-v3.png` | passed |
| 主窗口与菜单栏状态图形 | 启动后开启普通保护 | 不出现盾牌/锁/睡眠设备主视觉；窗口和菜单栏突出 Agent 持续执行 | 主窗口实际渲染绿色 `infinity.circle.fill`；源代码状态项为 `infinity.circle`/`infinity.circle.fill` | `runtime-2026-08-30-icon/main-agent-infinite-v3.png` + source inspection | passed |
| accessory 配置 | 读回 Info.plist | `LSUIElement=true` | raw value 为 `true` | `plutil -extract LSUIElement raw` | passed |
| accessory 运行策略 | 启动实际 `.app` | 不进入 Dock/`⌘Tab` | `isRunning=true isAccessory=true` | `NSRunningApplication.activationPolicy` | passed |
| 主窗口 → AI 运行保护 | 点击主开关 | 建立具名系统空闲断言 | 具名 `PreventUserIdleSystemSleep` 存在 | Computer Use + `pmset -g assertions` | passed |
| 关闭主窗口 | 点击关闭按钮 | 进程、菜单栏状态项和保护继续 | PID 保持；断言保持；`normalWindows=0, menuBarItems=1` | Computer Use + CGWindow + `pmset` | passed |
| 菜单栏 → 打开 AI Awake | 点击状态项再点“打开 AI Awake” | 设置窗口重新出现 | not run—SystemUIServer AX timeout | none | pending |
| `codesign --deep --strict` | 验证最新 app | 整体签名有效 | app、helper、debug dylib 均 validated | codesign output | passed |
| Gatekeeper/notary | `spctl` / `stapler` | Debug 不得被误认为发布版 | `rejected`；无 stapled ticket | command output | expected failure |
| LaunchDaemon 状态 | 查询 system domain | 本轮不登记 | 找不到 `com.carbin.AIAwake.LidHelper` | `launchctl print` | passed（安全约束） |
| MacBook → 合盖继续运行 | 开启并批准 | 4 小时租约、读回 1 | not run | none—无专用 MacBook | pending |
| App/helper 崩溃、拔电、过热、到期、重启 | 故障注入 | helper 恢复并读回 0 | not run | none | pending |

## 已知发布边界

- `SleepDisabled` 是未公开、全局、持久的系统开关；该功能只能标为实验性。
- 管理员若在活动租约中撤销后台组件，系统可能杀死并阻止唯一 root 恢复主体重启。UI 和 README 提供重新批准与 `sudo pmset -a disablesleep 0`，但不能承诺无条件自动恢复。
- 正式测试需把 Developer ID + 公证 + staple 的应用放入 `/Applications`，只在专用 MacBook 上执行特权矩阵。
- 当前实现拒绝接管外部已有的 `SleepDisabled=1`；不会擅自关闭其他工具的设置。

**Completion status：“Agent 持续执行”应用图标 v3 Rendered/launched + interaction-verified；整体 Build-verified / accessory background interaction-verified；menu popup screenshot 与 privileged lid interaction pending。**
