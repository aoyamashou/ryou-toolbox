import SwiftUI

struct Tool: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let view: @MainActor () -> AnyView

    static func == (l: Tool, r: Tool) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// 新增工具：在此追加一项即可。
enum ToolRegistry {
    static let all: [Tool] = [
        Tool(id: "tailscale", title: "Tailscale 节点", icon: "network") { AnyView(TailscaleView()) },
        Tool(id: "lark", title: "Lark 登录状态", icon: "person.badge.key") { AnyView(LarkView()) },
        Tool(id: "ductor", title: "Ductor", icon: "bolt.horizontal.circle") { AnyView(DuctorView()) },
    ]
}
