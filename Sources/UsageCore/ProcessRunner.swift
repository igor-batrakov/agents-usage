import Foundation

public enum ProcessRunner {
    /// Runs a process and returns the accumulated stdout.
    /// - `input` is written to stdin; stdin stays open while the process is alive
    ///   (Codex app-server exits on EOF before it gets to answer).
    ///   `closeInput` closes stdin after writing, for a process that reads until EOF (`security -i`).
    /// - `until` is an early exit: as soon as the accumulated output satisfies it,
    ///   the process is killed and the output returned.
    /// - On timeout the process is killed and an error is thrown.
    public static func run(
        _ path: String,
        _ arguments: [String],
        input: Data? = nil,
        closeInput: Bool = false,
        environment extra: [String: String] = [:],
        timeout: TimeInterval,
        until: (@Sendable (Data) -> Bool)? = nil
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw UsageError.message(L("%@ not found", path))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment.merging(extra) { _, new in new }
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        let state = RunState()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation

            // A successful run finishes once there is both the process exit and stdout EOF:
            // only then is the output surely complete. If a child inherited stdout (agy's hub),
            // EOF never comes: 2 s after the exit, return whatever has accumulated.
            let complete = {
                guard let status = state.exitStatus else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                if status == 0 {
                    state.finish(.success(state.output))
                } else {
                    let name = (path as NSString).lastPathComponent
                    state.finish(.failure(UsageError.exit(tool: name, status: status)))
                }
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if state.markEOF() { complete() }
                    return
                }
                if state.append(chunk, check: until) {
                    state.finish(.success(state.output))
                    stop(process)
                }
            }
            process.terminationHandler = { p in
                let status = p.terminationReason == .exit ? p.terminationStatus : -p.terminationStatus
                if state.markExit(status) { complete() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: complete)
            }

            do {
                try process.run()
            } catch {
                // terminationHandler will not be called: remove the handler here, otherwise it holds the pipe.
                stdout.fileHandleForReading.readabilityHandler = nil
                state.finish(.failure(UsageError.message(L("can't start %@: %@", path, error.localizedDescription))))
                return
            }
            // The timeout is armed before writing: if the process does not read stdin, the write blocks,
            // and only killing the process on timeout unblocks it (EPIPE).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if state.finish(.failure(UsageError.message(L("timed out after %d s", Int(timeout))))) {
                    stop(process)
                }
            }
            if input == nil, closeInput {
                try? stdin.fileHandleForWriting.close()
            }
            if let input {
                // A separate queue: a blocking write does not hold a Swift Concurrency pool thread.
                // The throwing variant: the process may already have exited and closed the pipe. The non-throwing write
                // raises an ObjC exception in that case and crashes the whole app.
                // A write error is not passed on: it only means the process exited or closed
                // stdin, and the real outcome (exit code or timeout) comes from the handlers above.
                // Without `closeInput` stdin is not closed by hand: the pipe closes along with the launch objects.
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    if closeInput { try? stdin.fileHandleForWriting.close() }
                }
            }
        }
    }

    /// SIGTERM, then SIGKILL if the process has not exited within 2 s: hung CLIs must not pile up between polls.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// A GUI app does not get the shell PATH, so we provide a minimal one.
    static let environment: [String: String] = {
        let home = NSHomeDirectory()
        return [
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
        ]
    }()

    /// The first executable from the candidate list (`~` is expanded).
    public static func locate(_ candidates: [String]) -> String? {
        candidates.map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Shared state of one run; the continuation is resumed exactly once.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var done = false
    private var matched = false
    private var eof = false
    private var status: Int32?
    var continuation: CheckedContinuation<Data, Error>?

    var output: Data { lock.withLock { buffer } }
    var exitStatus: Int32? { lock.withLock { status } }

    /// Marks stdout EOF; true if the process has already exited (can finish).
    func markEOF() -> Bool { lock.withLock { eof = true; return status != nil } }

    /// Marks the process exit (a signal as a negative code); true if EOF has already happened.
    func markExit(_ code: Int32) -> Bool { lock.withLock { status = code; return eof } }

    /// Appends a chunk of output; true if `check` matched for the first time.
    func append(_ chunk: Data, check: ((Data) -> Bool)?) -> Bool {
        lock.withLock {
            buffer.append(chunk)
            guard let check, !matched, check(buffer) else { return false }
            matched = true
            return true
        }
    }

    /// true if this very call finished the run.
    @discardableResult
    func finish(_ result: Result<Data, Error>) -> Bool {
        let c: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !done else { return nil }
            done = true
            return continuation
        }
        c?.resume(with: result)
        return c != nil
    }
}
