import SwiftUI
import AppKit

private enum NodeFilter: String, CaseIterable, Identifiable {
    case computer = "💻 电脑"
    case mobile = "📱 手机/平板"
    var id: String { rawValue }

    func matches(_ n: TSNode) -> Bool {
        let isMobile = ["ios", "android"].contains(n.os.lowercased())
        return self == .mobile ? isMobile : !isMobile
    }
}

struct TailscaleView: View {
    @State private var model = TailscaleModel()
    @State private var copied: String?
    @State private var filter: NodeFilter = .computer

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            if model.error == nil, let note = model.versionNote {
                HStack {
                    Text(note)
                    Spacer()
                    Text("其他节点的客户端版本 Tailscale 不对外提供").font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout).padding(.horizontal).padding(.vertical, 8)
                Divider()
            }
            if let err = model.error {
                ContentUnavailableView("Tailscale 不可用", systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.nodes.filter(filter.matches)) { n in card(n) }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Tailscale 节点")
        .toolbar {
            ToolbarItem {
                Picker("类型", selection: $filter) {
                    ForEach(NodeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
            }
        }
        .task { await model.refresh() }
    }

    private func card(_ n: TSNode) -> some View {
        HStack(spacing: 8) {
            Circle().fill(n.online ? .green : .gray).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.host + (n.isSelf ? "（本机）" : "")).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Text(osLabel(n.os)).font(.caption).foregroundStyle(.secondary)
                    if n.ssh { chip("🔑 SSH", .green) }
                    if n.exitNode { chip("🚪 出口", .orange) }
                    if !n.online, let t = n.lastSeen {
                        Text(t.formatted(.relative(presentation: .named)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            Text(n.ipv4).font(.system(size: 17, design: .monospaced)).textSelection(.enabled)
            Button(copied == n.id ? "✅" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(n.ipv4, forType: .string)
                copied = n.id
                Task { try? await Task.sleep(for: .seconds(1.2)); if copied == n.id { copied = nil } }
            }
            .disabled(n.ipv4 == "-")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func osLabel(_ os: String) -> String {
    switch os.lowercased() {
    case "macos": return "🍎 macOS"
    case "ios": return "📱 iOS"
    case "android": return "🤖 Android"
    case "linux": return "🐧 Linux"
    case "windows": return "🪟 Windows"
    default: return os
    }
}

private func chip(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
        .background(color.opacity(0.2), in: Capsule())
}
