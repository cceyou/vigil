import Foundation

public enum HookServerError: Error, CustomStringConvertible {
    case pathTooLong
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong: return "socket path too long"
        case .syscall(let name, let code): return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Owns the Unix domain socket hook.sh talks to. One JSON line per connection; the connection is closed
/// as soon as the line is read so `nc` returns immediately.
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEvent) -> Void

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "cz.krystof.vigil.hookserver")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private let maxLine = 256 * 1024

    public init(socketPath: String, handler: @escaping Handler) {
        self.path = socketPath
        self.handler = handler
    }

    public var isRunning: Bool { queue.sync { listenFD >= 0 } }

    /// Recreates the socket (removing a stale one) and starts accepting.
    public func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            unlink(path)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            guard path.utf8.count < capacity else { throw HookServerError.pathTooLong }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    _ = path.withCString { strncpy(dst, $0, capacity - 1) }
                }
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HookServerError.syscall("socket", errno) }
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { let e = errno; close(fd); throw HookServerError.syscall("bind", e) }
            chmod(path, 0o600)
            guard listen(fd, 16) == 0 else { let e = errno; close(fd); unlink(path); throw HookServerError.syscall("listen", e) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            listenFD = fd
            acceptSource = source
        }
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for (_, c) in connections { c.close() }
            connections.removeAll()
            if listenFD >= 0 { unlink(path) }
            listenFD = -1
        }
    }

    /// True if something is accepting connections on `socketPath` right now (used by the self-test).
    public static func probe(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = socketPath.withCString { strncpy(dst, $0, capacity - 1) }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    // MARK: private

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return } // EAGAIN: drained
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let connection = Connection(fd: client, queue: queue, maxLine: maxLine) { [weak self] event in
                if let event { self?.handler(event) }
            } onClose: { [weak self] fd in
                self?.connections[fd] = nil
            }
            connections[client] = connection
            connection.start()
        }
    }

    private final class Connection {
        let fd: Int32
        private let source: DispatchSourceRead
        private var buffer = Data()
        private var finished = false
        private let maxLine: Int
        private let deliver: (HookEvent?) -> Void
        private let onClose: (Int32) -> Void
        private let queue: DispatchQueue

        init(fd: Int32, queue: DispatchQueue, maxLine: Int, deliver: @escaping (HookEvent?) -> Void,
             onClose: @escaping (Int32) -> Void) {
            self.fd = fd
            self.queue = queue
            self.maxLine = maxLine
            self.deliver = deliver
            self.onClose = onClose
            self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        }

        func start() {
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.resume()
            // A client that connects and never sends anything must not linger.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(parse: true) }
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.contains(0x0A) || buffer.count > maxLine { finish(parse: true) }
            } else if n == 0 {
                finish(parse: true)
            } else if errno != EAGAIN && errno != EINTR {
                finish(parse: false)
            }
        }

        private func finish(parse: Bool) {
            guard !finished else { return }
            finished = true
            if parse, !buffer.isEmpty, buffer.count <= maxLine {
                let line = buffer.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first ?? buffer[...]
                deliver(HookEventParser.parse(Data(line)))
            }
            close()
            onClose(fd)
        }

        func close() {
            source.cancel()
            Darwin.close(fd)
        }
    }
}
