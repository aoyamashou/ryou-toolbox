import SwiftUI

/// 命令速查表里的一条命令。
///
/// 点击后只把命令填进下方终端，**不自动回车** —— 和 Orca 设置面板一致：
/// 用户先看一眼命令对不对（尤其带参数的），确认无误自己按回车。
struct QuickCommand: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    /// 需要用户补参数（如 `<name>`、`<path>`）的命令：点的时候把光标停在末尾
    var needsArgument: Bool = false
    var note: String?
}

/// 命令速查分组。
struct QuickCommandGroup: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String?
    let commands: [QuickCommand]
}

/// 一屏「命令速查 + 终端」：上方按钮表，下方常驻内嵌终端。
///
/// 点按钮 → 命令出现在下方终端里（已输入、未执行）→ 检查后按回车。
struct CommandPaletteView: View {
    let groups: [QuickCommandGroup]
    @ObservedObject var terminal: EmbeddedTerminal
    /// 终端面板标题右侧的状态文案
    var terminalSubtitle: String?
    var terminalHeight: CGFloat = 260
    /// 无命令时的提示（如未安装）
    var emptyHint: String?
    /// 页面顶部的额外内容（状态卡等）
    var header: AnyView?

    @State private var lastCommand: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let header { header }
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "没有可用命令",
                            systemImage: "terminal",
                            description: Text(emptyHint ?? "先安装对应工具后再回来。")
                                .font(.callout)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                    }
                    if lastCommand != nil {
                        Text("命令已填入下方终端，检查无误后按回车执行。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }

            Divider()

            EmbeddedTerminalPanel(
                terminal: terminal,
                title: "终端",
                subtitle: terminalSubtitle,
                height: terminalHeight,
                onClose: nil
            )
            .padding(12)
        }
    }

    private func groupCard(_ group: QuickCommandGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(group.title).font(.headline)
                if let subtitle = group.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(group.commands.enumerated()), id: \.element.id) { index, cmd in
                    commandRow(cmd)
                    if index < group.commands.count - 1 { Divider() }
                }
            }
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func commandRow(_ cmd: QuickCommand) -> some View {
        let isLast = lastCommand == cmd.command
        return Button {
            lastCommand = cmd.command
            terminal.type(cmd.command)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cmd.title).font(.callout)
                    if let note = cmd.note {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Text(cmd.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(isLast ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: isLast ? "checkmark.circle.fill" : "arrow.down.left.circle")
                    .font(.caption)
                    .foregroundStyle(isLast ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("填入终端：\(cmd.command)")
    }
}
