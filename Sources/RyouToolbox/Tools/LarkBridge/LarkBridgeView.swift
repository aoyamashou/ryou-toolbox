import SwiftUI
import AppKit

/// Lark Bridge 命令速查：所有命令都是「点一下 → 填进下方终端 → 检查后回车」。
/// 你只用 Lark 租户，需要租户参数的命令都固定带 `--tenant lark`。
struct LarkBridgeView: View {
    @State private var model = LarkBridgeModel()
    @State private var terminal = EmbeddedTerminal()

    private let repoURL = URL(string: "https://github.com/zarazhangrui/lark-coding-agent-bridge")!

    var body: some View {
        CommandPaletteView(
            groups: groups,
            terminal: terminal,
            terminalSubtitle: model.installed ? nil : "未安装 lark-channel-bridge",
            emptyHint: "未检测到 lark-channel-bridge。先在上面复制安装命令，装好后点「刷新」。",
            header: AnyView(header)
        )
        .navigationTitle("Lark Bridge")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem {
                Menu {
                    Button("打开配置目录") { NSWorkspace.shared.open(BridgePaths.home) }
                    Button("网页控制台") {
                        if let url = model.consoleURL, let u = URL(string: url) {
                            NSWorkspace.shared.open(u)
                        } else {
                            terminal.type("lark-channel-bridge ui")
                        }
                    }
                    Button("在系统 Terminal 中打开") { Terminal.run() }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .task {
            await model.refresh()
            if !terminal.running { terminal.start() }
        }
    }

    // MARK: 顶部状态（只读）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.processes.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                    .frame(width: 9, height: 9)
                Text(model.processes.isEmpty ? "未运行" : "运行中").font(.headline)
                if let active = model.activeProfile {
                    Text("active: \(active)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let v = model.version {
                    Text("v\(v)").font(.caption).monospaced().foregroundStyle(.secondary)
                    if model.hasUpdate, let latest = model.latestVersion {
                        Text("→ \(latest)").font(.caption).monospaced().foregroundStyle(.orange)
                    }
                }
            }

            if model.installed {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        label("在线 bot")
                        Text(model.processes.isEmpty
                             ? "无"
                             : model.processes.map { "\($0.botName ?? $0.appId)（\($0.profile)）" }.joined(separator: "、"))
                            .textSelection(.enabled)
                    }
                    GridRow {
                        label("后台服务")
                        Text(model.serviceInstalled
                             ? (model.processes.isEmpty ? "已注册 · 已停止" : "已注册 · 运行中")
                             : "未注册")
                    }
                    GridRow {
                        label("日志错误")
                        Text("\(model.errorCount)")
                            .foregroundStyle(model.errorCount > 0 ? .red : .secondary)
                    }
                    if !model.profiles.isEmpty {
                        GridRow {
                            label("Profiles")
                            Text(model.profiles.map { "\($0.name)（\($0.agent)）" }.joined(separator: "、"))
                        }
                    }
                }
                .font(.callout)
            }
            if let err = model.error {
                Text(err).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let m = model.message {
                Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let note = model.versionNote, model.installed {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
            if model.needsOnboarding, model.installed {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                    Text("还没有 profile：点下面「扫码初始化」，二维码会出现在下方终端里。")
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    // MARK: 命令表

    private var groups: [QuickCommandGroup] {
        guard model.installed else {
            return [
                QuickCommandGroup(
                    title: "安装",
                    subtitle: "需要 Node.js ≥ 20.12",
                    commands: [
                        QuickCommand(title: "npm 安装", command: "npm i -g lark-channel-bridge"),
                        QuickCommand(title: "pnpm 安装", command: "pnpm add -g lark-channel-bridge"),
                    ]
                )
            ]
        }

        var groups: [QuickCommandGroup] = []

        // 没 profile 时，把扫码初始化放最前面
        if model.needsOnboarding {
            groups.append(
                QuickCommandGroup(
                    title: "首次初始化（必须交互）",
                    subtitle: "二维码会出现在下方终端里",
                    commands: [
                        QuickCommand(title: "扫码创建应用（Claude Code）",
                                     command: "lark-channel-bridge run --agent claude --tenant lark",
                                     note: "出二维码后用 Lark App 扫，回车开始"),
                        QuickCommand(title: "扫码创建应用（Codex）",
                                     command: "lark-channel-bridge run --agent codex --tenant lark"),
                        QuickCommand(title: "已有 app-id 初始化",
                                     command: "lark-channel-bridge run --app-id cli_xxx --agent claude --tenant lark",
                                     needsArgument: true,
                                     note: "把 cli_xxx 换成你的应用 id"),
                        QuickCommand(title: "直接注册后台服务",
                                     command: "lark-channel-bridge start --agent claude --tenant lark"),
                    ]
                )
            )
        }

        groups.append(
            QuickCommandGroup(
                title: "运行与日志",
                commands: [
                    QuickCommand(title: "前台运行（Claude Code）",
                                 command: "lark-channel-bridge run --tenant lark"),
                    QuickCommand(title: "前台运行（Codex）",
                                 command: "lark-channel-bridge run --agent codex --tenant lark"),
                    QuickCommand(title: "网页控制台",
                                 command: "lark-channel-bridge run --web-ui --tenant lark",
                                 note: "机器级 supervisor + 本地网页控制台"),
                    QuickCommand(title: "打开网页控制台", command: "lark-channel-bridge ui"),
                    QuickCommand(title: "运行中的 bot", command: "lark-channel-bridge ps"),
                    QuickCommand(title: "查看 daemon 日志",
                                 command: "tail -f ~/.lark-channel/profiles/\(model.selectedProfileForLogs)/logs/daemon/daemon-stderr.log",
                                 note: "Ctrl+C 退出"),
                ]
            )
        )

        groups.append(
            QuickCommandGroup(
                title: "后台服务",
                commands: [
                    QuickCommand(title: "注册并启动", command: "lark-channel-bridge start --tenant lark"),
                    QuickCommand(title: "停止", command: "lark-channel-bridge stop"),
                    QuickCommand(title: "重启", command: "lark-channel-bridge restart"),
                    QuickCommand(title: "服务状态", command: "lark-channel-bridge status"),
                    QuickCommand(title: "注销服务", command: "lark-channel-bridge unregister",
                                 note: "删掉 plist 并停止，不影响配置"),
                ]
            )
        )

        var profileCommands: [QuickCommand] = [
            QuickCommand(title: "列出 profiles", command: "lark-channel-bridge profile list"),
        ]
        for p in model.profiles {
            profileCommands.append(
                QuickCommand(title: "切换为当前 · \(p.name)",
                             command: "lark-channel-bridge profile use \(p.name)",
                             note: "\(p.tenantLabel) · \(p.agent) · app \(p.appId)")
            )
        }
        profileCommands.append(
            QuickCommand(title: "新建 profile",
                         command: "lark-channel-bridge profile create --tenant lark ",
                         needsArgument: true,
                         note: "末尾补 profile 名，如 work")
        )
        for p in model.profiles {
            profileCommands.append(
                QuickCommand(title: "删除 profile · \(p.name)",
                             command: "lark-channel-bridge profile remove \(p.name)")
            )
        }
        groups.append(
            QuickCommandGroup(
                title: "Profiles",
                subtitle: model.profiles.isEmpty ? "还没有 profile" : nil,
                commands: profileCommands
            )
        )

        groups.append(
            QuickCommandGroup(
                title: "升级与清理",
                commands: [
                    QuickCommand(title: "npm 升级", command: "npm i -g lark-channel-bridge"),
                    QuickCommand(title: "迁移旧版配置", command: "lark-channel-bridge migrate"),
                ]
            )
        )
        return groups
    }
}
