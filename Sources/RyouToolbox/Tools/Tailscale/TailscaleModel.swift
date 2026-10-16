import Foundation
import Observation

struct TSNode: Identifiable, Sendable {
    let id: String
    let host: String
    let dns: String
    let os: String
    let online: Bool
    let ipv4: String
    let isSelf: Bool
    let ssh: Bool
    let lastSeen: Date?
    let exitNode: Bool
}

private struct TSStatus: Decodable {
    struct Peer: Decodable {
        let ID: String
        let HostName: String
        let DNSName: String
        let OS: String
        let Online: Bool?
        let TailscaleIPs: [String]?
        let sshHostKeys: [String]?
        let LastSeen: String?
        let ExitNode: Bool?
    }
    let Version: String?
    let BackendState: String
    let me: Peer?
    let peers: [String: Peer]?
    enum CodingKeys: String, CodingKey {
        case BackendState, Version
        case me = "Self"
        case peers = "Peer"
    }
}

@MainActor @Observable
final class TailscaleModel {
    var nodes: [TSNode] = []
    var error: String?
    var loading = false
    var localVersion: String?
    var versionNote: String?

    func refresh() async {
        loading = true
        defer { loading = false }
        async let latest = Self.latestStable()
        let r = await Shell.run("tailscale", ["status", "--json"])
        guard let data = r.stdout.data(using: .utf8), !data.isEmpty,
              let s = try? JSONDecoder().decode(TSStatus.self, from: data) else {
            nodes = []
            error = r.status == 0 ? "无法解析 Tailscale 输出" : "无法运行 tailscale：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            return
        }
        guard s.BackendState == "Running" else {
            nodes = []
            error = "Tailscale 未运行（状态：\(s.BackendState)）"
            return
        }
        error = nil
        localVersion = s.Version
        versionNote = Self.compare(local: s.Version, latest: await latest)
        func make(_ p: TSStatus.Peer, isSelf: Bool) -> TSNode {
            TSNode(id: p.ID, host: p.HostName,
                   dns: p.DNSName.hasSuffix(".") ? String(p.DNSName.dropLast()) : p.DNSName,
                   os: p.OS, online: isSelf ? true : (p.Online ?? false),
                   ipv4: (p.TailscaleIPs ?? []).first { !$0.contains(":") } ?? "-",
                   isSelf: isSelf,
                   ssh: !(p.sshHostKeys ?? []).isEmpty,
                   lastSeen: p.LastSeen.flatMap { $0.hasPrefix("0001") ? nil : ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) },
                   exitNode: p.ExitNode ?? false)
        }
        var list = (s.peers ?? [:]).values.map { make($0, isSelf: false) }
            .sorted { ($0.online ? 0 : 1, $0.host) < ($1.online ? 0 : 1, $1.host) }
        if let me = s.me { list.insert(make(me, isSelf: true), at: 0) }
        nodes = list
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

extension TailscaleModel {
    /// 官方稳定版最新版本号；失败返回 nil。
    nonisolated static func latestStable() async -> String? {
        guard let url = URL(string: "https://pkgs.tailscale.com/stable/?mode=json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["TarballsVersion"] as? String
    }

    static func compare(local: String?, latest: String?) -> String {
        guard let local else { return "无法获取本机版本" }
        let l = String(local.split(separator: "-").first ?? "")
        guard let latest else { return "本机 \(l)（无法检查最新版本）" }
        if l.compare(latest, options: .numeric) == .orderedAscending { return "🔔 本机 \(l)，有新版本 \(latest)" }
        return "✅ 本机 \(l)，已是最新稳定版"
    }
}
