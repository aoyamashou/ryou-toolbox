import SwiftUI
import AppKit

/// Ductor 命令速查：所有命令都是「点一下 → 填进下方终端 → 检查后回车」。
/// 和 Orca 设置面板一致，点击不自动执行。
struct DuctorView: View {
    @State private var model = DuctorModel()
    @State private var terminal = EmbeddedTerminal()

    var body: some View {
        CommandPaletteView(
            groups: groups,
            terminal: terminal,
            terminalSubtitle: terminalSubtitle,
            emptyHint: "未检测到 ductor。先在上面复制安装命令，装好后点「刷新」。",
            header: AnyView(header)
        )
        .navigationTitle("Ductor")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading)
            }
            ToolbarItem {
                Button {
                    NSWorkspace.shared.open(DuctorPaths.home)
                } label: {
                    Label("配置目录", systemImage: "folder")
                }
            }
        }
        .task {
            await model.refresh()
            if !terminal.running { terminal.start() }
        }
    }

    private var terminalSubtitle: String? {
        model.installed ? nil : "未安装 ductor"
    }

    // MARK: 顶部状态（只读，不抢命令区的位置）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text(model.running ? "运行中" : "未运行").font(.headline)
                if let pid = model.pid, model.running {
                    Text("pid=\(String(pid))").font(.caption).monospaced().foregroundStyle(.secondary)
                }
                if model.running, !model.uptime.isEmpty {
                    Text("uptime \(model.uptime)").font(.caption).foregroundStyle(.secondary)
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
                    GridRow { label("Provider"); Text(model.providerLabel) }
                    GridRow { label("Transport"); Text(model.transportLabel) }
                    GridRow {
                        label("Docker")
                        Text(model.dockerEnabled ? "enabled" : "disabled")
                            .foregroundStyle(model.dockerEnabled ? .primary : .secondary)
                    }
                    GridRow { label("后台服务"); Text(model.serviceLabel) }
                    GridRow {
                        label("日志错误")
                        Text("\(model.errorCount)").foregroundStyle(model.errorCount > 0 ? .red : .secondary)
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
            if !model.logLines.isEmpty {
                logPreview
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    /// 日志预览：只显示最后几行，避免占满命令区。
    private var logPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近日志").font(.caption).bold().foregroundStyle(.secondary)
                if !model.logFiles.isEmpty {
                    Picker("", selection: Binding(
                        get: { model.selectedLog },
                        set: { model.selectedLog = $0; Task { await model.refreshLogs() } })) {
                        ForEach(model.logFiles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 150).controlSize(.small)
                }
                Spacer()
                Button { Task { await model.refreshLogs() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small).buttonStyle(.plain)
            }
            Text(model.logLines.suffix(6).joined(separator: "\n"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 命令表

    private var groups: [QuickCommandGroup] {
        guard model.installed else {
            return [
                QuickCommandGroup(
                    title: "安装",
                    subtitle: "需要 Python 3.11+，推荐 pipx 或 uv",
                    commands: [
                        QuickCommand(title: "pipx 安装", command: "pipx install ductor"),
                        QuickCommand(title: "uv 安装", command: "uv tool install ductor"),
                        QuickCommand(title: "首次配置向导", command: "ductor onboarding",
                                     note: "选 Telegram token、允许的用户、时区、Docker 等"),
                    ]
                )
            ]
        }

        var groups: [QuickCommandGroup] = [
            QuickCommandGroup(
                title: "运行",
                subtitle: "前台进程；交互式向导会在这里出提示",
                commands: [
                    QuickCommand(title: "启动（未配置则进向导）", command: "ductor"),
                    QuickCommand(title: "首次配置向导", command: "ductor onboarding", note: "会清空现有配置，谨慎"),
                    QuickCommand(title: "停止", command: "ductor stop"),
                    QuickCommand(title: "重启", command: "ductor restart"),
                    QuickCommand(title: "查看状态", command: "ductor status"),
                ]
            ),
            QuickCommandGroup(
                title: "后台服务（launchd）",
                commands: [
                    QuickCommand(title: "安装并启动服务", command: "ductor service install"),
                    QuickCommand(title: "服务状态", command: "ductor service status"),
                    QuickCommand(title: "启动服务", command: "ductor service start"),
                    QuickCommand(title: "停止服务", command: "ductor service stop"),
                    QuickCommand(title: "查看服务日志", command: "ductor service logs"),
                    QuickCommand(title: "卸载服务", command: "ductor service uninstall"),
                ]
            ),
            QuickCommandGroup(
                title: "子智能体",
                commands: [
                    QuickCommand(title: "列出子智能体", command: "ductor agents list"),
                    QuickCommand(title: "新建子智能体", command: "ductor agents add ", needsArgument: true,
                                 note: "在末尾补上名字，如 work"),
                ]
            ),
            QuickCommandGroup(
                title: "Docker 沙箱",
                subtitle: "enable / disable 只改配置，需重启生效",
                commands: [
                    QuickCommand(title: "启用沙箱", command: "ductor docker enable"),
                    QuickCommand(title: "停用沙箱", command: "ductor docker disable"),
                    QuickCommand(title: "挂载目录", command: "ductor docker mount ", needsArgument: true,
                                 note: "末尾补主机目录路径"),
                    QuickCommand(title: "移除挂载", command: "ductor docker unmount ", needsArgument: true),
                    QuickCommand(title: "列出挂载", command: "ductor docker mounts"),
                    QuickCommand(title: "可用软件包", command: "ductor docker extras"),
                    QuickCommand(title: "重建容器与镜像", command: "ductor docker rebuild",
                                 note: "下次启动时重建"),
                ]
            ),
            QuickCommandGroup(
                title: "升级与清理",
                commands: [
                    QuickCommand(title: "升级并重启", command: "ductor upgrade",
                                 note: "会自停后 exec 自己，在 launchd 下容易与 KeepAlive 争抢"),
                    QuickCommand(title: "清除配置并重设", command: "ductor reset"),
                    QuickCommand(title: "彻底卸载", command: "ductor uninstall",
                                 note: "移除程序与本地数据"),
                ]
            ),
        ]

        // 有更新时把「升级」提到最前面，省得每次翻
        if model.hasUpdate {
            groups.insert(
                QuickCommandGroup(
                    title: "更新可用",
                    subtitle: "PyPI 上已有 \(model.latestVersion ?? "新版")",
                    commands: [
                        QuickCommand(title: "pipx 升级", command: "pipx upgrade ductor"),
                        QuickCommand(title: "uv 升级", command: "uv tool upgrade ductor"),
                        QuickCommand(title: "ductor 自带升级", command: "ductor upgrade"),
                    ]
                ),
                at: 0
            )
        }
        return groups
    }
}
