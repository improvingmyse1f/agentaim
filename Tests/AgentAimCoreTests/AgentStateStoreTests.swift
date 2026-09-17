import Foundation
import Testing
@testable import AgentAimCore

struct AgentStateStoreTests {
    @Test func hookMappingCoversSupportedLifecycleEvents() {
        #expect(mapped("UserPromptSubmit") == .working(startsNewTurn: true))
        #expect(mapped("PreToolUse") == .working(startsNewTurn: false))
        #expect(mapped("PostToolUse") == .working(startsNewTurn: false))
        #expect(mapped("PermissionRequest") == .waiting)
        #expect(mapped("Elicitation") == .waiting)
        #expect(mapped("Stop") == .responded)
        #expect(mapped("StopFailure") == .failed)
        #expect(mapped("PostToolUseFailure") == .working(startsNewTurn: false))
        #expect(mapped("PostToolUseFailure", isInterrupt: true) == .interrupted)
        #expect(mapped("ElicitationResult") == .working(startsNewTurn: false))
        #expect(mapped("Interrupt") == .interrupted)
        #expect(mapped("SessionEnd") == .remove)
        #expect(mapped("SessionStart") == nil)
    }

    @Test func notificationSubtypeMapping() {
        #expect(mapped("Notification", notification: "permission_prompt") == .waiting)
        #expect(mapped("Notification", notification: "idle_prompt") == .responded)
        #expect(mapped("Notification", notification: "other") == nil)
    }

    @Test func aggregateUsesAcceptedPriorityAcrossSessions() {
        var store = AgentStateStore()
        apply(&store, provider: .codex, session: "one", turn: "1", name: "UserPromptSubmit", time: 1)
        #expect(store.aggregate.phase == .working)

        apply(&store, provider: .claude, session: "two", turn: "1", name: "Stop", time: 2)
        #expect(store.aggregate.phase == .responded)

        apply(&store, provider: .codex, session: "three", turn: "1", name: "PermissionRequest", time: 3)
        #expect(store.aggregate.phase == .waiting)

        apply(&store, provider: .claude, session: "four", turn: "1", name: "StopFailure", time: 4)
        #expect(store.aggregate.phase == .failed)
        #expect(store.aggregate.sessionCount == 4)
    }

    @Test func terminalStateRejectsLateWorkingUntilNewTurn() {
        var store = AgentStateStore()
        apply(&store, provider: .codex, session: "s", turn: "turn-1", name: "Stop", time: 20)

        let late = apply(&store, provider: .codex, session: "s", turn: "turn-1", name: "PostToolUse", time: 21)
        #expect(!late.accepted)
        #expect(store.aggregate.phase == .responded)

        let newTurn = apply(&store, provider: .codex, session: "s", turn: "turn-2", name: "UserPromptSubmit", time: 22)
        #expect(newTurn.accepted)
        #expect(newTurn.startedNewTurn)
        #expect(store.aggregate.phase == .working)
    }

    @Test func onlyUserPromptMarksAnAcceptedTransitionAsANewTurn() {
        var store = AgentStateStore()

        let firstTool = apply(
            &store,
            provider: .codex,
            session: "tool-first",
            turn: "turn-1",
            name: "PreToolUse",
            time: 1
        )
        #expect(firstTool.accepted)
        #expect(!firstTool.startedNewTurn)

        let prompt = apply(
            &store,
            provider: .codex,
            session: "prompt",
            turn: "turn-1",
            name: "UserPromptSubmit",
            time: 2
        )
        #expect(prompt.accepted)
        #expect(prompt.startedNewTurn)

        let duplicate = apply(
            &store,
            provider: .codex,
            session: "prompt",
            turn: "turn-1",
            name: "UserPromptSubmit",
            time: 2
        )
        #expect(!duplicate.accepted)
        #expect(!duplicate.startedNewTurn)
    }

    @Test func workingLookupTracksTheScheduledSessionAndTurn() {
        var store = AgentStateStore()
        apply(&store, provider: .codex, session: "s", turn: "turn-1", name: "UserPromptSubmit", time: 1)

        #expect(store.isWorking(provider: .codex, sessionID: "s", turnID: "turn-1"))
        #expect(!store.isWorking(provider: .codex, sessionID: "s", turnID: "turn-2"))

        apply(&store, provider: .codex, session: "s", turn: "turn-1", name: "Stop", time: 2)
        #expect(!store.isWorking(provider: .codex, sessionID: "s", turnID: "turn-1"))
    }

    @Test func olderAndDuplicateEventsAreIdempotent() {
        var store = AgentStateStore()
        let first = hook(provider: .claude, session: "s", turn: "1", name: "PermissionRequest", time: 10)
        let firstTransition = store.apply(first)
        let duplicateTransition = store.apply(first)
        let olderTransition = store.apply(hook(provider: .claude, session: "s", turn: "1", name: "PreToolUse", time: 9))

        #expect(firstTransition.attention == .waiting)
        #expect(!duplicateTransition.accepted)
        #expect(duplicateTransition.attention == nil)
        #expect(!olderTransition.accepted)
        #expect(store.aggregate.phase == .waiting)
    }

    @Test func attentionIsIndependentFromMaskedAggregate() {
        var store = AgentStateStore()
        apply(&store, provider: .codex, session: "failed", turn: "1", name: "StopFailure", time: 1)

        let waiting = apply(&store, provider: .claude, session: "waiting", turn: "1", name: "PermissionRequest", time: 2)
        #expect(waiting.aggregate.phase == .failed)
        #expect(waiting.attention == .waiting)
    }

    @Test func sessionEndRemovesOnlyMatchingSession() {
        var store = AgentStateStore()
        apply(&store, provider: .codex, session: "same", turn: "1", name: "UserPromptSubmit", time: 1)
        apply(&store, provider: .claude, session: "same", turn: "1", name: "PermissionRequest", time: 1)

        let transition = apply(&store, provider: .codex, session: "same", turn: "1", name: "SessionEnd", time: 2)
        #expect(transition.accepted)
        #expect(store.aggregate.phase == .waiting)
        #expect(store.aggregate.sessionCount == 1)
    }

    @Test func sessionEndTombstoneRejectsStrayEventsButAllowsANewPrompt() {
        var store = AgentStateStore()
        apply(&store, provider: .codex, session: "ended", turn: "1", name: "UserPromptSubmit", time: 10)
        apply(&store, provider: .codex, session: "ended", turn: "1", name: "SessionEnd", time: 20)

        let stale = apply(&store, provider: .codex, session: "ended", turn: "1", name: "PermissionRequest", time: 15)
        #expect(!stale.accepted)
        #expect(store.aggregate.sessionCount == 0)

        let strayNewerEvent = apply(
            &store,
            provider: .codex,
            session: "ended",
            turn: "1",
            name: "PermissionRequest",
            time: 21
        )
        #expect(!strayNewerEvent.accepted)
        #expect(store.aggregate.sessionCount == 0)

        let newer = apply(&store, provider: .codex, session: "ended", turn: "2", name: "UserPromptSubmit", time: 22)
        #expect(newer.accepted)
        #expect(store.aggregate.phase == .working)
        #expect(store.aggregate.sessionCount == 1)
    }

    @Test func interruptRequestsAttentionAndMovesSessionToIdle() {
        var store = AgentStateStore()
        apply(&store, provider: .claude, session: "s", turn: "1", name: "UserPromptSubmit", time: 1)
        let transition = store.apply(hook(
            provider: .claude,
            session: "s",
            turn: "1",
            name: "PostToolUseFailure",
            isInterrupt: true,
            time: 2
        ))

        #expect(transition.accepted)
        #expect(transition.attention == .interrupted)
        #expect(store.aggregate.phase == .idle)

        let lateToolCompletion = apply(
            &store,
            provider: .claude,
            session: "s",
            turn: "1",
            name: "PostToolUse",
            time: 3
        )
        #expect(!lateToolCompletion.accepted)
        #expect(store.aggregate.phase == .idle)
    }

    private func mapped(_ name: String, notification: String? = nil, isInterrupt: Bool = false) -> AgentStateAction? {
        AgentEventMapper.action(for: hook(name: name, notification: notification, isInterrupt: isInterrupt))
    }

    @discardableResult
    private func apply(
        _ store: inout AgentStateStore,
        provider: AgentProvider,
        session: String,
        turn: String?,
        name: String,
        time: TimeInterval
    ) -> AgentStateTransition {
        store.apply(hook(provider: provider, session: session, turn: turn, name: name, time: time))
    }

    private func hook(
        provider: AgentProvider = .codex,
        session: String = "session",
        turn: String? = "turn",
        name: String,
        notification: String? = nil,
        isInterrupt: Bool = false,
        time: TimeInterval = 1
    ) -> AgentHookEvent {
        AgentHookEvent(
            provider: provider,
            sessionID: session,
            turnID: turn,
            hookEventName: name,
            notificationType: notification,
            isInterrupt: isInterrupt,
            timestamp: time
        )
    }
}
