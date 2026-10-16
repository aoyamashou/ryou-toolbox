# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概览

自用 macOS 工具箱：SwiftUI 窗口应用（侧边栏 + 详情），每个小工具是一个独立组件。无测试/lint 体系。

- 构建并打包：`./scripts/build-app.sh` → `build/RyouToolbox.app`（ad-hoc 签名，无 Sandbox，因为要调用外部 CLI）
- 仅编译：`swift build`
- 根目录的 `lark-user-bind.zsh`、`Tailscale IPv4 地址.command` 是原始脚本，App 里的功能由它们迁移而来（保留不动）。

## 架构

- `Sources/RyouToolbox/Core/Tool.swift`：`ToolRegistry.all` 是工具注册表，**新增工具只需新建视图并在此追加一项**。
- `Core/Shell.swift`：`Shell.run(命令, 参数)` 经 `/usr/bin/env` 异步执行外部命令。GUI 应用没有 shell 的 PATH，所以这里补全了 `/opt/homebrew/bin` 等，并设置 `LARKSUITE_CLI_NO_*_NOTIFIER`。
- `Tools/Tailscale`：`tailscale status --json` → Codable 解析（`Self`/`Peer` 是 Swift 保留词，需 CodingKeys 重命名）；只取 IPv4。SSH 开关由 `sshHostKeys` 非空推断；Tailscale 不对外提供其他节点的客户端版本，只能查本机版本并与 `pkgs.tailscale.com/stable/?mode=json` 的 `TarballsVersion` 比较。
- `Tools/Lark`（只读）：`lark-cli profile list` → 对每个 Profile 并发 `auth status --profile <n> --json --verify`。“有效 User”判定：`identity=="user" && verified && identities.user.tokenStatus=="valid"`，与 `lark-user-bind.zsh` 的 `verify_profile` 保持一致。
- Model 用 `@MainActor @Observable`（Swift 6 严格并发）。
