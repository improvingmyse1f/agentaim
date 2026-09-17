import Darwin
import Foundation

public enum AgentAimIPCError: Error, Equatable {
    case datagramTooLarge
    case invalidSocketPath
    case invalidEvent
    case socketAlreadyInUse
    case socketPathOccupied
    case posix(Int32)
}

private struct SocketPathIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

public enum AgentAimIPC {
    public static let maximumDatagramBytes = 8_192

    public static var runtimeDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentAim", isDirectory: true)
    }

    public static var socketURL: URL {
        runtimeDirectoryURL.appendingPathComponent("events.sock")
    }
}

public enum AgentIPCCodec {
    public static func encode(_ event: AgentHookEvent) throws -> Data {
        let data = try JSONEncoder().encode(event)
        guard data.count <= AgentAimIPC.maximumDatagramBytes else {
            throw AgentAimIPCError.datagramTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> AgentHookEvent {
        guard !data.isEmpty, data.count <= AgentAimIPC.maximumDatagramBytes else {
            throw AgentAimIPCError.datagramTooLarge
        }
        let event = try JSONDecoder().decode(AgentHookEvent.self, from: data)
        guard !event.sessionID.isEmpty,
              event.sessionID.utf8.count <= 256,
              !event.hookEventName.isEmpty,
              event.hookEventName.utf8.count <= 128,
              event.timestamp.isFinite
        else {
            throw AgentAimIPCError.invalidEvent
        }
        return event
    }
}

public enum UnixDatagramClient {
    public static func send(_ data: Data, to socketURL: URL = AgentAimIPC.socketURL) throws {
        guard !data.isEmpty, data.count <= AgentAimIPC.maximumDatagramBytes else {
            throw AgentAimIPCError.datagramTooLarge
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw AgentAimIPCError.posix(errno) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw AgentAimIPCError.posix(errno)
        }

        var (address, length) = try unixAddress(path: socketURL.path)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, socketAddress, length)
                }
            }
        }
        guard sent == data.count else { throw AgentAimIPCError.posix(errno) }
    }
}

public final class UnixDatagramServer: @unchecked Sendable {
    private let socketURL: URL
    private let handler: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "com.agentaim.ipc", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var cleanupFinished: DispatchSemaphore?

    public init(socketURL: URL = AgentAimIPC.socketURL, handler: @escaping @Sendable (Data) -> Void) {
        self.socketURL = socketURL
        self.handler = handler
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor < 0 else { return }

        try preparePrivateDirectory(socketURL.deletingLastPathComponent())
        try prepareSocketPath()

        let newDescriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard newDescriptor >= 0 else { throw AgentAimIPCError.posix(errno) }
        var didBind = false
        var boundIdentity: SocketPathIdentity?

        do {
            var (address, length) = try unixAddress(path: socketURL.path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(newDescriptor, socketAddress, length)
                }
            }
            guard bindResult == 0 else { throw AgentAimIPCError.posix(errno) }
            didBind = true
            guard let identity = try socketPathIdentity(at: socketURL.path) else {
                throw AgentAimIPCError.posix(ENOENT)
            }
            boundIdentity = identity
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else { throw AgentAimIPCError.posix(errno) }
            guard try socketPathIdentity(at: socketURL.path) == identity else {
                throw AgentAimIPCError.socketAlreadyInUse
            }
            guard Darwin.fcntl(newDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw AgentAimIPCError.posix(errno)
            }
        } catch {
            Darwin.close(newDescriptor)
            if didBind, let boundIdentity {
                _ = try? unlinkSocket(at: socketURL.path, ifMatching: boundIdentity)
            }
            throw error
        }
        guard let boundIdentity else {
            Darwin.close(newDescriptor)
            throw AgentAimIPCError.posix(ENOENT)
        }

        descriptor = newDescriptor
        let cleanupFinished = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: newDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drainDatagrams() }
        let socketPath = socketURL.path
        source.setCancelHandler {
            Darwin.close(newDescriptor)
            _ = try? unlinkSocket(at: socketPath, ifMatching: boundIdentity)
            cleanupFinished.signal()
        }
        self.source = source
        self.cleanupFinished = cleanupFinished
        source.resume()
    }

    public func stop() {
        lock.lock()
        descriptor = -1
        let oldSource = source
        source = nil
        let oldCleanupFinished = cleanupFinished
        cleanupFinished = nil
        lock.unlock()

        guard let oldSource else { return }
        oldSource.cancel()
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            oldCleanupFinished?.wait()
        }
    }

    deinit {
        stop()
    }

    private func drainDatagrams() {
        while true {
            lock.lock()
            let currentDescriptor = descriptor
            lock.unlock()
            guard currentDescriptor >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: AgentAimIPC.maximumDatagramBytes + 1)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(currentDescriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            if count == 0 { return }
            guard count <= AgentAimIPC.maximumDatagramBytes else { continue }
            handler(Data(buffer.prefix(count)))
        }
    }

    /// Do not unlink another live AgentAim instance's socket. A one-byte probe is
    /// intentionally not valid AgentAim JSON, so an active receiver drops it without
    /// changing state. ECONNREFUSED identifies the filesystem entry left behind by a
    /// process that exited before it could clean up.
    private func prepareSocketPath() throws {
        guard let existingIdentity = try socketPathIdentity(at: socketURL.path) else { return }

        do {
            try UnixDatagramClient.send(Data([0]), to: socketURL)
        } catch AgentAimIPCError.posix(let code) where code == ECONNREFUSED || code == ENOENT {
            guard try unlinkSocket(at: socketURL.path, ifMatching: existingIdentity) else {
                throw AgentAimIPCError.socketAlreadyInUse
            }
            return
        } catch {
            throw error
        }

        throw AgentAimIPCError.socketAlreadyInUse
    }
}

private func socketPathIdentity(at path: String) throws -> SocketPathIdentity? {
    var metadata = stat()
    let result = path.withCString { Darwin.lstat($0, &metadata) }
    guard result == 0 else {
        if errno == ENOENT { return nil }
        throw AgentAimIPCError.posix(errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFSOCK else {
        throw AgentAimIPCError.socketPathOccupied
    }
    return SocketPathIdentity(device: metadata.st_dev, inode: metadata.st_ino)
}

@discardableResult
private func unlinkSocket(at path: String, ifMatching expected: SocketPathIdentity) throws -> Bool {
    guard let current = try socketPathIdentity(at: path) else { return true }
    guard current == expected else { return false }
    guard Darwin.unlink(path) == 0 || errno == ENOENT else {
        throw AgentAimIPCError.posix(errno)
    }
    return true
}

private func preparePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard Darwin.chmod(url.path, 0o700) == 0 else { throw AgentAimIPCError.posix(errno) }
}

private func unixAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else { throw AgentAimIPCError.invalidSocketPath }

    address.sun_family = sa_family_t(AF_UNIX)
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }
    return (address, length)
}
