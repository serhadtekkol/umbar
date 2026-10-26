import Darwin
import Foundation
import QARunnerCore

/// Identity of a connected peer, as far as the kernel reports it.
struct Peer {
    var uid: UInt32?
    var pid: Int32?
    var path: String?
}

/// The command channel (§3.3): one Unix stream socket in a 0700 directory,
/// one request per connection, connections handled strictly one at a time.
///
/// Serial handling is deliberate. Commands move the real pointer; two of
/// them interleaving would be a correctness bug, and the throughput need is
/// one tester typing commands.
///
/// Thread ownership: `start` spawns one accept thread, which owns the
/// listening descriptor until `stop` closes it; `accept` then fails and the
/// thread returns. Each request is handed to `handler` on the main actor and
/// the accept thread blocks until it answers.
final class SocketServer {
    typealias Handler = @MainActor (_ line: [UInt8], _ peer: Peer) async -> Response

    private let paths: RunnerPaths
    private let expectedUID: UInt32
    private let log: RunnerLog
    private let isArmed: () -> Bool
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let stateLock = NSLock()

    /// Per-connection I/O timeout. A peer that connects and sends nothing
    /// must not hold the only handling slot.
    private static let ioTimeoutSeconds = 5

    init(paths: RunnerPaths, expectedUID: UInt32, log: RunnerLog, isArmed: @escaping () -> Bool, handler: @escaping Handler) {
        self.paths = paths
        self.expectedUID = expectedUID
        self.log = log
        self.isArmed = isArmed
        self.handler = handler
    }

    /// Returns a refusal when the socket could not be set up safely; the
    /// runner then quits rather than run without its only control channel
    /// (in particular without remote disarm).
    func start() -> Refusal? {
        guard paths.socketPathFits else { return Refusal(.ioError, "socket-path-too-long") }
        guard SafeFiles.makePrivateDirectory(paths.supportDir),
              SafeFiles.makeStrictPrivateDirectory(paths.socketDir) else {
            return Refusal(.ioError, "socket-dir")
        }
        // A stale socket from a previous run is removed; anything else at
        // that path is not ours to delete, so refuse instead.
        var st = stat()
        if lstat(paths.socketPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
                return Refusal(.ioError, "socket-path-occupied")
            }
            unlink(paths.socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return Refusal(.ioError, "socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(paths.socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // The directory is 0700, so the window between bind and chmod is
        // not reachable by other users; chmod makes 0600 hold regardless.
        guard bound == 0, chmod(paths.socketPath, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            return Refusal(.ioError, "bind")
        }
        stateLock.lock()
        listenFD = fd
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "qarunner.socket"
        thread.start()
        return nil
    }

    func stop() {
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(paths.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                return
            }
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Self.ioTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let peer = Self.peer(of: conn)
        if let refusal = PeerPolicy.check(peerUID: peer.uid, expectedUID: expectedUID) {
            log.write(LogRecord(time: Date(), event: .peerRefused, callerPID: peer.pid, callerPath: peer.path,
                                refusal: refusal, armed: isArmed(),
                                facts: ["peer_uid": peer.uid.map(String.init) ?? "unknown"]),
                      category: .refuse)
            // No response body: an unauthorized peer learns nothing about
            // the protocol or the arm state.
            return
        }

        var framer = LineFramer()
        var request: [UInt8]?
        var buf = [UInt8](repeating: 0, count: 1024)
        readLoop: while request == nil {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { break }
            for event in framer.append(buf[0..<n]) {
                switch event {
                case .line(let line):
                    request = line
                    break readLoop
                case .overflow:
                    let refusal = Refusal(.lineTooLong)
                    log.write(LogRecord(time: Date(), event: .refused, callerPID: peer.pid, callerPath: peer.path,
                                        refusal: refusal, armed: isArmed()), category: .refuse)
                    send(Response.refusal(refusal), conn)
                    return
                }
            }
        }
        guard let request else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var response = Response.refusal(Refusal(.ioError, "no-response"))
        let handler = self.handler
        Task { @MainActor in
            response = await handler(request, peer)
            semaphore.signal()
        }
        semaphore.wait()
        send(response, conn)
    }

    private func send(_ response: Response, _ conn: Int32) {
        let data = response.line()
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(conn, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// `getpeereid` is the authorization input. `LOCAL_PEERPID` and
    /// `proc_pidpath` are only for the log trail (§3.3).
    private static func peer(of conn: Int32) -> Peer {
        var uid: uid_t = 0, gid: gid_t = 0
        let haveUID = getpeereid(conn, &uid, &gid) == 0
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let havePID = getsockopt(conn, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0
        var path: String?
        if havePID {
            var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                path = String(cString: pathBuf)
            }
        }
        return Peer(uid: haveUID ? uid : nil, pid: havePID ? pid : nil, path: path)
    }
}
