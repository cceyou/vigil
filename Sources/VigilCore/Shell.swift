import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// Runs an executable synchronously with a timeout. Never throws; launch failures come back as status -1.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], stdin input: String? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval = 15) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error)")
        }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        var outData = Data(), errData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        readers.wait()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}
