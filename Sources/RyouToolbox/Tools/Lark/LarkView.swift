import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct LarkView: View {
    @State private var model = LarkModel()
    @State private var authTarget: String?
    @State private var showNew = false
    @State private var deleteTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            if let err = model.error {
                ContentUnavailableView("Lark CLI 不可用", systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                List(model.profiles) { p in row(p) }
            }
        }
        .navigationTitle("Lark 登录状态")
        .toolbar {
            ToolbarItem {
                Button { showNew = true } label: { Label("新建 Profile", systemImage: "plus") }
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
            }
        }
        .overlay { if model.loading && model.profiles.isEmpty { ProgressView() } }
        .task { await model.refresh() }
        .sheet(item: Binding(get: { authTarget.map(Ident.init) }, set: { authTarget = $0?.id })) { t in
            AuthSheet(profile: t.id) { Task { await model.refresh() } }
        }
        .sheet(isPresented: $showNew) {
            NewProfileSheet { name in
                showNew = false
                Task { await model.refresh(); authTarget = name }
            }
        }
        .confirmationDialog("确认删除 Profile “\(deleteTarget ?? "")”？", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let n = deleteTarget { Task { await model.remove(n) } }
                deleteTarget = nil
            }
        }
    }

    private var summary: some View {
        HStack {
            if let c = model.current {
                Text("当前 Profile：\(c.name) ｜ \(c.valid ? "User 权限 · \(c.userName)" : "App/Bot 权限（无有效 User）")")
            } else {
                Text("当前 Profile：无")
            }
            Spacer()
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func row(_ p: LarkProfile) -> some View {
        HStack(spacing: 10) {
            Text(p.valid ? "✅" : "⚠️")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.name).font(.headline)
                    if p.active { Text("当前").font(.caption2).padding(.horizontal, 5)
                        .background(.blue.opacity(0.2), in: Capsule()) }
                    Text(p.brand).font(.caption).foregroundStyle(.secondary)
                }
                Text(p.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(p.userName)
                Text(p.openId).font(.caption).monospaced().foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("切换") { Task { await model.use(p.name) } }.disabled(p.active)
            Button(p.valid ? "重新授权" : "授权") { authTarget = p.name }
            Button(role: .destructive) { deleteTarget = p.name } label: { Image(systemName: "trash") }
        }
        .padding(.vertical, 2)
    }
}

private struct Ident: Identifiable { let id: String }

private func qrImage(_ text: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    guard let out = f.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

private struct URLBlock: View {
    let url: String
    var body: some View {
        VStack(spacing: 8) {
            if let img = qrImage(url) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200)
            }
            Text(url).font(.caption).monospaced().textSelection(.enabled).lineLimit(3)
            HStack {
                Button("复制链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                Button("在浏览器打开") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
            }
        }
    }
}

private struct AuthSheet: View {
    @State private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    let onClose: () -> Void

    init(profile: String, onClose: @escaping () -> Void) {
        _flow = State(initialValue: AuthFlow(profile: profile))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("User 授权：\(flow.profile)").font(.headline)
            switch flow.phase {
            case .starting: ProgressView("正在发起授权…")
            case .waiting(let url):
                Text("请用 Lark 扫码，或打开链接完成授权").foregroundStyle(.secondary)
                URLBlock(url: url)
                Button("我已授权，完成登录") { Task { await flow.finish() } }.keyboardShortcut(.defaultAction)
            case .finishing: ProgressView("正在验证…")
            case .done(let m): Text(m)
            case .failed(let m):
                Text(m).foregroundStyle(.red).textSelection(.enabled)
                Button("重试") { Task { await flow.start() } }
            }
            Button("关闭") { dismiss(); onClose() }
        }
        .padding(24).frame(width: 420)
        .task { await flow.start() }
    }
}

private struct NewProfileSheet: View {
    @State private var flow = NewProfileFlow()
    @State private var name = ""
    @State private var brand = "lark"
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("新建 Profile").font(.headline)
            switch flow.phase {
            case .idle:
                TextField("名称（字母/数字/. _ -）", text: $name).textFieldStyle(.roundedBorder)
                Picker("产品", selection: $brand) {
                    Text("国际版 Lark").tag("lark"); Text("国内版飞书").tag("feishu")
                }.pickerStyle(.segmented)
                Button("创建") { Task { await flow.start(name: name, brand: brand) } }
                    .disabled(!NewProfileFlow.validName(name))
            case .running(let url):
                if let url {
                    Text("请在浏览器中完成应用配置").foregroundStyle(.secondary)
                    URLBlock(url: url)
                } else {
                    ProgressView("正在创建…")
                }
                Text("完成后此窗口会自动继续").font(.caption).foregroundStyle(.secondary)
            case .done:
                Text("✅ 已创建 \(name)，下一步授权 User 身份")
                Button("继续授权") { onCreated(name) }.keyboardShortcut(.defaultAction)
            case .failed(let m):
                Text(m).foregroundStyle(.red).textSelection(.enabled)
            }
            Button("取消") { flow.cancel(); dismiss() }
        }
        .padding(24).frame(width: 420)
    }
}
