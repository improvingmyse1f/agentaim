import Foundation

public enum HookEventForwarder {
    public static func forward(
        input: Data,
        provider: AgentProvider,
        socketURL: URL = AgentAimIPC.socketURL
    ) {
        guard input.count <= HookEventSanitizer.maximumInputBytes,
              let event = try? HookEventSanitizer.decode(input, provider: provider),
              let datagram = try? AgentIPCCodec.encode(event)
        else { return }
        try? UnixDatagramClient.send(datagram, to: socketURL)
    }
}
