import SwiftUI

/// 命令输出弹窗用的数据。
struct OutputItem: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// 通用的命令输出弹窗：等宽、可选中、可整段复制。
struct OutputSheet: View {
    let item: OutputItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.title).font(.headline)
                Spacer()
                Button("复制") { Terminal.copy(item.text) }
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(item.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(width: 640, height: 460)
    }
}

/// 「命令行 + 复制按钮」一行，安装命令展示用。
struct CommandRow: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                Terminal.copy(command)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
