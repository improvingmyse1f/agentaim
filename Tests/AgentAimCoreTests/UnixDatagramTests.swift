import Darwin
import Foundation
import Testing
@testable import AgentAimCore

private final class LockedEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentHookEvent?

    func set(_ event: AgentHookEvent?) {
        lock.lock()
        value = event
        lock.unlock()
    }

    func get() -> AgentHookEvent? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedServers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UnixDatagramServer] = []

    func append(_ server: UnixDatagramServer) {
        lock.lock()
        values.append(server)
        lock.unlock()
    }

    func all() -> [UnixDatagramServer] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct UnixDatagramTests {
    @Test func temporarySocketReceivesSanitizedEventDatagram() throws {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/aa-test-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
        let received = DispatchSemaphore(value: 0)
        let decoded = LockedEvent()

        let server = UnixDatagramServer(socketURL: socketURL) { data in
            decoded.set(try? AgentIPCCodec.decode(data))
            received.signal()
        }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let event = AgentHookEvent(
            provider: .codex,
            sessionID: "ipc-session",
            turnID: "turn-1",
            hookEventName: "Stop",
            notificationType: nil,
            timestamp: 42
        )
        try UnixDatagramClient.send(AgentIPCCodec.encode(event), to: socketURL)

        #expect(received.wait(timeout: .now() + 2) == .success)
        #expect(decoded.get() == event)
    }

    @Test func hookForwarderSanitizesAndSendsToTemporarySocket() throws {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/aa-hook-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
        let received = DispatchSemaphore(value: 0)
        let decoded = LockedEvent()
        let server = UnixDatagramServer(socketURL: socketURL) { data in
            decoded.set(try? AgentIPCCodec.decode(data))
            received.signal()
        }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let input = Data(#"{"session_id":"helper","hook_event_name":"Stop","prompt":"never forward"}"#.utf8)
        HookEventForwarder.forward(input: input, provider: .codex, socketURL: socketURL)

        #expect(received.wait(timeout: .now() + 2) == .success)
        #expect(decoded.get()?.sessionID == "helper")
        #expect(decoded.get()?.hookEventName == "Stop")
    }

    @Test func oversizedDatagramIsRejectedBySender() throws {
        let data = Data(repeating: 0x41, count: AgentAimIPC.maximumDatagramBytes + 1)
        #expect(throws: AgentAimIPCError.self) {
            try UnixDatagramClient.send(data, to: URL(fileURLWithPath: "/tmp/not-used.sock"))
        }
    }

    @Test func runtimeDirectoryAndSocketUsePrivateModes() throws {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/aa-mode-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
        let server = UnixDatagramServer(socketURL: socketURL) { _ in }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: temporaryDirectory.path)
        let socketAttributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((socketAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func secondServerCannotReplaceAnActiveSocket() throws {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/aa-active-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
        let received = DispatchSemaphore(value: 0)
        let decoded = LockedEvent()

        let first = UnixDatagramServer(socketURL: socketURL) { data in
            guard let event = try? AgentIPCCodec.decode(data) else { return }
            decoded.set(event)
            received.signal()
        }
        try first.start()
        defer {
            first.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let second = UnixDatagramServer(socketURL: socketURL) { _ in }
        #expect(throws: AgentAimIPCError.self) {
            try second.start()
        }

        let event = AgentHookEvent(
            provider: .claude,
            sessionID: "still-owned-by-first",
            turnID: "turn-1",
            hookEventName: "PermissionRequest",
            notificationType: nil,
            timestamp: 84
        )
        try UnixDatagramClient.send(AgentIPCCodec.encode(event), to: socketURL)

        #expect(received.wait(timeout: .now() + 2) == .success)
        #expect(decoded.get() == event)
    }

    @Test func simultaneousServersNeverLoseTheWinningSocketPath() throws {
        for iteration in 0..<40 {
            let temporaryDirectory = URL(
                fileURLWithPath: "/tmp/aa-race-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
            let received = DispatchSemaphore(value: 0)
            let startGate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            let winners = LockedServers()
            let servers = (0..<2).map { _ in
                UnixDatagramServer(socketURL: socketURL) { data in
                    guard (try? AgentIPCCodec.decode(data)) != nil else { return }
                    received.signal()
                }
            }

            for server in servers {
                group.enter()
                DispatchQueue.global().async {
                    startGate.wait()
                    if (try? server.start()) != nil {
                        winners.append(server)
                    }
                    group.leave()
                }
            }
            startGate.signal()
            startGate.signal()
            #expect(group.wait(timeout: .now() + 2) == .success)
            #expect(winners.all().count == 1, "iteration \(iteration)")

            let event = AgentHookEvent(
                provider: .codex,
                sessionID: "race-\(iteration)",
                turnID: "1",
                hookEventName: "Stop",
                notificationType: nil,
                timestamp: TimeInterval(iteration)
            )
            try UnixDatagramClient.send(AgentIPCCodec.encode(event), to: socketURL)
            #expect(received.wait(timeout: .now() + 2) == .success, "iteration \(iteration)")

            servers.forEach { $0.stop() }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    @Test func stopWaitsUntilAnInFlightHandlerReleasesTheDescriptor() throws {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/aa-stop-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
        let handlerStarted = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let server = UnixDatagramServer(socketURL: socketURL) { _ in
            handlerStarted.signal()
            releaseHandler.wait()
        }
        try server.start()
        defer {
            releaseHandler.signal()
            server.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try UnixDatagramClient.send(Data([0]), to: socketURL)
        #expect(handlerStarted.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            server.stop()
            stopFinished.signal()
        }
        #expect(stopFinished.wait(timeout: .now() + 0.05) == .timedOut)
        releaseHandler.signal()
        #expect(stopFinished.wait(timeout: .now() + 2) == .success)
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    @Test func stoppingAnOldServerDoesNotUnlinkAReplacementSocket() throws {
        let temporaryDirectory = URL(
            fileURLWithPath: "/tmp/aa-owner-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = temporaryDirectory.appendingPathComponent("events.sock")
        let first = UnixDatagramServer(socketURL: socketURL) { _ in }
        let replacementReceived = DispatchSemaphore(value: 0)
        let replacement = UnixDatagramServer(socketURL: socketURL) { _ in
            replacementReceived.signal()
        }
        defer {
            first.stop()
            replacement.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try first.start()
        #expect(Darwin.unlink(socketURL.path) == 0)
        try replacement.start()

        first.stop()
        #expect(FileManager.default.fileExists(atPath: socketURL.path))
        try UnixDatagramClient.send(Data([0]), to: socketURL)
        #expect(replacementReceived.wait(timeout: .now() + 2) == .success)
    }
}
