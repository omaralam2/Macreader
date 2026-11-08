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

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum Shell {
    /// Runs a program directly (no shell involved) and waits for it.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
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
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let errData = errBox.data

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a /bin/sh script as root through `sudo -A`, which asks for the
    /// password with a native dialog (the askpass helper below).
    ///
    /// Why not `do shell script … with administrator privileges`: that runs the
    /// script through Apple's `authtrampoline`, and macOS privacy checks (TCC)
    /// are then made against authtrampoline instead of MacReader, so reading
    /// the raw disk fails with "Operation not permitted" even after the user
    /// gave MacReader Full Disk Access. sudo stays a child of MacReader, so the
    /// grant applies. The script is passed as an argument, never interpolated.
    static func runAsAdmin(_ script: String) -> AdminResult {
        guard let askpass = askpassPath() else {
            return .failure("MacReader couldn't prepare the password prompt.")
        }
        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = askpass
        // -k: always ask (no cached sudo ticket); -p "": no text prompt on stderr.
        let result = run("/usr/bin/sudo", ["-A", "-k", "-p", "", "/bin/sh", "-c", script], environment: env)
        return adminResult(result)
    }

    static func adminResult(_ result: ShellResult) -> AdminResult {
        if result.ok {
            return .success(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let err = result.stderr
        if err.contains("no password was provided") || err.contains("MACREADER_ASKPASS_CANCELLED") {
            return .cancelled
        }
        if err.contains("incorrect password attempt") {
            return .failure("الباسورد غلط.")
        }
        let cleaned = err.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("Sorry, try again") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(cleaned)
    }

    /// Writes (once) a tiny askpass helper that shows a native password dialog
    /// and prints the password to sudo. Nothing is stored anywhere.
    private static func askpassPath() -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macreader-askpass.sh")
        let body = """
        #!/bin/sh
        /usr/bin/osascript -e 'text returned of (display dialog "MacReader محتاج باسورد الماك علشان يفتح الهارد أو يفصله." default answer "" with hidden answer with title "MacReader" with icon caution buttons {"إلغاء", "OK"} default button "OK" cancel button "إلغاء")' 2>/dev/null || { echo MACREADER_ASKPASS_CANCELLED >&2; exit 1; }

        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    /// Single-quotes a value for /bin/sh.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
