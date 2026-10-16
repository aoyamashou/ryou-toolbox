import Foundation
import Observation

struct LarkProfile: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let brand: String
    var active: Bool
    var userName: String = "-"
    var openId: String = "-"
    var valid = false
    var note: String = ""
}

private struct ProfileItem: Decodable {
    let name: String
    let brand: String?
    let active: Bool?
}

private struct AuthStatus: Decodable {
    struct User: Decodable { let userName: String?; let openId: String?; let tokenStatus: String? }
    struct Identities: Decodable { let user: User? }
    let identity: String?
    let verified: Bool?
    let identities: Identities?
}

@MainActor @Observable
final class LarkModel {
    var profiles: [LarkProfile] = []
    var error: String?
    var message: String?
    var loading = false

    var current: LarkProfile? { profiles.first { $0.active } }

    func refresh() async {
        loading = true
        defer { loading = false }
        let r = await Shell.run("lark-cli", ["profile", "list"])
        guard let data = r.stdout.data(using: .utf8),
              let items = try? JSONDecoder().decode([ProfileItem].self, from: data) else {
            profiles = []
            error = "无法运行 lark-cli：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            return
        }
        error = nil
        let base = items.map { LarkProfile(name: $0.name, brand: $0.brand ?? "?", active: $0.active ?? false) }
        profiles = base
        let checked = await withTaskGroup(of: LarkProfile.self) { group in
            for p in base { group.addTask { await Self.check(p) } }
            var out: [LarkProfile] = []
            for await p in group { out.append(p) }
            return out
        }
        profiles = base.compactMap { b in checked.first { $0.name == b.name } }
    }

    func use(_ name: String) async {
        let r = await Shell.run("lark-cli", ["profile", "use", name])
        message = r.status == 0 ? "已切换到 \(name)" : "切换失败：\(r.stderr)"
        await refresh()
    }

    func remove(_ name: String) async {
        let r = await Shell.run("lark-cli", ["profile", "remove", name])
        message = r.status == 0 ? "已删除 \(name)" : "删除失败：\(r.stderr)"
        await refresh()
    }

    /// 与 lark-user-bind.zsh 的 verify_profile 同一判定标准。
    nonisolated private static func check(_ p: LarkProfile) async -> LarkProfile {
        var p = p
        let r = await Shell.run("lark-cli", ["auth", "status", "--profile", p.name, "--json", "--verify"])
        guard let data = r.stdout.data(using: .utf8),
              let s = try? JSONDecoder().decode(AuthStatus.self, from: data) else {
            p.note = "无法验证"
            return p
        }
        let u = s.identities?.user
        p.userName = u?.userName ?? "-"
        p.openId = u?.openId ?? "-"
        p.valid = s.identity == "user" && s.verified == true && u?.tokenStatus == "valid"
        p.note = p.valid ? "User 有效" : "无有效 User（\(u?.tokenStatus ?? "未绑定")）"
        return p
    }
}

/// 设备码授权流程（对应脚本的 authenticate_profile）。
@MainActor @Observable
final class AuthFlow {
    enum Phase: Equatable { case starting, waiting(url: String), finishing, done(String), failed(String) }
    var phase: Phase = .starting
    private var deviceCode = ""
    let profile: String

    init(profile: String) { self.profile = profile }

    func start() async {
        phase = .starting
        let r = await Shell.run("lark-cli", ["auth", "login", "--profile", profile, "--recommend", "--no-wait", "--json"])
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [String: Any],
              let url = obj["verification_url"] as? String,
              let code = obj["device_code"] as? String else {
            phase = .failed("发起授权失败：\(r.stderr.isEmpty ? r.stdout : r.stderr)")
            return
        }
        deviceCode = code
        phase = .waiting(url: url)
    }

    func finish() async {
        phase = .finishing
        let r = await Shell.run("lark-cli", ["auth", "login", "--profile", profile, "--device-code", deviceCode])
        if r.status != 0 {
            phase = .failed("授权未完成：\((r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        let v = await Shell.run("lark-cli", ["auth", "status", "--profile", profile, "--json", "--verify"])
        if let s = try? JSONDecoder().decode(AuthStatus.self, from: Data(v.stdout.utf8)),
           s.identity == "user", s.verified == true, s.identities?.user?.tokenStatus == "valid" {
            phase = .done("✅ User 身份有效：\(s.identities?.user?.userName ?? "-")")
        } else {
            phase = .failed("授权后验证失败：当前不是有效的 User 身份")
        }
    }
}

/// 新建 Profile（对应脚本的 bind_profile 前半：config init --new）。
@MainActor @Observable
final class NewProfileFlow {
    enum Phase: Equatable { case idle, running(url: String?), done, failed(String) }
    var phase: Phase = .idle
    private let proc = StreamingProcess()

    static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    func start(name: String, brand: String) async {
        phase = .running(url: nil)
        let box = LineBox()
        let code = await proc.run("lark-cli", ["config", "init", "--new", "--name", name, "--brand", brand, "--lang", "zh_cn"]) { line in
            guard let url = Self.firstURL(in: line) else { return }
            Task { @MainActor in
                if case .running(nil) = self.phase { self.phase = .running(url: url) }
            }
            box.last = line
        }
        phase = code == 0 ? .done : .failed("创建失败（退出码 \(code)）\(box.last)")
    }

    func cancel() { proc.cancel() }

    nonisolated static func firstURL(in line: String) -> String? {
        guard let r = line.range(of: "https?://[^\\s\"'<>]+", options: .regularExpression) else { return nil }
        return String(line[r])
    }
}

final class LineBox: @unchecked Sendable { var last = "" }
