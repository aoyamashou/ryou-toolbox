import SwiftUI
import AppKit
import SwiftTerm

/// 内嵌终端：在 App 窗口里跑一个真实的登录 shell，并支持「按钮点一下就自动输入命令」。
///
/// 做法与 Orca 的 `OnboardingInlineCommandTerminal` 一致：
/// 建一个临时 PTY → 等 shell 画出提示符 → 用 bracketed paste 写入命令 → 单独发 `\r` 执行。
/// 命令只填进命令行不自动回车，用户能改完再自己按回车。
@MainActor
final class EmbeddedTerminal: ObservableObject {
    /// 底层 view，SwiftUI 里用 `NSViewRepresentable` 挂上去。
    let view: LocalProcessTerminalView
    @Published private(set) var running = false
    @Published private(set) var exitCode: Int32?

    /// shell 画出提示符、可以安全写入命令了。
    private var ready = false
    private var pendingCommand: String?
    private var probeTimer: Timer?
    private var probeStartedAt = Date()
    private var idleSamples = 0

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        var onTitle: ((String) -> Void)?
        var onDirectory: ((String?) -> Void)?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle?(title) }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { onDirectory?(directory) }
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
    }

    private let delegate = Delegate()

    init() {
        var options = TerminalOptions.default
        options.scrollback = 4000
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 260),
                                       options: options)
        view.processDelegate = delegate
        delegate.onExit = { [weak self] code in
            Task { @MainActor in
                self?.running = false
                self?.exitCode = code
            }
        }
        // 终端里程序设置标题时顺带当作「输出到了」的信号，不做别的事。
        delegate.onTitle = { _ in }
    }

    // MARK: 生命周期

    func start(directory: String? = nil) {
        guard !running else { return }
        // 注意：本仓库有自己的 `Terminal`（Core/Terminal.swift），这里必须用限定名
        var env = SwiftTerm.Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // 让子进程拿到和 App 一致的 PATH（GUI 应用没有 shell 的 PATH），
        // 否则 brew / pipx 装的 CLI 在终端里找不到。
        env.append("PATH=\(Shell.environment["PATH"] ?? "/usr/bin:/bin")")
        env.append("TERM_PROGRAM=RyouToolbox")
        env.append("LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1")
        env.append("LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(executable: shell,
                          args: ["-l", "-i"],
                          environment: env,
                          execName: (shell as NSString).lastPathComponent,
                          currentDirectory: directory ?? FileManager.default.homeDirectoryForCurrentUser.path)
        running = true
        exitCode = nil
        ready = false
        startReadinessProbe()
    }

    func stop() {
        probeTimer?.invalidate()
        probeTimer = nil
        if running { view.process.terminate() }
        running = false
    }

    // MARK: 自动输入

    /// 把命令填进当前命令行（不回车）。shell 还没 ready 时先排队，ready 后自动补上。
    func type(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !running { start() }
        guard ready else {
            pendingCommand = trimmed
            return
        }
        paste(trimmed)
    }

    /// 让 App 焦点回到终端，方便用户接着敲。
    func focus() {
        view.window?.makeFirstResponder(view)
    }

    /// 填进命令行并立刻执行。
    func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        type(trimmed)
        if !ready {
            pendingSubmitText = trimmed
            return
        }
        submitAfterPaste(expecting: trimmed)
    }

    private var pendingSubmitText: String?

    /// 单独发回车：paste 本身不带换行，这是 Orca 里分开的两步。
    func submit() {
        guard running else { return }
        view.send(source: view, data: ArraySlice([0x0D]))
        view.window?.makeFirstResponder(view)
    }

    /// 粘贴和回车是两条独立的写入，直接连着发会因为线程调度先到 PTY 而变成「空回车」。
    /// 这里等命令行上真的出现这段文字再回车，最多等 1.5 秒。
    private func submitAfterPaste(expecting text: String, attempt: Int = 0) {
        guard running else { return }
        guard attempt < 30 else { submit(); return }
        let buffer = String(decoding: view.getBufferAsData(), as: UTF8.self)
        // 只看最后几行，避开滚动缓冲区里的旧输出
        let tail = buffer.split(separator: "\n", omittingEmptySubsequences: false).suffix(4)
            .joined(separator: "\n")
        let needle = text.split(separator: "\n").first.map(String.init) ?? text
        if tail.contains(needle) {
            submit()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.submitAfterPaste(expecting: text, attempt: attempt + 1)
        }
    }

    /// 走 SwiftTerm 的 `pasteText`，它会按 shell 当前的 bracketed paste 状态包裹，
    /// 多行命令不会被 shell 提前执行，也不会被当成逐字符敲入。
    private func paste(_ text: String) {
        view.pasteText(text)
        view.window?.makeFirstResponder(view)
    }

    // MARK: 就绪检测

    /// 和 Orca 一样：等到终端缓冲区里出现非空内容（提示符），再写入命令，
    /// 否则命令可能被早于 shell 初始化发送而丢掉或重复回显。
    private func startReadinessProbe() {
        probeTimer?.invalidate()
        probeStartedAt = Date()
        idleSamples = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    private func probe() {
        guard running else { probeTimer?.invalidate(); return }
        let text = String(decoding: view.getBufferAsData(), as: UTF8.self)
        let hasOutput = text.contains { !$0.isWhitespace }
        if hasOutput {
            idleSamples += 1
            // 连续两次都读到内容才算稳，避免读到半行提示符
            if idleSamples >= 2 { markReady() }
            return
        }
        // 兜底：800ms 还没读到任何文字（某些 GPU 渲染路径读不到），也照样放行
        if Date().timeIntervalSince(probeStartedAt) > 0.8 { markReady() }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        probeTimer?.invalidate()
        probeTimer = nil
        if let cmd = pendingCommand {
            pendingCommand = nil
            paste(cmd)
        }
        if let text = pendingSubmitText {
            pendingSubmitText = nil
            submitAfterPaste(expecting: text)
        }
    }
}

/// SwiftUI 包装：`LocalProcessTerminalView` 是 AppKit view。
struct TerminalHost: NSViewRepresentable {
    let terminal: EmbeddedTerminal

    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal.view }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 尺寸变化由 SwiftTerm 自己按 frame 重算 PTY 大小
    }
}

/// 页面底部的内嵌终端槽位：`nil` 时不占空间，展开时从底部滑出。
struct InlineTerminalModifier: ViewModifier {
    @Binding var terminal: EmbeddedTerminal?
    let title: String
    var subtitle: String?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            if let terminal {
                Divider()
                EmbeddedTerminalPanel(terminal: terminal, title: title, subtitle: subtitle) {
                    terminal.stop()
                    self.terminal = nil
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear { terminal?.stop() }
    }
}

extension View {
    /// 在当前页面底部挂一个内嵌终端（`nil` 时隐藏）。
    func inlineTerminal(_ terminal: Binding<EmbeddedTerminal?>,
                        title: String = "终端",
                        subtitle: String? = nil) -> some View {
        modifier(InlineTerminalModifier(terminal: terminal, title: title, subtitle: subtitle))
    }
}

/// 打开（或复用）页面底部的内嵌终端并输入命令。
@MainActor
func openInlineTerminal(_ slot: Binding<EmbeddedTerminal?>,
                        command: String,
                        autoSubmit: Bool = false) {
    let terminal = slot.wrappedValue ?? EmbeddedTerminal()
    slot.wrappedValue = terminal
    terminal.start()
    guard !command.isEmpty else { return }
    if autoSubmit {
        terminal.run(command)
    } else {
        terminal.type(command)
    }
}

struct EmbeddedTerminalPanel: View {
    @ObservedObject var terminal: EmbeddedTerminal
    let title: String
    var subtitle: String?
    var height: CGFloat = 240
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalHost(terminal: terminal)
                .frame(height: height)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary)
        }
        .onAppear { terminal.focus() }
        .onDisappear { terminal.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(terminal.running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(title).font(.callout).bold()
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let code = terminal.exitCode, !terminal.running {
                Text("已退出（\(code)）").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                terminal.start()
            } label: {
                Label("重启 shell", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(terminal.running)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .controlSize(.small)
                .help("收起终端")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}
