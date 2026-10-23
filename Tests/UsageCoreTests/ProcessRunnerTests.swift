import Foundation
import Testing
@testable import UsageCore

@Suite struct ProcessRunnerTests {
    @Test func returnsStdoutWithoutUntil() async throws {
        let out = try await ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
        #expect(String(decoding: out, as: UTF8.self) == "hello\n")
    }

    @Test func extraEnvironmentIsPassed() async throws {
        let out = try await ProcessRunner.run("/bin/sh", ["-c", "printf %s \"$CODEX_HOME|$HOME\""],
                                              environment: ["CODEX_HOME": "/tmp/x"], timeout: 5)
        #expect(String(decoding: out, as: UTF8.self) == "/tmp/x|\(NSHomeDirectory())")
    }

    @Test func largeOutputIsComplete() async throws {
        // More than one pipe buffer chunk (64 KB).
        let out = try await ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero"], timeout: 5)
        #expect(out.count == 200_000)
    }

    @Test func nonZeroExitCarriesStatus() async {
        await #expect(throws: UsageError.exit(tool: "sh", status: 44)) {
            try await ProcessRunner.run("/bin/sh", ["-c", "exit 44"], timeout: 5)
        }
    }

    @Test func runStatusKeepsOutputOfFailedRun() async throws {
        let result = try await ProcessRunner.runStatus("/bin/sh", ["-c", "printf '{\"ok\":false}'; pwd; exit 4"],
                                                       directory: "/", timeout: 5)
        #expect(result.status == 4)
        #expect(String(decoding: result.output, as: UTF8.self) == "{\"ok\":false}/\n")
    }

    @Test func closeInputGivesEOF() async throws {
        // Without closing stdin, cat would wait for input until the timeout.
        let start = Date()
        let out = try await ProcessRunner.run("/bin/cat", [], input: Data("key\n".utf8), closeInput: true, timeout: 5)
        #expect(String(decoding: out, as: UTF8.self) == "key\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func untilStopsLongRunningProcess() async throws {
        // cat with stdin open never exits on its own: leave on the condition.
        let start = Date()
        let out = try await ProcessRunner.run("/bin/cat", [], input: Data("ping\n".utf8), timeout: 5,
                                              until: { String(decoding: $0, as: UTF8.self).contains("ping") })
        #expect(String(decoding: out, as: UTF8.self) == "ping\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func timeoutThrows() async {
        await #expect(throws: UsageError.message("timed out after 0 s")) {
            try await ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        }
    }

    @Test func processIgnoringSigtermIsKilled() async throws {
        // exec, so that sleep replaces the shell and inherits the ignored SIGTERM instead of being orphaned.
        let marker = "31.4159"
        _ = try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; echo ready; exec /bin/sleep \(marker)"],
                                        timeout: 5, until: { String(decoding: $0, as: UTF8.self).contains("ready") })
        try await Task.sleep(for: .seconds(3))
        let check = try await ProcessRunner.run("/bin/sh", ["-c", "pgrep -f 'sleep \(marker)' || true"], timeout: 5)
        #expect(check.isEmpty)
    }

    @Test func writeToExitedProcessFailsWithoutCrash() async {
        // The process exits immediately without reading stdin; 1 MB does not fit the pipe buffer → EPIPE.
        signal(SIGPIPE, SIG_IGN)
        await #expect(throws: UsageError.self) {
            try await ProcessRunner.run("/bin/sh", ["-c", "exit 3"], input: Data(count: 1 << 20), timeout: 5)
        }
    }

    @Test func timeoutWorksWhenStdinIsNotRead() async {
        // sleep does not read stdin, 1 MB does not fit the pipe, the write blocks; the timeout still fires.
        signal(SIGPIPE, SIG_IGN)
        let start = Date()
        await #expect(throws: UsageError.message("timed out after 0 s")) {
            try await ProcessRunner.run("/bin/sleep", ["30"], input: Data(count: 1 << 20), timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func descendantHoldingStdoutDoesNotHang() async throws {
        // A background sleep inherits stdout, EOF comes only after 6 s. Wait not for it but 2 s after the exit.
        let start = Date()
        let out = try await ProcessRunner.run("/bin/sh", ["-c", "echo hi; /bin/sleep 6 & exit 0"], timeout: 10)
        #expect(String(decoding: out, as: UTF8.self) == "hi\n")
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func nonZeroExitThrows() async {
        await #expect(throws: UsageError.self) {
            try await ProcessRunner.run("/usr/bin/false", [], timeout: 5)
        }
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: UsageError.message("/nonexistent/tool not found")) {
            try await ProcessRunner.run("/nonexistent/tool", [], timeout: 1)
        }
    }

    @Test func codexResponseLineIsFoundAmongNotifications() {
        let stream = Data("""
        {"id":1,"result":{}}
        {"method":"remoteControl/status/changed","params":{}}
        {"id":2,"result":{"rateLimits":{}}}
        {"id":3,"res
        """.utf8)
        let line = CodexSource.response(id: 2, in: stream)
        #expect(line.map { String(decoding: $0, as: UTF8.self) } == #"{"id":2,"result":{"rateLimits":{}}}"#)
        #expect(CodexSource.response(id: 3, in: stream) == nil)
    }
}
