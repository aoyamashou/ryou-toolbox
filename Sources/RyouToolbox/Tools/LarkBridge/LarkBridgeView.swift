import SwiftUI
import AppKit

/// Lark（国际版）× 本机 coding agent 的桥：lark-channel-bridge（社区工具）。
/// 你只用 Lark 租户，所以所有需要租户参数的命令都固定带 `--tenant lark`。
struct LarkBridgeView: View {
    @State private var model = LarkBridgeModel()
    @State private var pendingUnregister: String?
    @State private var pendingRemove: String?
    @State private var confirmInstall = false
    /// 新建 profile 时先问名字（`profile create <name>` 的 name 是必填参数）
    @State private var showNewProfile = false
    /// 初始化时要选 agent：机器上同时装了 claude 和 codex，`run` 不指定会直接报错
    @State private var onboardingAgent = "claude"
    /// 页面底部的内嵌终端（点按钮时展开并自动输入命令）
    @State private var terminal: EmbeddedTerminal?

    private let repoURL = URL(string: "https://github.com/zarazhangrui/lark-coding-agent-bridge")!

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
                        if model.needsOnboarding { onboardingCard }
                        runningCard
                        profilesCard
                        actionsCard
                        logsCard
                    }
                    .padding(14)
                }
            }
        }
        .navigationTitle("Lark Bridge")
        .inlineTerminal($terminal, title: "lark-channel-bridge", subtitle: "命令已填好，回车执行")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
            }
            ToolbarItem {
                Menu {
                    Button("打开内嵌终端（不执行命令）") { openTerminal() }
                    Button("前台运行 bridge（首次扫码向导）") { openTerminal("lark-channel-bridge run --agent \(onboardingAgent) --tenant lark") }
                    Divider()
                    Button("网页控制台（--web-ui）") { openTerminal("lark-channel-bridge run --web-ui --tenant lark") }
                    Button("查看 daemon 日志") {
                        openTerminal("tail -f ~/.lark-channel/profiles/\(model.selectedProfileForLogs)/logs/daemon/daemon-stderr.log")
                    }
                    Divider()
                    Button("在系统 Terminal 中打开") { Terminal.run() }
                } label: {
                    Label("终端", systemImage: "terminal")
                }
                .help("交互式命令（扫码初始化等）在页面底部的内嵌终端里执行")
            }
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
        .onAppear {
            // 没有 profile 时点「启动」也会走页面底部的内嵌终端，而不是跳去 Terminal.app
            model.openOnboarding = { command in
                openTerminal(command, autoSubmit: true)
            }
        }
        .sheet(item: $model.output) { OutputSheet(item: $0) }
        .sheet(isPresented: $showNewProfile) {
            NewBridgeProfileSheet { name in
                showNewProfile = false
                openTerminal("lark-channel-bridge profile create --tenant lark \(name)")
            }
        }
        .confirmationDialog("注销 “\(pendingUnregister ?? "")” 的后台服务？（不会删除配置和会话）",
                            isPresented: Binding(get: { pendingUnregister != nil },
                                                 set: { if !$0 { pendingUnregister = nil } }),
                            titleVisibility: .visible) {
            Button("注销", role: .destructive) {
                let name = pendingUnregister
                Task { await model.unregister(profile: name) }
            }
        }
        .confirmationDialog("删除 profile “\(pendingRemove ?? "")”？会停掉它的服务并归档本地状态。",
                            isPresented: Binding(get: { pendingRemove != nil },
                                                 set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let name = pendingRemove
                Task {
                    await model.stop(profile: name)
                    if let name { await model.removeProfile(name) }
                }
            }
        }
        .confirmationDialog("在终端里执行安装？", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("在终端执行") { Task { await install() } }
        } message: {
            Text("会执行 npm i -g lark-channel-bridge（需要 Node.js ≥ 20.12）。")
        }
    }

    // MARK: 未安装

    private var installPane: some View {
        VStack(spacing: 14) {
            ContentUnavailableView("未检测到 lark-channel-bridge",
                                   systemImage: "shippingbox",
                                   description: Text("把 Lark 消息接通本机 Claude Code / Codex CLI。需要 Node.js ≥ 20.12。"))
            VStack(alignment: .leading, spacing: 8) {
                Text("官方安装命令（点右边按钮复制）").font(.callout).bold()
                CommandRow(command: "npm i -g lark-channel-bridge")
                CommandRow(command: "pnpm add -g lark-channel-bridge")
                Text("装好后首次运行 `lark-channel-bridge run --tenant lark` 会出二维码，用 Lark App 扫码创建 / 选择 PersonalAgent 应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button("在终端执行安装") { confirmInstall = true }
                    .buttonStyle(.borderedProminent)
                Button("在终端手动操作") { openTerminal() }
                Link("GitHub 仓库", destination: repoURL)
            }
            if let node = model.nodeVersion {
                Text("已检测到 Node \(node)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.installed == false, model.error != nil {
                Text("没检测到 node，请先安装 Node.js ≥ 20.12（brew install node）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.processes.isEmpty ? .orange : .green)
                    .frame(width: 10, height: 10)
                Text(model.processes.isEmpty ? "未运行" : "运行中")
                    .font(.headline)
                if let active = model.activeProfile {
                    Text("active: \(active)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let v = model.version {
                    Text("v\(v)").font(.caption).monospaced().foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("在线 bot").foregroundStyle(.secondary)
                    Text(model.processes.isEmpty
                         ? "无"
                         : model.processes.map { "\($0.botName ?? $0.appId)（\($0.profile)）" }.joined(separator: "、"))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("后台服务").foregroundStyle(.secondary)
                    Text(model.serviceInstalled
                         ? (model.processes.isEmpty ? "已注册 · 已停止" : "已注册 · 运行中")
                         : "未注册（现在只能前台跑）")
                }
                GridRow {
                    Text("日志错误").foregroundStyle(.secondary)
                    Text("\(model.errorCount)")
                        .foregroundStyle(model.errorCount > 0 ? .red : .secondary)
                }
                if let console = model.consoleURL {
                    GridRow {
                        Text("网页控制台").foregroundStyle(.secondary)
                        Link(console, destination: URL(string: console) ?? repoURL)
                            .lineLimit(1)
                    }
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

    // MARK: 首次初始化（Lark 租户）

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "qrcode")
                Text("还差一步：扫码创建 PersonalAgent 应用").font(.headline)
            }
            Text("首次初始化必须交互（会出二维码），所以在页面底部的内嵌终端里跑，命令已带上 `--tenant lark`。")
                .font(.callout).foregroundStyle(.secondary)

            // 这台机器同时装了 claude 和 codex，`run` 不指定 --agent 会直接报错退出。
            HStack(spacing: 8) {
                Text("agent").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $onboardingAgent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("方式一 · 扫码自动创建应用（推荐）").font(.caption).bold()
                CommandRow(command: "lark-channel-bridge run --agent \(onboardingAgent) --tenant lark")
                Text("方式二 · 已有 PersonalAgent 应用（cli_ 开头）").font(.caption).bold()
                CommandRow(command: "lark-channel-bridge run --app-id cli_xxx --agent \(onboardingAgent) --tenant lark")
                Text("方式三 · 直接注册成开机自启的后台服务").font(.caption).bold()
                CommandRow(command: "lark-channel-bridge start --agent \(onboardingAgent) --tenant lark")
            }
            HStack(spacing: 12) {
                Button("在内嵌终端扫码初始化") {
                    openTerminal("lark-channel-bridge run --agent \(onboardingAgent) --tenant lark", autoSubmit: true)
                }
                .buttonStyle(.borderedProminent)
                Button("用已有 app-id 初始化") {
                    // app-id / agent / 租户都填好，用户只需把 cli_xxx 换掉
                    openTerminal("lark-channel-bridge run --app-id cli_xxx --agent \(onboardingAgent) --tenant lark")
                }
                Link("中文文档", destination: URL(string: "https://github.com/zarazhangrui/lark-coding-agent-bridge/blob/main/README.zh.md")!)
            }
            Text("初始化完成后，profile 会写进 ~/.lark-channel/config.json 并自动出现在这一页，之后所有运维操作都能直接在这里点。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25))
        }
    }

    // MARK: 运行中的 bot

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("运行中的 bot").font(.headline)
                Spacer()
                Button { Task { await model.ps() } } label: {
                    Label("查看 ps", systemImage: "list.bullet")
                }
                .controlSize(.small)
            }
            if model.processes.isEmpty {
                Text("当前没有 bot 在运行。点下面的「启动」或在终端跑 `lark-channel-bridge run --tenant lark`。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.processes) { p in
                    HStack(spacing: 8) {
                        Text(p.botName ?? "（未握手）").font(.callout).bold()
                        Text(p.appId).font(.caption).monospaced().foregroundStyle(.secondary)
                        chip(p.tenant == "lark" ? "Lark" : p.tenant,
                             p.tenant == "lark" ? .blue : .orange)
                        chip(p.agent, .purple)
                        Text("profile \(p.profile)").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("pid \(p.pid)").font(.caption).monospaced().foregroundStyle(.secondary)
                        Text(p.version).font(.caption2).monospaced().foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Profile

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button { Task { await model.profileList() } } label: {
                    Label("profile list", systemImage: "list.bullet.indent")
                }
                .controlSize(.small)
                Button { showNewProfile = true } label: {
                    Label("新建", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if model.profiles.isEmpty {
                Text("还没有 profile。点右上角「新建」或跑一次 `lark-channel-bridge run --tenant lark` 扫码创建。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.profiles) { p in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.name).font(.callout).bold()
                                if p.name == model.activeProfile {
                                    chip("当前", .blue)
                                }
                                chip(p.tenantLabel, p.tenant == "lark" ? .blue : .green)
                                chip(p.agent, .purple)
                                if p.mode == "team" { chip("团队模式", .orange) }
                            }
                            Text("app \(p.appId) · \(p.accessSummary) · 权限 \(p.permission) · lark-cli \(p.larkCliIdentity)")
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("工作目录 \(p.workspace)")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("启动") { Task { await model.start(profile: p.name) } }
                            .disabled(model.busy)
                        Button("停止") { Task { await model.stop(profile: p.name) } }
                            .disabled(model.busy)
                        Button("状态") { Task { await model.status(profile: p.name) } }
                            .disabled(model.busy)
                        Button("设为当前") { Task { await model.useProfile(p.name) } }
                            .disabled(p.name == model.activeProfile)
                        Button("注销服务") { pendingUnregister = p.name }
                            .disabled(!FileManager.default.fileExists(atPath: BridgePaths.servicePlist(p.name).path))
                        Button(role: .destructive) { pendingRemove = p.name } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(.vertical, 3)
                    if p.id != model.profiles.last?.id { Divider() }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 操作

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运维操作").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                action("启动当前", "play.fill") { await model.start(profile: nil) }
                action("停止当前", "stop.fill", role: .destructive) { await model.stop(profile: nil) }
                action("重启当前", "arrow.triangle.2.circlepath") { await model.restart(profile: nil) }
                action("服务状态", "stethoscope") { await model.status(profile: nil) }
                action("运行中的 bot", "list.bullet") { await model.ps() }
                action("打开控制台", "safari") { openConsole() }
                action("打开配置目录", "folder") {
                    NSWorkspace.shared.open(BridgePaths.home)
                }
                upgradeAction
                action("前台运行（扫码）", "qrcode") {
                    openTerminal("lark-channel-bridge run --agent \(onboardingAgent) --tenant lark", autoSubmit: true)
                }
            }
            Text("扫码初始化、profile create/remove、web 控制台这类交互命令在「终端」菜单或内嵌终端里执行。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var upgradeAction: some View {
        Button {
            openTerminal("npm i -g lark-channel-bridge", autoSubmit: true)
            Task { try? await Task.sleep(for: .seconds(25)); await model.refresh() }
        } label: {
            Label(model.hasUpdate ? "升级到 \(model.latestVersion ?? "最新")" : "升级",
                  systemImage: "arrow.up.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .help("在终端里执行 npm i -g lark-channel-bridge")
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

    private func openConsole() {
        if let url = model.consoleURL, let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        } else {
            openTerminal("lark-channel-bridge ui", autoSubmit: true)
        }
    }

    /// 在页面底部展开内嵌终端并输入命令（默认只填不回车，方便先改参数）。
    private func openTerminal(_ command: String = "", autoSubmit: Bool = false) {
        openInlineTerminal($terminal, command: command, autoSubmit: autoSubmit)
    }

    // MARK: 日志

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("日志").font(.headline)
                Text(model.selectedProfileForLogs)
                    .font(.caption).foregroundStyle(.secondary)
                if !model.logFiles.isEmpty {
                    Picker("", selection: Binding(
                        get: { model.selectedLog },
                        set: { model.selectedLog = $0; Task { await model.refreshLogs() } })) {
                        ForEach(model.logFiles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Spacer()
                Button { Task { await model.refreshLogs() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.open(BridgePaths.logsDir(model.selectedProfileForLogs))
                } label: {
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
                                .foregroundStyle(line.contains("✗") || line.contains(" error")
                                                 ? .red
                                                 : line.contains("⚠") ? .orange : .primary)
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
            .frame(height: 210)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 安装

    private func install() async {
        openTerminal("npm i -g lark-channel-bridge", autoSubmit: true)
        try? await Task.sleep(for: .seconds(20))
        await model.refresh()
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
    }
}

/// 新建 profile 前先问名字：`profile create <name>` 的 name 是必填参数，缺了会报 missing required argument。
struct NewBridgeProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 Profile").font(.headline)
            Text("profile 名只用字母、数字、连字符，例如 `work`、`personal`。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("profile 名", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("命令：lark-channel-bridge profile create --tenant lark \(name.isEmpty ? "<name>" : name)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
