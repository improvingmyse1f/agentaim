import Foundation
import Testing
@testable import AgentAimCore

struct HookSanitizerTests {
    @Test func sanitizerExtractsAllowlistedFieldsOnly() throws {
        let input = Data(#"""
        {
          "session_id":"abc",
          "turn_id":"turn-7",
          "hook_event_name":"PermissionRequest",
          "cwd":"/tmp/work",
          "notification_type":"permission_prompt",
          "error":"denied",
          "timestamp":123.5,
          "prompt":"secret prompt",
          "tool_input":{"token":"secret"},
          "transcript_path":"/secret/path"
        }
        """#.utf8)

        let event = try HookEventSanitizer.decode(input, provider: .claude)
        let encoded = try JSONEncoder().encode(event)
        let output = String(decoding: encoded, as: UTF8.self)

        #expect(event.sessionID == "abc")
        #expect(event.turnID == "turn-7")
        #expect(event.notificationType == "permission_prompt")
        #expect(!event.isInterrupt)
        #expect(!output.contains("secret prompt"))
        #expect(!output.contains("tool_input"))
        #expect(!output.contains("transcript_path"))
        #expect(!output.contains("token"))
        #expect(!output.contains("/tmp/work"))
        #expect(!output.contains("denied"))
        #expect(!output.contains("\"cwd\""))
        #expect(!output.contains("\"error\""))
    }

    @Test func sanitizerRejectsMissingSessionOrUnknownProvider() {
        #expect(throws: HookEventSanitizerError.self) {
            try HookEventSanitizer.decode(Data(#"{"hook_event_name":"Stop"}"#.utf8), provider: .codex)
        }
        #expect(AgentProvider(argument: "unknown") == nil)
    }

    @Test func sanitizerKeepsOnlyClaudeInterruptSentinel() throws {
        let input = Data(#"{"session_id":"abc","hook_event_name":"PostToolUseFailure","is_interrupt":true}"#.utf8)
        let event = try HookEventSanitizer.decode(input, provider: .claude)
        let output = String(decoding: try AgentIPCCodec.encode(event), as: UTF8.self)

        #expect(event.isInterrupt)
        #expect(output.contains("is_interrupt"))
        #expect(AgentEventMapper.action(for: event) == .interrupted)
    }
}
