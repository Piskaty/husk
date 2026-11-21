import Darwin
import Foundation

enum CommandRunner {
    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        captureOutput: Bool = false,
        environment: [String: String]? = nil
    ) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("husk-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        func outputFile(_ name: String) throws -> FileHandle {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return try FileHandle(forUpdating: url)
        }

        let stderr = try outputFile("stderr")
        defer { try? stderr.close() }
        let stdout = captureOutput ? try outputFile("stdout") : nil
        defer { try? stdout?.close() }

        let finished = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout ?? FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw Failure.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
        }

        guard process.terminationStatus == 0 else {
            try stderr.seek(toOffset: 0)
            let data = try stderr.read(upToCount: 8192) ?? Data()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.exit(process.terminationStatus, message)
        }

        guard let stdout else { return "" }
        try stdout.seek(toOffset: 0)
        let limit = 8 * 1024 * 1024
        let output = try stdout.read(upToCount: limit + 1) ?? Data()
        guard output.count <= limit, let text = String(data: output, encoding: .utf8) else {
            throw Failure.invalidOutput
        }
        return text
    }

    private enum Failure: LocalizedError {
        case timedOut(String)
        case exit(Int32, String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .timedOut(let command): return "\(command) exceeded its time limit."
            case .exit(let status, let message): return message.isEmpty ? "Command exited with status \(status)." : message
            case .invalidOutput: return "Command output could not be read completely."
            }
        }
    }
}
