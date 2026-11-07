import XCTest
@testable import MacReader

final class ShellTests: XCTestCase {

    /// Whatever a volume is called, quoting must hand it to the shell unchanged
    /// (no command substitution, no word splitting).
    func testQuoteRoundTrip() throws {
        let values = [
            "plain",
            "with space",
            "it's",
            "'''",
            "$(echo HACKED)",
            "`echo HACKED`",
            "$HOME",
            "a\"b",
            "back\\slash",
            "tab\there",
            "new\nline",
            "هارد عمر",
            "*",
            "",
        ]
        for value in values {
            let result = try runSh([], script: "printf %s \(Shell.quote(value))")
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout, value, "quote() changed \(value.debugDescription)")
        }
    }

    func testRunCapturesOutputAndStatus() {
        let ok = Shell.run("/bin/sh", ["-c", "echo out; echo err >&2"])
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.stdout, "out\n")
        XCTAssertEqual(ok.stderr, "err\n")

        let fail = Shell.run("/bin/sh", ["-c", "exit 3"])
        XCTAssertEqual(fail.status, 3)

        let missing = Shell.run("/does/not/exist", [])
        XCTAssertFalse(missing.ok)
    }

    /// Lots of stderr must not deadlock run().
    func testLargeStderrDoesNotDeadlock() {
        let r = Shell.run("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo xxxxxxxxxxxxxxxxxxxx >&2; i=$((i+1)); done; echo done"])
        XCTAssertEqual(r.stdout, "done\n")
        XCTAssertGreaterThan(r.stderr.count, 100_000)
    }
}
