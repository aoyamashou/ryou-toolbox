import Foundation
import AppKit

/// 在 Terminal 里执行命令（交互式命令必须这样跑）。
///
/// 生成一个 `.command` 脚本再用 `open` 丢给 Terminal，而不是 AppleScript：
/// 前者不需要「控制 Terminal.app」的自动化授权，也不会被 TCC 弹窗打断。
enum Terminal {
    /// - Parameter command: 要执行的命令；传 nil 只打开一个干净的登录 shell。
    static func run(_ command: String? = nil) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RyouToolbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let olds = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for old in olds { try? FileManager.default.removeItem(at: old) }
        }

        var lines = ["#!/bin/zsh -l", "cd \"$HOME\""]
        if let command, !command.isEmpty {
            lines.append(command)
            // 命令跑完保留窗口，方便看输出 / 继续操作
            lines.append("exec zsh -l")
        }

        let file = dir.appendingPathComponent("toolbox.command")
        guard (try? lines.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([file], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    /// 复制到剪贴板。
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
