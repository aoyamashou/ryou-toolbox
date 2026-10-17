import Foundation

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
}

enum Shell {
    /// GUI 应用没有 shell 的 PATH，这里补全常见 CLI 目录（含 pipx/uv 的 ~/.local/bin）。
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.cargo/bin",
            "/Applications/Tailscale.app/Contents/MacOS",
        ].joined(separator: ":")
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        env["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        return env
    }()

    static func run(_ command: String, _ args: [String]) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [command] + args
                p.environment = environment
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(stdout: "", stderr: "\(error)", status: -1))
                    return
                }
                // 先读完再 wait，避免管道写满死锁
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: ShellResult(
                    stdout: String(decoding: o, as: UTF8.self),
                    stderr: String(decoding: e, as: UTF8.self),
                    status: p.terminationStatus))
            }
        }
    }
}

/// 长时间运行并按行回传输出的进程（如 `lark-cli config init --new` 会阻塞到用户在浏览器完成）。
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()

    /// onLine 在后台线程回调；返回退出码。
    func run(_ command: String, _ args: [String], onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = Shell.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                do { try self.process.run() } catch {
                    onLine("\(error)"); cont.resume(returning: -1); return
                }
                var buffer = Data()
                let h = self.pipe.fileHandleForReading
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let i = buffer.firstIndex(of: 10) {
                        onLine(String(decoding: buffer[..<i], as: UTF8.self))
                        buffer.removeSubrange(...i)
                    }
                }
                if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
                self.process.waitUntilExit()
                cont.resume(returning: self.process.terminationStatus)
            }
        }
    }

    func cancel() { if process.isRunning { process.terminate() } }
}
