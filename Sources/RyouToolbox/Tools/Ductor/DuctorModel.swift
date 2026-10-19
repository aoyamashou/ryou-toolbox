import Foundation
import Observation
import Darwin

// MARK: - 配置 / 数据模型

struct DuctorConfig: Decodable, Sendable {
    struct DockerConfig: Decodable, Sendable {
        let enabled: Bool?
        let containerName: String?
        enum CodingKeys: String, CodingKey {
            case enabled
            case containerName = "container_name"
        }
    }

    let provider: String?
    let model: String?
    let transport: String?
    let transports: [String]?
    let docker: DockerConfig?
    let language: String?
    let timezone: String?
}

struct DuctorAgent: Identifiable, Sendable {
    let name: String
    let provider: String?
    let model: String?
    var id: String { name }
}

enum DuctorPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ductor")
    static let config = home.appendingPathComponent("config/config.json")
    static let agents = home.appendingPathComponent("agents.json")
    static let logs = home.appendingPathComponent("logs")
    static let pid = home.appendingPathComponent("bot.pid")
    static let servicePlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/dev.ductor.plist")
}

// MARK: - Model

@MainActor @Observable
final class DuctorModel {
    var installed = false
    var version: String?
    var latestVersion: String?
    var availableInstaller: String?   // "pipx" / "uv" / nil
    var running = false
    var pid: Int32?
    var uptime = ""
    var config: DuctorConfig?
    var agents: [DuctorAgent] = []
    var serviceInstalled = false
    var serviceLoaded = false
    var errorCount = 0
    var logFiles: [String] = []
    var selectedLog = "agent.log"
    var logLines: [String] = []
    var error: String?
    var message: String?
    var loading = false

    var serviceLabel: String {
        guard serviceInstalled else { return "未安装" }
        if serviceLoaded { return "已安装 · launchd 运行中" }
        return running ? "已安装 · 前台进程" : "已安装 · 已停止"
    }
    var dockerEnabled: Bool { config?.docker?.enabled ?? false }
    var transportLabel: String {
        let list = config?.transports ?? config?.transport.map { [$0] } ?? []
        return list.isEmpty ? "-" : list.joined(separator: ", ")
    }
    var providerLabel: String {
        guard let p = config?.provider else { return "-" }
        guard let m = config?.model, !m.isEmpty else { return p }
        return "\(p) · \(m)"
    }
    /// 根据本机实际可用的安装器给出要执行的安装命令。
    var installCommand: String {
        availableInstaller == "uv" ? "uv tool install ductor" : "pipx install ductor"
    }
    var versionNote: String? {
        guard installed, let v = version else { return nil }
        guard let latest = latestVersion else { return "无法检查最新版本" }
        if v.compare(latest, options: .numeric) == .orderedAscending { return "🔔 有新版本 \(latest)" }
        return "已是最新"
    }

    // MARK: 刷新

    func refresh() async {
        loading = true
        defer { loading = false }
        async let latest = Self.latestFromPyPI()

        let v = await Shell.run("ductor", ["--version"])
        installed = v.status == 0
        latestVersion = await latest

        if await Shell.run("uv", ["--version"]).status == 0 {
            availableInstaller = "uv"
        } else if await Shell.run("pipx", ["--version"]).status == 0 {
            availableInstaller = "pipx"
        } else {
            availableInstaller = nil
        }

        guard installed else {
            version = nil
            running = false
            pid = nil
            uptime = ""
            config = nil
            agents = []
            serviceInstalled = false
            serviceLoaded = false
            errorCount = 0
            logFiles = []
            logLines = []
            error = "未找到 ductor 命令（PATH 中缺少 ~/.local/bin 或未安装）"
            return
        }

        version = Self.parseVersion(v.stdout)
        error = nil
        config = Self.loadConfig()
        agents = Self.loadAgents()
        serviceInstalled = FileManager.default.fileExists(atPath: DuctorPaths.servicePlist.path)
        if serviceInstalled {
            let lc = await Shell.run("launchctl", ["list", "dev.ductor"])
            // launchctl list 即使没在跑也返回 0，只有带 PID 才算真的加载运行
            serviceLoaded = lc.status == 0 && lc.stdout.contains("\"PID\"")
        } else {
            serviceLoaded = false
        }
        readRuntimeState()
        errorCount = Self.countErrors()
        await loadLogFileList()
        await refreshLogs()
    }

    private func readRuntimeState() {        guard let raw = try? String(contentsOf: DuctorPaths.pid, encoding: .utf8),
              let p = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            running = false
            pid = nil
            uptime = ""
            return
        }
        pid = p
        running = kill(p, 0) == 0
        guard running,
              let attrs = try? FileManager.default.attributesOfItem(atPath: DuctorPaths.pid.path),
              let started = attrs[.modificationDate] as? Date else {
            uptime = ""
            return
        }
        let seconds = Int(Date().timeIntervalSince(started))
        uptime = "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    var hasUpdate: Bool {
        guard let v = version, let latest = latestVersion else { return false }
        return v.compare(latest, options: .numeric) == .orderedAscending
    }

    // MARK: 日志

    func loadLogFileList() async {
        let dir = DuctorPaths.logs
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        logFiles = names
            .filter { $0.hasSuffix(".log") || $0.hasSuffix(".err") }
            .sorted { Self.fileDate(dir, $0) > Self.fileDate(dir, $1) }
        if !logFiles.contains(selectedLog) {
            selectedLog = logFiles.first ?? ""
        }
    }

    func refreshLogs() async {
        guard !selectedLog.isEmpty else {
            logLines = []
            return
        }
        let path = DuctorPaths.logs.appendingPathComponent(selectedLog).path
        let r = await Shell.run("tail", ["-n", "200", path])
        logLines = r.status == 0
            ? r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            : ["无法读取日志：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]
    }

    // MARK: 读取文件

    private static func loadConfig() -> DuctorConfig? {
        guard let data = try? Data(contentsOf: DuctorPaths.config) else { return nil }
        return try? JSONDecoder().decode(DuctorConfig.self, from: data)
    }

    private static func loadAgents() -> [DuctorAgent] {
        guard let data = try? Data(contentsOf: DuctorPaths.agents),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return DuctorAgent(name: name,
                               provider: item["provider"] as? String,
                               model: item["model"] as? String)
        }
    }

    private static func fileDate(_ dir: URL, _ name: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast
    }

    private static func countErrors() -> Int {
        let dir = DuctorPaths.logs
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let newest = names.filter { $0.hasSuffix(".log") }.max { fileDate(dir, $0) < fileDate(dir, $1) }
        guard let newest,
              let text = try? String(contentsOf: dir.appendingPathComponent(newest), encoding: .utf8) else { return 0 }
        return text.components(separatedBy: " ERROR ").count - 1
    }

    // MARK: 工具

    nonisolated static func latestFromPyPI() async -> String? {
        guard let url = URL(string: "https://pypi.org/pypi/ductor/json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any] else { return nil }
        return info["version"] as? String
    }

    static func parseVersion(_ text: String) -> String? {
        // "ductor 0.20.1"
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let last = parts.last, last.first?.isNumber == true else { return nil }
        return String(last)
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
                                  with: "", options: .regularExpression)
    }
}
