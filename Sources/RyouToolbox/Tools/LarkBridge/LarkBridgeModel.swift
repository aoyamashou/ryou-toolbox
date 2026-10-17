import Foundation
import Observation
import Darwin

// MARK: - 配置模型（~/.lark-channel/config.json，schemaVersion 2）

struct BridgeRoot: Decodable, Sendable {
    let schemaVersion: Int?
    let activeProfile: String?
    let profiles: [String: BridgeProfile]?
}

struct BridgeProfile: Decodable, Sendable {
    struct Accounts: Decodable, Sendable {
        struct App: Decodable, Sendable {
            let id: String?
            let tenant: String?
        }
        let app: App?
    }
    struct Access: Decodable, Sendable {
        let allowedUsers: [String]?
        let allowedChats: [String]?
        let admins: [String]?
        let requireMentionInGroup: Bool?
    }
    struct Permissions: Decodable, Sendable {
        let defaultAccess: String?
        let maxAccess: String?
    }
    struct Workspaces: Decodable, Sendable {
        let `default`: String?
    }
    struct Preferences: Decodable, Sendable {
        let messageReply: String?
        let cotMessages: String?
        let showToolCalls: Bool?
        let model: String?
    }
    struct LarkCli: Decodable, Sendable {
        let identityPreset: String?
    }

    let agentKind: String?
    let mode: String?
    let accounts: Accounts?
    let access: Access?
    let permissions: Permissions?
    let workspaces: Workspaces?
    let preferences: Preferences?
    let larkCli: LarkCli?
}

struct BridgeProfileSummary: Identifiable, Sendable {
    let name: String
    let agent: String
    let tenant: String
    let appId: String
    let mode: String
    let accessSummary: String
    let permission: String
    let larkCliIdentity: String
    let workspace: String
    var id: String { name }

    var tenantLabel: String {
        switch tenant {
        case "lark": return "Lark（国际版）"
        case "feishu": return "飞书（国内版）"
        default: return tenant
        }
    }
}

/// 正在运行的 bot（来自 ~/.lark-channel/registry/processes.json）
struct BridgeProcess: Identifiable, Sendable {
    let id: String
    let pid: Int
    let appId: String
    let tenant: String
    let profile: String
    let agent: String
    let startedAt: String
    let version: String
    let botName: String?
}

enum BridgePaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lark-channel")
    static let config = home.appendingPathComponent("config.json")
    static let activeProfile = home.appendingPathComponent("active-profile")
    static let registry = home.appendingPathComponent("registry/processes.json")
    static let hostUi = home.appendingPathComponent("ui.json")
    static let launchAgents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")

    static func profileDir(_ name: String) -> URL {
        home.appendingPathComponent("profiles/\(name)")
    }
    static func logsDir(_ name: String) -> URL {
        profileDir(name).appendingPathComponent("logs")
    }
    static func daemonLogs(_ name: String) -> URL {
        logsDir(name).appendingPathComponent("daemon")
    }
    static func servicePlist(_ name: String) -> URL {
        launchAgents.appendingPathComponent("ai.lark-channel-bridge.bot.\(name).plist")
    }
    /// 机器级 supervisor（`start --web-ui`）的 plist
    static var supervisorPlist: URL {
        launchAgents.appendingPathComponent("ai.lark-channel-bridge.bot.supervisor.plist")
    }
}

// MARK: - Model

@MainActor @Observable
final class LarkBridgeModel {
    var installed = false
    var version: String?
    var latestVersion: String?

    var profiles: [BridgeProfileSummary] = []
    var activeProfile: String?
    var processes: [BridgeProcess] = []
    var serviceInstalled = false
    var errorCount = 0
    var logFiles: [String] = []
    var selectedLog = ""
    var logLines: [String] = []
    var consoleURL: String?

    var error: String?
    var message: String?
    var busy = false
    var output: OutputItem?

    var nodeVersion: String?

    var hasUpdate: Bool {
        guard let v = version, let latest = latestVersion else { return false }
        return v.compare(latest, options: .numeric) == .orderedAscending
    }

    /// 还没有任何 profile 时必须先在终端扫码初始化，非交互的 `start` 会直接报错。
    var needsOnboarding: Bool { profiles.isEmpty }

    var versionNote: String? {
        guard installed, let v = version else { return nil }
        guard let latest = latestVersion else { return "无法检查最新版本" }
        if v.compare(latest, options: .numeric) == .orderedAscending { return "🔔 有新版本 \(latest)" }
        return "已是最新"
    }

    // MARK: 刷新

    func refresh() async {
        async let latest = Self.latestFromNPM()

        let v = await Shell.run("lark-channel-bridge", ["--version"])
        installed = v.status == 0
        version = installed ? Self.parseVersion(v.stdout) : nil
        latestVersion = await latest

        let nv = await Shell.run("node", ["--version"])
        nodeVersion = nv.status == 0 ? nv.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        guard installed else {
            profiles = []
            activeProfile = nil
            processes = []
            serviceInstalled = false
            errorCount = 0
            logFiles = []
            logLines = []
            error = "未找到 lark-channel-bridge 命令（需要 Node.js ≥ 20.12，然后 npm i -g lark-channel-bridge）"
            return
        }

        error = nil
        consoleURL = Self.readConsoleURL()
        loadConfig()
        loadProcesses()
        refreshServiceState()
        errorCount = Self.countErrors(profile: selectedProfileForLogs)
        await loadLogFiles()
        await refreshLogs()
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: BridgePaths.config),
              let root = try? JSONDecoder().decode(BridgeRoot.self, from: data) else {
            profiles = []
            activeProfile = nil
            return
        }
        activeProfile = (try? String(contentsOf: BridgePaths.activeProfile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? root.activeProfile

        let summary = (root.profiles ?? [:]).map { name, p -> BridgeProfileSummary in
            let users = p.access?.allowedUsers?.count ?? 0
            let chats = p.access?.allowedChats?.count ?? 0
            let admins = p.access?.admins?.count ?? 0
            var access: [String] = ["仅 owner"]
            if users > 0 { access.append("\(users) 个用户") }
            if chats > 0 { access.append("\(chats) 个群") }
            if admins > 0 { access.append("\(admins) 个管理员") }
            if p.access?.requireMentionInGroup == false { access.append("群里免 @") }
            return BridgeProfileSummary(
                name: name,
                agent: p.agentKind ?? "-",
                tenant: p.accounts?.app?.tenant ?? "-",
                appId: p.accounts?.app?.id ?? "-",
                mode: p.mode ?? "personal",
                accessSummary: access.joined(separator: " · "),
                permission: p.permissions?.defaultAccess ?? "-",
                larkCliIdentity: p.larkCli?.identityPreset ?? "-",
                workspace: p.workspaces?.default ?? "-")
        }
        profiles = summary.sorted { a, b in
            if a.name == activeProfile { return true }
            if b.name == activeProfile { return false }
            return a.name < b.name
        }
    }

    private func loadProcesses() {
        guard let data = try? Data(contentsOf: BridgePaths.registry),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["entries"] as? [[String: Any]] else {
            processes = []
            return
        }
        processes = raw.compactMap { item in
            guard let id = item["id"] as? String,
                  let pid = item["pid"] as? Int,
                  let profile = item["profileName"] as? String else { return nil }
            guard kill(Int32(pid), 0) == 0 else { return nil }   // 只留活着的
            return BridgeProcess(id: id,
                                 pid: pid,
                                 appId: item["appId"] as? String ?? "-",
                                 tenant: item["tenant"] as? String ?? "-",
                                 profile: profile,
                                 agent: item["agentKind"] as? String ?? "-",
                                 startedAt: item["startedAt"] as? String ?? "",
                                 version: item["version"] as? String ?? "-",
                                 botName: item["botName"] as? String)
        }
        .sorted { $0.profile < $1.profile }
    }

    private func refreshServiceState() {
        let candidates = [BridgePaths.supervisorPlist] + profiles.map { BridgePaths.servicePlist($0.name) }
        serviceInstalled = candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: 操作

    func run(_ args: [String], title: String, showSheet: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let r = await Shell.run("lark-channel-bridge", args)
        let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? r.stderr : r.stdout
        let text = Self.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        message = r.status == 0 ? "✅ \(title)完成" : "❌ \(title)失败（退出码 \(r.status)）"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        if r.status != 0 || (showSheet && lines > 1) {
            output = OutputItem(title: title, text: text.isEmpty ? "（无输出）" : text)
        }
        await refresh()
    }

    private func profileArgs(_ name: String?) -> [String] {
        guard let name, !name.isEmpty else { return [] }
        return ["--profile", name]
    }

    func start(profile name: String?) async {
        guard !needsOnboarding else {
            message = "还没有 profile，先在终端扫码初始化（已为你打开终端）"
            Terminal.run("lark-channel-bridge run --tenant lark")
            return
        }
        await run(["start"] + profileArgs(name ?? activeProfile),
                  title: "启动 \(name ?? activeProfile ?? "")", showSheet: true)
        await waitForConnect()
    }

    func stop(profile name: String?) async {
        guard !needsOnboarding else { return }
        await run(["stop"] + profileArgs(name ?? activeProfile),
                  title: "停止 \(name ?? activeProfile ?? "")", showSheet: true)
        try? await Task.sleep(for: .seconds(1))
        loadProcesses()
        refreshServiceState()
    }

    func restart(profile name: String?) async {
        guard !needsOnboarding else { return }
        let target = name ?? activeProfile
        // restart 要求服务已注册，否则用 stop + start
        if serviceInstalled {
            await run(["restart"] + profileArgs(target), title: "重启 \(target ?? "")", showSheet: true)
        } else {
            await run(["stop"] + profileArgs(target), title: "停止", showSheet: false)
            try? await Task.sleep(for: .seconds(1))
            await run(["start"] + profileArgs(target), title: "启动", showSheet: true)
        }
        await waitForConnect()
    }

    func status(profile name: String?) async {
        guard !needsOnboarding else {
            message = "还没有 profile，先在终端扫码初始化"
            return
        }
        await run(["status"] + profileArgs(name ?? activeProfile), title: "服务状态", showSheet: true)
    }

    func ps() async { await run(["ps"], title: "运行中的 bot", showSheet: true) }
    func profileList() async { await run(["profile", "list"], title: "Profile 列表", showSheet: true) }

    func useProfile(_ name: String) async {
        await run(["profile", "use", name], title: "切换 profile")
    }

    /// 归档 profile（不删数据，可用同名重建）。`profile remove` 本身不交互。
    func removeProfile(_ name: String) async {
        await run(["profile", "remove", name], title: "删除 profile \(name)", showSheet: true)
    }

    func unregister(profile name: String?) async {
        await run(["unregister"] + profileArgs(name), title: "注销后台服务", showSheet: true)
    }

    /// 后台服务启动后，进程注册表要等 WebSocket 握手才写入，轮询几次。
    private func waitForConnect(timeout: Double = 12) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(0.8))
            loadProcesses()
            if !processes.isEmpty {
                refreshServiceState()
                await loadLogFiles()
                await refreshLogs()
                return
            }
        }
        loadProcesses()
        refreshServiceState()
    }

    // MARK: 日志

    func loadLogFiles() async {
        let dir = BridgePaths.logsDir(selectedProfileForLogs)
        var names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // 附带 daemon 目录里的 stdout/stderr
        let daemon = BridgePaths.daemonLogs(selectedProfileForLogs)
        let daemonNames = (try? FileManager.default.contentsOfDirectory(atPath: daemon.path)) ?? []
        names = names.filter { $0.hasSuffix(".jsonl") }
            .sorted { Self.fileDate(dir, $0) > Self.fileDate(dir, $1) }
        logFiles = names + daemonNames.filter { !$0.hasPrefix(".") }
        if !logFiles.contains(selectedLog) {
            selectedLog = logFiles.first ?? ""
        }
    }

    /// 日志跟随「当前关注的 profile」：优先运行中的（多个则 active），其次有日志的，
    /// 最后才退回 active profile。
    var selectedProfileForLogs: String {
        let running = Set(processes.map(\.profile))
        if running.count == 1, let only = running.first { return only }
        if let active = activeProfile, running.contains(active) { return active }
        if let withLogs = profiles.first(where: { Self.hasLogs($0.name) })?.name { return withLogs }
        if let active = activeProfile, !active.isEmpty { return active }
        return profiles.first?.name ?? ""
    }

    static func hasLogs(_ profile: String) -> Bool {
        let dir = BridgePaths.logsDir(profile)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.hasSuffix(".jsonl") }
    }

    func refreshLogs() async {
        guard !selectedLog.isEmpty else {
            logLines = []
            return
        }
        let base = selectedLog.hasSuffix(".jsonl")
            ? BridgePaths.logsDir(selectedProfileForLogs)
            : BridgePaths.daemonLogs(selectedProfileForLogs)
        let path = base.appendingPathComponent(selectedLog).path
        let r = await Shell.run("tail", ["-n", "200", path])
        guard r.status == 0 else {
            logLines = ["无法读取日志：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]
            return
        }
        logLines = selectedLog.hasSuffix(".jsonl")
            ? r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(Self.renderJSONLine)
            : r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: 工具

    private static func fileDate(_ dir: URL, _ name: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.modificationDate] as? Date)
            ?? .distantPast
    }

    static func countErrors(profile: String) -> Int {
        let dir = BridgePaths.logsDir(profile)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let newest = names.filter { $0.hasSuffix(".jsonl") }
            .max { fileDate(dir, $0) < fileDate(dir, $1) }
        guard let newest,
              let text = try? String(contentsOf: dir.appendingPathComponent(newest), encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\"level\":\"error\"").count - 1
    }

    private static func readConsoleURL() -> String? {
        guard let data = try? Data(contentsOf: BridgePaths.hostUi),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["url"] as? String,
              let pid = obj["pid"] as? Int,
              kill(Int32(pid), 0) == 0 else { return nil }
        return url
    }

    nonisolated static func latestFromNPM() async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/lark-channel-bridge/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    static func parseVersion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.drop { !$0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
                                  with: "", options: .regularExpression)
    }

    /// JSONL 日志一行 → 「时间 级别 [phase.event] 关键字段」
    static func renderJSONLine(_ line: Substring) -> String {
        let raw = String(line)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
        let ts = (obj["ts"] as? String) ?? ""
        let time = ts.count >= 19 ? String(ts.dropFirst(11).prefix(8)) : ts
        let level = (obj["level"] as? String) ?? "info"
        let phase = (obj["phase"] as? String) ?? "-"
        let event = (obj["event"] as? String) ?? "-"
        var fields: [String] = []
        for key in ["botName", "chatId", "senderId", "profile", "cwd", "reason", "message", "error", "terminal", "durationMs", "count"] {
            guard let value = obj[key] else { continue }
            let text = "\(value)"
            if text.isEmpty || text == "<null>" { continue }
            let short = text.count > 60 ? String(text.prefix(60)) + "…" : text
            fields.append("\(key)=\(short)")
        }
        let mark = level == "error" ? "✗" : level == "warn" ? "⚠" : "·"
        let tail = fields.isEmpty ? "" : "  " + fields.joined(separator: " ")
        return "\(time) \(mark) [\(phase).\(event)]\(tail)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
