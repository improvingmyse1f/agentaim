import Foundation

public enum HookEventSanitizerError: Error {
    case invalidJSON
    case missingRequiredField(String)
    case invalidField(String)
}

public enum HookEventSanitizer {
    public static let maximumInputBytes = 1_048_576
    private static let maximumIdentifierLength = 256
    private static let maximumEventNameLength = 128

    public static func decode(_ data: Data, provider: AgentProvider) throws -> AgentHookEvent {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            throw HookEventSanitizerError.invalidJSON
        }

        let sessionID = try requiredString(json, snake: "session_id", camel: "sessionId", limit: maximumIdentifierLength)
        let hookEventName = try requiredString(json, snake: "hook_event_name", camel: "hookEventName", limit: maximumEventNameLength)
        let turnID = try optionalString(json, keys: ["turn_id", "turnId", "prompt_id"], limit: maximumIdentifierLength)
        let notificationType = try optionalString(json, keys: ["notification_type", "notificationType"], limit: maximumEventNameLength)

        return AgentHookEvent(
            provider: provider,
            sessionID: sessionID,
            turnID: turnID,
            hookEventName: hookEventName,
            notificationType: notificationType,
            isInterrupt: json["is_interrupt"] as? Bool == true,
            timestamp: timestamp(json["timestamp"])
        )
    }

    private static func requiredString(
        _ json: [String: Any],
        snake: String,
        camel: String,
        limit: Int
    ) throws -> String {
        guard let value = try optionalString(json, keys: [snake, camel], limit: limit), !value.isEmpty else {
            throw HookEventSanitizerError.missingRequiredField(snake)
        }
        return value
    }

    private static func optionalString(_ json: [String: Any], keys: [String], limit: Int) throws -> String? {
        guard let raw = keys.lazy.compactMap({ json[$0] }).first else { return nil }
        guard let value = raw as? String, value.utf8.count <= limit else {
            throw HookEventSanitizerError.invalidField(keys[0])
        }
        return value
    }

    private static func timestamp(_ raw: Any?) -> TimeInterval {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String {
            if let number = TimeInterval(string) { return number }
            if let date = ISO8601DateFormatter().date(from: string) { return date.timeIntervalSince1970 }
        }
        return Date().timeIntervalSince1970
    }
}
