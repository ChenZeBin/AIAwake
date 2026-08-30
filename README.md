# AI Awake

一个极简原生 macOS 工具，帮助本地模型、Agent、训练和推理任务避免因用户空闲而中断。

## 第一版能力

- 一键开启“AI 运行保护”，仅在应用运行期间阻止系统空闲休眠。
- 可选同时阻止显示器因空闲而关闭。
- MacBook 可选择“合盖继续运行（实验性）”，使用受限后台组件建立最长 4 小时的安全租约。
- 查看当前供电来源、电脑休眠和显示器关闭计时器。
- 修改当前电源方案的 `sleep`、`displaysleep`；MacBook 支持时也可修改 `lidwake`。
- 修改前由 macOS 显示管理员授权，修改后保留一次可恢复的旧设置。
- 菜单栏常驻入口和 `⇧⌘A` 快捷键。
- 以 accessory app 运行：不出现在 Dock 和 `⌘Tab`，关闭设置窗口后继续在菜单栏后台运行。

当前工程是非沙盒的本地开发版。它通过系统管理员授权修改常规 `pmset` 设置，并内嵌一个由 `SMAppService` 管理的 LaunchDaemon 处理合盖运行，不能直接作为 Mac App Store 构建提交。正式分发需要同一 Team ID 的 Developer ID 签名、公证和独立权限验收。若目标是 Mac App Store，应移除持久设置与合盖运行，仅保留临时保护和只读状态。

## 合盖边界

`AI 运行保护` 使用公开的空闲休眠活动断言。Apple 的本机 SDK 说明明确指出，这类断言仍允许因合盖、用户主动休眠、低电量等原因进入休眠。

“合盖继续运行（实验性）”是单独的高权限能力：后台组件临时应用未公开的 `pmset -a disablesleep 1`，并在结束时读回验证 `SleepDisabled=0`。它不伪装成普通空闲保护，也不承诺在所有机型和 macOS 版本上可用。

安全边界：

- 仅允许当前桌面用户在应用确实位于 `/Applications`、接入 AC 电源且温度未达到 `serious` / `critical` 时开启。
- 单次租约最长 4 小时；AIAwake 每 20 秒续心跳，后台组件在失联 75 秒内恢复。
- AIAwake 退出或崩溃、XPC 断开、拔掉电源、过热、租约到期、后台组件重启时，后台组件都会尝试恢复原值。
- 设置前写入 root 所有、权限 `0600` 的事务日志；后台组件启动时优先处理未完成恢复。
- 每个 `pmset` 调用有 2 秒硬超时；XPC 失效会立即标记连接取消，任何写入前后都会复查，取消路径只允许恢复。
- XPC 只允许固定的 `status` / `beginLease` / `renewLease` / `endLease`，应用和后台组件按 bundle ID 与 Team ID `KS2MXK543H` 双向校验签名。
- 如果管理员在租约期间撤销后台组件，macOS 可能阻止它重新启动，`SleepDisabled=1` 可能残留。重新批准后台组件以触发恢复；紧急情况下执行 `sudo pmset -a disablesleep 0` 并用 `pmset -g` 验证。

MacBook 上的 `lidwake` 仅控制“开盖时是否唤醒”，不等于阻止合盖休眠。长时间合盖运行还涉及供电和散热，应使用 macOS 支持的合盖模式与合适的外接设备。

首次使用合盖运行时，AIAwake 会登记后台组件；管理员需要在“系统设置 → 通用 → 登录项与扩展”批准，然后回到应用重试。Apple 的本机 SDK 要求包含 LaunchDaemon 的发布应用经过公证，并建议应用位于 `/Applications`；普通未公证 Debug 构建只能用于编译、签名和界面验证，不能视为可分发版本。

## 构建

```sh
git clone https://github.com/ChenZeBin/AIAwake.git
cd AIAwake
xcodegen generate
xcodebuild -project MacSleep.xcodeproj -scheme AIAwake -configuration Debug -derivedDataPath .build build
```

应用产物：

```text
.build/Build/Products/Debug/AIAwake.app
```

运行测试：

```sh
xcodebuild -project MacSleep.xcodeproj -scheme AIAwake -configuration Debug -derivedDataPath .build test
```
