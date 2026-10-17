import SwiftUI
import AppKit

struct DuctorView: View {
    @State private var model = DuctorModel()
    @State private var pendingUninstall = false
    @State private var confirmTerminal = false
    /// 页面底部的内嵌终端（点按钮时展开并自动输入命令）
    @State private var terminal: EmbeddedTerminal?

    var body: some View {
        VStack(spacing: 0) {
            if !model.installed {
                installPane
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statusCard
                        if let note = model.versionNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        actionCard
                        if !model.agents.isEmpty { agentsCard }
                        logsCard
                    }
                    .padding(14)
                }
            }
        }
        .navigationTitle("Ductor")
        .inlineTerminal($terminal, title: "ductor", subtitle: "命令已填好，回车执行")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading || model.busy)
            }
            ToolbarItem {
                Menu {
                    Button("打开内嵌终端（不执行命令）") { openTerminal(shellOnly: true) }
                    if !model.serviceInstalled {
                        Button("运行 ductor（前台）") { openTerminal(script: "ductor") }
                    }
                    Button("重新运行 onboarding") { openTerminal(script: "ductor onboarding") }
                    Button("配置子代理（agents add）") { openTerminal(script: "ductor agents add") }
                    Divider()
                    Button("在系统 Terminal 中打开") { Terminal.run() }
                } label: {
                    Label("终端", systemImage: "terminal")
                }
                .help("在页面底部的内嵌终端里执行交互式命令")            }
        }
        .overlay {
            if model.busy {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("正在执行…").padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task { await model.refresh() }
        .sheet(item: $model.output) { item in
            OutputSheet(item: item)
        }
        .confirmationDialog("彻底卸载 Ductor？会停止服务、删除 ~/.ductor 工作区并卸载 pip 包。",
                            isPresented: $pendingUninstall, titleVisibility: .visible) {
            Button("卸载", role: .destructive) {
                Task { await openInTerminal("ductor uninstall") }
            }
        }
        .confirmationDialog("将在终端里执行安装命令，确认？",
                            isPresented: $confirmTerminal, titleVisibility: .visible) {
            Button("在终端执行") {
                Task { await openInTerminal(model.installCommand) }
            }
        } message: {
            Text("安装过程可能有交互提示，命令会在 Terminal 里执行。")
        }
    }

    // MARK: 未安装

    private var installPane: some View {
        VStack(spacing: 14) {
            ContentUnavailableView("未检测到 Ductor", systemImage: "shippingbox",
                                   description: Text("Ductor 是一个把 Claude Code / Codex / Gemini CLI 接到 Telegram / Matrix / Slack 的运维层。要求 Python 3.11+，推荐用 pipx 或 uv 安装。"))
            VStack(alignment: .leading, spacing: 8) {
                Text("官方安装命令（点右边按钮复制，粘到终端执行）").font(.callout).bold()
                ForEach(["pipx install ductor", "uv tool install ductor"], id: \.self) { cmd in
                    CommandRow(command: cmd)
                }
                Text("装完后在终端运行 `ductor`，向导会让你选 Telegram token、允许的用户、时区和可选 Docker 等。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button("在终端执行安装") { confirmTerminal = true }
                    .buttonStyle(.borderedProminent)
                Button("在终端手动操作") { openTerminal(shellOnly: true) }
                Link("GitHub 仓库", destination: URL(string: "https://github.com/PleasePrompto/ductor")!)
            }
            if let installer = model.availableInstaller {
                Text("检测到 \(installer)，点「在终端执行安装」会用它执行 \(model.installCommand)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.loading {
                Text("没检测到 pipx / uv，先安装其中之一（brew install pipx 或 brew install uv），或手动复制上面的命令。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let err = model.error {
                Text(err).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.running ? .green : .orange).frame(width: 10, height: 10)
                Text(model.running ? "运行中" : "未运行").font(.headline)
                if let pid = model.pid, model.running {
                    Text("pid=\(String(pid))").font(.caption).foregroundStyle(.secondary)
                }
                if model.running, !model.uptime.isEmpty {
                    Text("uptime: \(model.uptime)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let v = model.version {
                    Text("v\(v)").font(.caption).monospaced().foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    label("Provider"); Text(model.providerLabel)
                }
                GridRow {
                    label("Transport"); Text(model.transportLabel)
                }
                GridRow {
                    label("Docker"); Text(model.dockerEnabled ? "enabled" : "disabled")
                        .foregroundStyle(model.dockerEnabled ? .primary : .secondary)
                }
                GridRow {
                    label("后台服务")
                    Text(model.serviceLabel)
                }
                GridRow {
                    label("日志错误"); Text("\(model.errorCount)").foregroundStyle(model.errorCount > 0 ? .red : .secondary)
                }
            }
            .font(.callout)
            if let err = model.error {
                Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let m = model.message {
                Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    // MARK: 操作

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运维操作").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                if model.serviceInstalled {
                    action("启动服务", "play.fill") { await model.start() }
                    action("停止服务", "stop.fill", role: .destructive) { await model.stop() }
                    action("重启服务", "arrow.triangle.2.circlepath") { await model.restart() }
                } else {
                    action("在终端启动", "play.fill") { openTerminal() }
                    action("停止", "stop.fill", role: .destructive) { await model.stop() }
                    action("安装后台服务", "arrow.down.to.line") { await model.installService() }
                }
                action("运行诊断", "stethoscope") { await model.status() }
                upgradeAction
                action(model.dockerEnabled ? "关闭 Docker" : "启用 Docker",
                       "shippingbox") { await model.toggleDocker() }
                action("子代理列表", "person.2") { await model.listAgents() }
                if model.serviceInstalled {
                    action("卸载后台服务", "eject", role: .destructive) { await model.uninstallService() }
                }
                action("重新运行向导", "wand.and.stars") { openTerminal(script: "ductor onboarding") }
                action("彻底卸载", "trash", role: .destructive) { pendingUninstall = true }
            }
            Text("交互式命令（onboarding / 卸载 / agents add 等）请点右上角「终端」菜单。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 升级会让 ductor 自停、装新包、再 exec 自己，在 launchd 里容易跟 KeepAlive 抢，
    /// 所以放到终端里跑。
    private var upgradeAction: some View {
        Button {
            openTerminal(script: "ductor upgrade")
            Task { try? await Task.sleep(for: .seconds(20)); await model.refresh() }
        } label: {
            Label(model.hasUpdate ? "升级到 \(model.latestVersion ?? "最新")" : "升级",
                  systemImage: "arrow.up.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help("在终端里执行 ductor upgrade")
    }

    private func action(_ title: String, _ icon: String, role: ButtonRole? = nil,
                        _ run: @escaping () async -> Void) -> some View {
        Button(role: role) {
            Task { await run() }
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(model.busy)
    }

    private var agentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("子代理（agents.json）").font(.headline)
            ForEach(model.agents) { a in
                HStack(spacing: 8) {
                    Text(a.name).font(.callout).bold()
                    Text("\(a.provider ?? "inherited") · \(a.model ?? "inherited")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 日志

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("日志").font(.headline)
                if !model.logFiles.isEmpty {
                    Picker("", selection: Binding(
                        get: { model.selectedLog },
                        set: { model.selectedLog = $0; Task { await model.refreshLogs() } })) {
                        ForEach(model.logFiles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                Spacer()
                Button { Task { await model.refreshLogs() } } label: {
                    Label("刷新日志", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button { NSWorkspace.shared.open(DuctorPaths.logs) } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .controlSize(.small)
            }
            ScrollView(.vertical) {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.contains(" ERROR ") ? .red :
                                                 line.contains(" WARNING ") ? .orange : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(8)
                    .onChange(of: model.logLines.count) { _, count in
                        guard count > 0 else { return }
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                    .onAppear {
                        guard !model.logLines.isEmpty else { return }
                        proxy.scrollTo(model.logLines.count - 1, anchor: .bottom)
                    }
                }
            }
            .frame(height: 200)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 终端

    private func openTerminal(script: String? = nil, shellOnly: Bool = false) {
        openInlineTerminal($terminal,
                           command: shellOnly ? "" : (script ?? "ductor"),
                           autoSubmit: !shellOnly)
    }

    private func openInTerminal(_ cmd: String) async {
        openInlineTerminal($terminal, command: cmd, autoSubmit: true)
        // 安装/卸载是长任务，稍后再刷新一次
        try? await Task.sleep(for: .seconds(3))
        await model.refresh()
    }
}
