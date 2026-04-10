import Foundation
import Darwin

/// IPC between daemon (server) and CLI (client) over a Unix domain socket.
/// Per-user socket at ~/.t-space.sock. JSON request/response, newline-delimited.

enum IPC {
    static var socketPath: String {
        NSHomeDirectory() + "/.t-space.sock"
    }

    struct Request: Codable {
        let argv: [String]
    }

    struct Response: Codable {
        let out: String
        let err: String
        let code: Int
    }
}

enum IPCError: Error, CustomStringConvertible {
    case socketCreate(Int32)
    case bind(Int32)
    case listen(Int32)
    case connect(Int32)
    case io(String)

    var description: String {
        switch self {
        case .socketCreate(let e): return "socket() failed: errno=\(e)"
        case .bind(let e):         return "bind() failed: errno=\(e)"
        case .listen(let e):       return "listen() failed: errno=\(e)"
        case .connect(let e):      return "connect() failed: errno=\(e)"
        case .io(let m):           return "io: \(m)"
        }
    }
}

// MARK: - Low-level helpers

private func makeUnixAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    precondition(bytes.count <= capacity, "socket path too long: \(path)")
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            for i in 0..<bytes.count { dst[i] = bytes[i] }
        }
    }
    return addr
}

private func bindUnix(_ fd: Int32, _ path: String) -> Bool {
    var addr = makeUnixAddr(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, len) == 0
        }
    }
}

private func connectUnix(_ fd: Int32, _ path: String) -> Bool {
    var addr = makeUnixAddr(path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, len) == 0
        }
    }
}

/// Read a single newline-terminated line. Returns nil on EOF/error.
private func readLine(fd: Int32) -> String? {
    var buf: [UInt8] = []
    var b: UInt8 = 0
    while true {
        let n = read(fd, &b, 1)
        if n <= 0 { break }
        if b == 0x0A { break }
        buf.append(b)
    }
    if buf.isEmpty { return nil }
    return String(bytes: buf, encoding: .utf8)
}

/// Write all bytes plus a trailing newline.
@discardableResult
private func writeAll(fd: Int32, _ s: String) -> Bool {
    let data = (s + "\n").data(using: .utf8)!
    return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
        var off = 0
        let base = ptr.baseAddress!
        while off < data.count {
            let n = write(fd, base.advanced(by: off), data.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

// MARK: - Server

class IPCServer {
    private var listenFd: Int32 = -1
    private let handler: (IPC.Request) -> IPC.Response

    init(handler: @escaping (IPC.Request) -> IPC.Response) {
        self.handler = handler
    }

    func start() throws {
        let path = IPC.socketPath

        // Clean up stale socket from a previous run
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw IPCError.socketCreate(errno)
        }

        guard bindUnix(listenFd, path) else {
            let e = errno
            close(listenFd); listenFd = -1
            throw IPCError.bind(e)
        }

        chmod(path, 0o600)

        guard listen(listenFd, 16) == 0 else {
            let e = errno
            close(listenFd); listenFd = -1
            throw IPCError.listen(e)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }

        print("IPC listening on \(path)")
    }

    private func acceptLoop() {
        while listenFd >= 0 {
            let cfd = accept(listenFd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                if listenFd < 0 { return }  // shutdown
                continue
            }
            handleConnection(cfd)
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        guard let line = readLine(fd: fd),
              let data = line.data(using: .utf8),
              let req = try? JSONDecoder().decode(IPC.Request.self, from: data) else {
            sendResponse(fd, IPC.Response(out: "", err: "invalid request", code: 1))
            return
        }

        // Dispatch to main thread (state mutations must be main-threaded).
        var response = IPC.Response(out: "", err: "", code: 0)
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            response = self.handler(req)
            sem.signal()
        }
        sem.wait()

        sendResponse(fd, response)
    }

    private func sendResponse(_ fd: Int32, _ resp: IPC.Response) {
        guard let data = try? JSONEncoder().encode(resp),
              let str = String(data: data, encoding: .utf8) else { return }
        writeAll(fd: fd, str)
    }
}

// MARK: - stdout capture

/// Run a block with stdout redirected to a pipe, returning the captured text.
/// After the block completes, stdout is restored and the captured text is also
/// echoed to the original stdout so the daemon's terminal log is preserved.
func withCapturedStdout(_ block: () -> Void) -> String {
    fflush(stdout)
    let saved = dup(fileno(stdout))

    var pipefds: [Int32] = [0, 0]
    guard pipe(&pipefds) == 0 else {
        block()
        return ""
    }
    dup2(pipefds[1], fileno(stdout))
    close(pipefds[1])

    block()

    fflush(stdout)
    dup2(saved, fileno(stdout))
    close(saved)

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(pipefds[0], &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    close(pipefds[0])

    let captured = String(data: data, encoding: .utf8) ?? ""
    // Echo back to daemon's restored stdout so terminal log is preserved
    if !captured.isEmpty {
        FileHandle.standardOutput.write(Data(captured.utf8))
    }
    return captured
}

// MARK: - Client

func ipcClient(_ request: IPC.Request) throws -> IPC.Response {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.socketCreate(errno) }
    defer { close(fd) }

    guard connectUnix(fd, IPC.socketPath) else {
        throw IPCError.connect(errno)
    }

    let reqData = try JSONEncoder().encode(request)
    guard let reqStr = String(data: reqData, encoding: .utf8) else {
        throw IPCError.io("encode request")
    }
    guard writeAll(fd: fd, reqStr) else {
        throw IPCError.io("write request")
    }

    guard let line = readLine(fd: fd),
          let data = line.data(using: .utf8) else {
        throw IPCError.io("read response")
    }
    return try JSONDecoder().decode(IPC.Response.self, from: data)
}
