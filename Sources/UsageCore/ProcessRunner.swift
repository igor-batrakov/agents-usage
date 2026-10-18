import Foundation

public enum ProcessRunner {
    /// Запускает процесс и возвращает накопленный stdout.
    /// - `input` пишется в stdin; stdin остаётся открытым, пока процесс жив
    ///   (app-server Codex завершается по EOF раньше, чем успевает ответить).
    /// - `until` — досрочный выход: как только накопленный вывод ему удовлетворяет,
    ///   процесс гасится и вывод возвращается.
    /// - По таймауту процесс гасится, бросается ошибка.
    public static func run(
        _ path: String,
        _ arguments: [String],
        input: Data? = nil,
        environment extra: [String: String] = [:],
        timeout: TimeInterval,
        until: (@Sendable (Data) -> Bool)? = nil
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw UsageError.message("не найден \(path)")
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

            // Успешный запуск завершается, когда есть и выход процесса, и EOF stdout —
            // только тогда вывод точно полный. Если потомок унаследовал stdout (hub у agy),
            // EOF не придёт: через 2 с после выхода отдаём то, что накоплено.
            let complete = {
                guard let status = state.exitStatus else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                if status == 0 {
                    state.finish(.success(state.output))
                } else {
                    let name = (path as NSString).lastPathComponent
                    state.finish(.failure(UsageError.message("\(name): код \(status)")))
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
                // terminationHandler не будет вызван — снимаем обработчик здесь, иначе он держит pipe.
                stdout.fileHandleForReading.readabilityHandler = nil
                state.finish(.failure(UsageError.message("не запустить \(path): \(error.localizedDescription)")))
                return
            }
            // Таймаут взводится до записи: если процесс не читает stdin, запись блокируется,
            // и только гашение процесса по таймауту её разблокирует (EPIPE).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if state.finish(.failure(UsageError.message("таймаут \(Int(timeout)) с"))) {
                    stop(process)
                }
            }
            if let input {
                // Отдельная очередь — блокирующая запись не держит поток пула Swift Concurrency.
                // Бросающий вариант: процесс мог уже выйти и закрыть pipe. Небросающий write
                // в этом случае кидает ObjC-исключение и роняет всё приложение.
                // Ошибку записи не отдаём наружу: она значит лишь, что процесс вышел или закрыл
                // stdin, а настоящий итог (код выхода или таймаут) сообщат обработчики выше.
                // stdin не закрываем вручную: pipe закроется вместе с объектами запуска.
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                }
            }
        }
    }

    /// SIGTERM, а если процесс не вышел за 2 с — SIGKILL: зависшие CLI не должны копиться между опросами.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// GUI-приложению не достаётся PATH из шелла — даём минимальный набор.
    static let environment: [String: String] = {
        let home = NSHomeDirectory()
        return [
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
        ]
    }()

    /// Первый исполняемый файл из списка кандидатов (`~` раскрывается).
    public static func locate(_ candidates: [String]) -> String? {
        candidates.map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Общее состояние одного запуска; continuation возобновляется ровно один раз.
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

    /// Отмечает EOF stdout; true — если процесс уже вышел (можно завершать).
    func markEOF() -> Bool { lock.withLock { eof = true; return status != nil } }

    /// Отмечает выход процесса (сигнал — отрицательным кодом); true — если EOF уже был.
    func markExit(_ code: Int32) -> Bool { lock.withLock { status = code; return eof } }

    /// Добавляет кусок вывода; true — если `check` впервые сработал.
    func append(_ chunk: Data, check: ((Data) -> Bool)?) -> Bool {
        lock.withLock {
            buffer.append(chunk)
            guard let check, !matched, check(buffer) else { return false }
            matched = true
            return true
        }
    }

    /// true — если именно этот вызов завершил запуск.
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
