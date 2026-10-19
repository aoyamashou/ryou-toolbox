# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概览

自用 macOS 工具箱：SwiftUI 窗口应用（侧边栏 + 详情），每个小工具是一个独立组件。无测试/lint 体系。

- 构建并打包：`./scripts/build-app.sh` → `build/RyouToolbox.app`（ad-hoc 签名，无 Sandbox，因为要调用外部 CLI）
- 仅编译：`swift build`
- 根目录的 `lark-user-bind.zsh`、`Tailscale IPv4 地址.command` 是原始脚本，App 里的功能由它们迁移而来（保留不动）。

## 架构

- `Sources/RyouToolbox/Core/Tool.swift`：`ToolRegistry.all` 是工具注册表，**新增工具只需新建视图并在此追加一项**。
- `Core/Shell.swift`：`Shell.run(命令, 参数)` 经 `/usr/bin/env` 异步执行外部命令。GUI 应用没有 shell 的 PATH，所以这里补全了 `~/.local/bin`（pipx/uv）、`/opt/homebrew/bin` 等，并设置 `LARKSUITE_CLI_NO_*_NOTIFIER`；stdin 接 nullDevice，避免子进程等待输入卡死。
- `Tools/Tailscale`：`tailscale status --json` → Codable 解析（`Self`/`Peer` 是 Swift 保留词，需 CodingKeys 重命名）；只取 IPv4。SSH 开关由 `sshHostKeys` 非空推断；Tailscale 不对外提供其他节点的客户端版本，只能查本机版本并与 `pkgs.tailscale.com/stable/?mode=json` 的 `TarballsVersion` 比较。
- `Tools/Lark`（只读）：`lark-cli profile list` → 对每个 Profile 并发 `auth status --profile <n> --json --verify`。“有效 User”判定：`identity=="user" && verified && identities.user.tokenStatus=="valid"`，与 `lark-user-bind.zsh` 的 `verify_profile` 保持一致。
- `Core/Terminal.swift`：`Terminal.run(命令)` 生成临时 `.command` 脚本再用 `open` 交给 Terminal（**兜底**用：需要真 Terminal 时才走这里）；`Terminal.copy` 管剪贴板。注意它的类型名 `Terminal` 与 SwiftTerm 的 `Terminal` 同名，用到 SwiftTerm 的地方要写 `SwiftTerm.Terminal`。
- `Core/EmbeddedTerminal.swift`：内嵌终端（SwiftTerm / `LocalProcessTerminalView`），交互式命令默认走这里，不再跳到系统 Terminal。做法同 Orca 的 `OnboardingInlineCommandTerminal`：建 PTY 起登录 shell → 轮询终端缓冲区等提示符出现（连续两次非空，800ms 兜底）→ `view.pasteText()` 写入命令（自动按 shell 的 bracketed paste 状态包裹）→ 等命令行上真的出现这段文字再 `view.send(...,\r)` 回车。**粘贴和回车必须分两步且等粘贴落地**，直接连着发会因为调度顺序变成「空回车」。**交互模型是「命令速查」**（同 Orca 设置面板）：页面 = 上方命令按钮表 + 下方常驻终端。点按钮只调 `terminal.type(cmd)` 把命令填进命令行，**不回车**；用户检查无误自己按回车。所以 `Core/CommandPalette.swift` 的 `CommandPaletteView` 负责按钮表（`QuickCommand` / `QuickCommandGroup`），每个页面持有自己的 `EmbeddedTerminal` 实例。
- `Core/CommandPalette.swift`：`CommandPaletteView`（命令按钮表 + 下方终端）、`QuickCommand`（title / command / needsArgument / note）、`QuickCommandGroup`。
- `Core/OutputSheet.swift`：`OutputItem` / `OutputSheet`（命令输出弹窗）。
- `Tools/Ductor`：Ductor（PyPI 包，把 Claude Code / Codex / Gemini CLI 接到 Telegram/Matrix/Slack）。**纯只读状态 + 命令速查**：`DuctorModel` 只负责读 `~/.ductor/`（`config/config.json`、`logs/*.log`、`bot.pid`）＋ `launchctl list dev.ductor` 并展示状态，**不再执行任何 ductor 子命令**；所有操作都做成 `QuickCommand` 按钮，点一下把命令填进下方终端，用户自己回车。这样 `onboarding` / `uninstall` / `upgrade` 这类交互式或会与 launchd 抢的命令都不需要在 App 里特殊处理。日志用 `tail -n 200` 读，`docker enable/disable` 只改配置，需重启生效。
- `Tools/LarkBridge`：lark-channel-bridge（Lark ↔ 本机 Claude Code / Codex CLI 的桥）。状态读 `~/.lark-channel/`：`config.json`（schemaVersion 2，profiles 里含 `accounts.app.tenant`、`access`、`permissions`、`workspaces`）、`active-profile`、`registry/processes.json`（在线 bot，按 `kill(pid,0)` 过滤）＋ `~/Library/LaunchAgents/ai.lark-channel-bridge.bot.<profile>.plist` 判断服务是否注册。日志是 `profiles/<p>/logs/bridge-YYYYMMDD.jsonl`（结构化：ts/level/phase/event），在 App 里就地渲染成 `时间 · [phase.event] 字段`，不是直接打印原始 JSON；daemon 的 stdout/stderr 在 `logs/daemon/`。**纯只读状态 + 命令速查**，`LarkBridgeModel` 不再执行子命令；首次初始化必须交互（要扫二维码、选 agent），所以没有 profile 时把 `run --agent <claude|codex> --tenant lark` 放在命令表最前面。用户只用 Lark 租户，所有需要租户参数的命令都固定带 `--tenant lark`；但 `--tenant` 只被 `run` / `start` / `profile create` 接受，加在 `stop` / `status` / `ps` / `ui` 上会报 unknown option。机器上同时装了 claude 和 codex，`run` 不指定 `--agent` 会直接报错退出。命令表覆盖 `start/stop/restart/status/unregister`、`ps`、`profile list/use/create/remove`、`ui`、`run --web-ui`、`migrate`。
- Model 用 `@MainActor @Observable`（Swift 6 严格并发）；`EmbeddedTerminal` 因为要传给 `@ObservedObject`，用 `ObservableObject`。
