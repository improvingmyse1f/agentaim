import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    /// WorkBuddy（= CodeBuddy Code）单独一档。
    ///
    /// 它的 payload 与 Claude Code 同构，本来可以借用 `.claude` 蒙混过关，
    /// 但那样两边的会话会落在同一个 provider 命名空间里：Claude Code 在跑时
    /// WorkBuddy 再来一条 `Notification`，两边会互相干扰计数与收局判定。
    /// 分开之后，A 应用的事件永远碰不到 B 应用的会话。
    case workbuddy

    public init?(argument: String) {
        switch argument.lowercased() {
        case "codex": self = .codex
        case "claude", "claude-code": self = .claude
        case "workbuddy", "codebuddy", "codebuddy-code": self = .workbuddy
        default: return nil
        }
    }
}

public struct AgentHookEvent: Codable, Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let turnID: String?
    public let hookEventName: String
    public let notificationType: String?
    public let isInterrupt: Bool
    public let timestamp: TimeInterval

    public init(
        provider: AgentProvider,
        sessionID: String,
        turnID: String?,
        hookEventName: String,
        notificationType: String?,
        isInterrupt: Bool = false,
        timestamp: TimeInterval
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.hookEventName = hookEventName
        self.notificationType = notificationType
        self.isInterrupt = isInterrupt
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case sessionID = "session_id"
        case turnID = "turn_id"
        case hookEventName = "hook_event_name"
        case notificationType = "notification_type"
        case isInterrupt = "is_interrupt"
        case timestamp
    }
}

public enum AgentActivityPhase: Int, Codable, Comparable, Sendable {
    case idle = 0
    case working = 1
    case responded = 2
    case waiting = 3
    case failed = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AgentAttention: Equatable, Sendable {
    case waiting
    case responded
    case failed
    case interrupted
}

public enum AgentStateAction: Equatable, Sendable {
    case working(startsNewTurn: Bool)
    case waiting
    case responded
    case failed
    case interrupted
    case idle
    case remove
}

public enum AgentEventMapper {
    public static func action(for event: AgentHookEvent) -> AgentStateAction? {
        switch event.hookEventName {
        case "UserPromptSubmit":
            return .working(startsNewTurn: true)
        case "PreToolUse", "PostToolUse":
            return .working(startsNewTurn: false)
        case "PermissionRequest", "Elicitation":
            return .waiting
        case "ElicitationResult":
            return .working(startsNewTurn: false)
        case "Stop":
            return .responded
        case "StopFailure":
            return .failed
        case "PostToolUseFailure":
            return event.isInterrupt ? .interrupted : .working(startsNewTurn: false)
        case "Interrupt":
            return .interrupted
        case "SessionEnd":
            return .remove
        case "Notification":
            switch event.notificationType {
            case "permission_prompt": return .waiting
            case "idle_prompt": return .responded
            default: return nil
            }
        default:
            return nil
        }
    }
}

public struct AgentSessionKey: Hashable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

public struct AgentAggregate: Equatable, Sendable {
    public let phase: AgentActivityPhase
    public let sessionCount: Int

    public init(phase: AgentActivityPhase, sessionCount: Int) {
        self.phase = phase
        self.sessionCount = sessionCount
    }
}

public struct AgentStateTransition: Equatable, Sendable {
    public let accepted: Bool
    public let aggregate: AgentAggregate
    public let attention: AgentAttention?
    public let startedNewTurn: Bool

    public init(
        accepted: Bool,
        aggregate: AgentAggregate,
        attention: AgentAttention?,
        startedNewTurn: Bool = false
    ) {
        self.accepted = accepted
        self.aggregate = aggregate
        self.attention = attention
        self.startedNewTurn = startedNewTurn
    }
}

private struct AgentSessionRecord {
    var phase: AgentActivityPhase
    var turnID: String?
    var lastTimestamp: TimeInterval
}

private struct AgentEventIdentity: Hashable {
    let provider: AgentProvider
    let sessionID: String
    let turnID: String?
    let name: String
    let notificationType: String?
    let isInterrupt: Bool
    let timestampBits: UInt64

    init(_ event: AgentHookEvent) {
        provider = event.provider
        sessionID = event.sessionID
        turnID = event.turnID
        name = event.hookEventName
        notificationType = event.notificationType
        isInterrupt = event.isInterrupt
        timestampBits = event.timestamp.bitPattern
    }
}

private struct AgentSessionTombstone: Sendable {
    let key: AgentSessionKey
    let timestamp: TimeInterval
}

public struct AgentStateStore: Sendable {
    private var sessions: [AgentSessionKey: AgentSessionRecord] = [:]
    private var endedSessions: [AgentSessionKey: TimeInterval] = [:]
    private var endedSessionOrder: [AgentSessionTombstone] = []
    private var seenEvents: Set<AgentEventIdentity> = []
    private var seenEventOrder: [AgentEventIdentity] = []
    private let maximumRememberedEvents = 512
    private let maximumRememberedEndedSessions = 512

    public init() {}

    public var aggregate: AgentAggregate {
        let phase = sessions.values.map(\.phase).max() ?? .idle
        return AgentAggregate(phase: phase, sessionCount: sessions.count)
    }

    public func isWorking(provider: AgentProvider, sessionID: String, turnID: String?) -> Bool {
        guard let record = sessions[AgentSessionKey(provider: provider, sessionID: sessionID)],
              record.phase == .working
        else { return false }
        return turnID == nil || record.turnID == turnID
    }

    public mutating func apply(_ event: AgentHookEvent) -> AgentStateTransition {
        guard let action = AgentEventMapper.action(for: event) else {
            return unchanged()
        }

        let identity = AgentEventIdentity(event)
        guard !seenEvents.contains(identity) else { return unchanged() }
        remember(identity)

        let key = AgentSessionKey(provider: event.provider, sessionID: event.sessionID)
        if action == .remove {
            let activeTimestamp = sessions[key]?.lastTimestamp ?? -.infinity
            let endedTimestamp = endedSessions[key] ?? -.infinity
            guard event.timestamp >= activeTimestamp, event.timestamp >= endedTimestamp else {
                return unchanged()
            }
            sessions.removeValue(forKey: key)
            rememberEndedSession(key, timestamp: event.timestamp)
            return AgentStateTransition(accepted: true, aggregate: aggregate, attention: nil)
        }

        if let endedTimestamp = endedSessions[key] {
            guard event.timestamp > endedTimestamp,
                  case .working(startsNewTurn: true) = action
            else {
                return unchanged()
            }
            endedSessions.removeValue(forKey: key)
        }

        guard var record = sessions[key] else {
            let phase = phase(for: action)
            sessions[key] = AgentSessionRecord(phase: phase, turnID: event.turnID, lastTimestamp: event.timestamp)
            let startedNewTurn = if case .working(startsNewTurn: true) = action { true } else { false }
            return AgentStateTransition(
                accepted: true,
                aggregate: aggregate,
                attention: attention(for: action),
                startedNewTurn: startedNewTurn
            )
        }

        guard event.timestamp >= record.lastTimestamp else { return unchanged() }

        let explicitlyStartsTurn: Bool
        if case .working(let startsNewTurn) = action {
            explicitlyStartsTurn = startsNewTurn
        } else {
            explicitlyStartsTurn = false
        }
        let hasDifferentTurn = event.turnID.map { $0 != record.turnID } ?? false
        let startsNewTurn = explicitlyStartsTurn || hasDifferentTurn
        let nextPhase = phase(for: action)

        if !startsNewTurn, isTerminal(record.phase) {
            let isFailureUpgrade = record.phase == .responded && nextPhase == .failed
            let isBecomingIdle = nextPhase == .idle
            guard isFailureUpgrade || isBecomingIdle else { return unchanged() }
        }

        let phaseChanged = record.phase != nextPhase
        let turnChanged = startsNewTurn || (event.turnID != nil && event.turnID != record.turnID)
        record.phase = nextPhase
        if let turnID = event.turnID { record.turnID = turnID }
        record.lastTimestamp = event.timestamp
        sessions[key] = record

        guard phaseChanged || turnChanged else { return unchanged() }
        return AgentStateTransition(
            accepted: true,
            aggregate: aggregate,
            attention: phaseChanged || turnChanged ? attention(for: action) : nil,
            startedNewTurn: explicitlyStartsTurn
        )
    }

    private func unchanged() -> AgentStateTransition {
        AgentStateTransition(accepted: false, aggregate: aggregate, attention: nil)
    }

    private func phase(for action: AgentStateAction) -> AgentActivityPhase {
        switch action {
        case .working: return .working
        case .waiting: return .waiting
        case .responded: return .responded
        case .failed: return .failed
        case .interrupted, .idle, .remove: return .idle
        }
    }

    private func attention(for action: AgentStateAction) -> AgentAttention? {
        switch action {
        case .waiting: return .waiting
        case .responded: return .responded
        case .failed: return .failed
        case .interrupted: return .interrupted
        case .working, .idle, .remove: return nil
        }
    }

    private func isTerminal(_ phase: AgentActivityPhase) -> Bool {
        phase == .idle || phase == .responded || phase == .failed
    }

    private mutating func remember(_ identity: AgentEventIdentity) {
        seenEvents.insert(identity)
        seenEventOrder.append(identity)
        if seenEventOrder.count > maximumRememberedEvents {
            seenEvents.remove(seenEventOrder.removeFirst())
        }
    }

    private mutating func rememberEndedSession(_ key: AgentSessionKey, timestamp: TimeInterval) {
        endedSessions[key] = timestamp
        endedSessionOrder.append(AgentSessionTombstone(key: key, timestamp: timestamp))
        while endedSessionOrder.count > maximumRememberedEndedSessions {
            let oldest = endedSessionOrder.removeFirst()
            if endedSessions[oldest.key] == oldest.timestamp {
                endedSessions.removeValue(forKey: oldest.key)
            }
        }
    }
}
