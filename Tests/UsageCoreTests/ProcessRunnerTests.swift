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
        // Больше одного куска pipe-буфера (64 КБ).
        let out = try await ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero"], timeout: 5)
        #expect(out.count == 200_000)
    }

    @Test func nonZeroExitCarriesStatus() async {
        await #expect(throws: UsageError.exit(tool: "sh", status: 44)) {
            try await ProcessRunner.run("/bin/sh", ["-c", "exit 44"], timeout: 5)
        }
    }

    @Test func closeInputGivesEOF() async throws {
        // Без закрытия stdin cat ждал бы ввода до таймаута.
        let start = Date()
        let out = try await ProcessRunner.run("/bin/cat", [], input: Data("key\n".utf8), closeInput: true, timeout: 5)
        #expect(String(decoding: out, as: UTF8.self) == "key\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func untilStopsLongRunningProcess() async throws {
        // cat с открытым stdin не завершится сам — выходим по условию.
        let start = Date()
        let out = try await ProcessRunner.run("/bin/cat", [], input: Data("ping\n".utf8), timeout: 5,
                                              until: { String(decoding: $0, as: UTF8.self).contains("ping") })
        #expect(String(decoding: out, as: UTF8.self) == "ping\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func timeoutThrows() async {
        await #expect(throws: UsageError.message("таймаут 0 с")) {
            try await ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        }
    }

    @Test func processIgnoringSigtermIsKilled() async throws {
        // exec — чтобы sleep заменил shell и унаследовал игнор SIGTERM, а не остался сиротой.
        let marker = "31.4159"
        _ = try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; echo ready; exec /bin/sleep \(marker)"],
                                        timeout: 5, until: { String(decoding: $0, as: UTF8.self).contains("ready") })
        try await Task.sleep(for: .seconds(3))
        let check = try await ProcessRunner.run("/bin/sh", ["-c", "pgrep -f 'sleep \(marker)' || true"], timeout: 5)
        #expect(check.isEmpty)
    }

    @Test func writeToExitedProcessFailsWithoutCrash() async {
        // Процесс выходит сразу, не читая stdin; 1 МБ не влезает в буфер pipe → EPIPE.
        signal(SIGPIPE, SIG_IGN)
        await #expect(throws: UsageError.self) {
            try await ProcessRunner.run("/bin/sh", ["-c", "exit 3"], input: Data(count: 1 << 20), timeout: 5)
        }
    }

    @Test func timeoutWorksWhenStdinIsNotRead() async {
        // sleep не читает stdin, 1 МБ не влезает в pipe — запись блокируется; таймаут всё равно срабатывает.
        signal(SIGPIPE, SIG_IGN)
        let start = Date()
        await #expect(throws: UsageError.message("таймаут 0 с")) {
            try await ProcessRunner.run("/bin/sleep", ["30"], input: Data(count: 1 << 20), timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func descendantHoldingStdoutDoesNotHang() async throws {
        // Фоновый sleep наследует stdout — EOF придёт только через 6 с. Ждём не его, а 2 с после выхода.
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
        await #expect(throws: UsageError.message("не найден /nonexistent/tool")) {
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
