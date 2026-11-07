import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum AdminResult {
    case success(String)
    case cancelled
    case failure(String)
}

enum Shell {
    /// Runs a program directly (no shell involved) and waits for it.
    static func run(_ executable: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Read stderr concurrently so a full pipe can never deadlock us.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a /bin/sh script as root. macOS shows its standard password dialog.
    /// The script is passed to osascript as an argument, so it never has to be
    /// escaped into AppleScript source.
    static func runAsAdmin(_ script: String) -> AdminResult {
        let result = run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            script,
        ])
        if result.ok {
            return .success(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if result.stderr.contains("(-128)") {
            return .cancelled
        }
        return .failure(cleanOsascriptError(result.stderr))
    }

    /// Single-quotes a value for /bin/sh.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "0:93: execution error: <message> (65)" -> "<message>"
    private static func cleanOsascriptError(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r", with: "\n")
        if let range = text.range(of: "execution error: ") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"\s*\(-?[0-9]+\)$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }
}
