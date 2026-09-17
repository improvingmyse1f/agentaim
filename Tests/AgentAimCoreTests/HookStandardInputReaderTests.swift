import Darwin
import Foundation
import Testing
@testable import AgentAimCore

/// 回归测试：stdin 读取的 EOF 语义。
///
/// 历史 bug：`FileHandle.read(upToCount:)` 在 EOF 返回 `nil`，旧实现把 nil 当错误，
/// 于是「读全了 JSON 再遇 EOF」=「失败」，转发器静默 exit 0，事件一条都没送出去。
/// 下面第一例就是这条 bug 的墓碑：它必须在 EOF 之后仍然交出已读到的内容。
@Suite("Hook stdin 读取")
struct HookStandardInputReaderTests {
    /// 造一根管道，把 `bytes` 写完并关闭写端 —— 这正是 hook 看到 stdin 的样子。
    private static func makePipe(writing bytes: Data) -> FileHandle {
        var descriptors: [Int32] = [-1, -1]
        precondition(Darwin.pipe(&descriptors) == 0, "创建管道失败")
        let readHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let writeHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        if !bytes.isEmpty {
            writeHandle.write(bytes)
        }
        writeHandle.closeFile()
        return readHandle
    }

    @Test("EOF 不能被当成失败：payload 一个字节都不能丢")
    func returnsEverythingBeforeEOF() {
        let payload = Data(#"{"session_id":"abc","hook_event_name":"Stop"}"#.utf8)

        let data = HookStandardInputReader.read(from: Self.makePipe(writing: payload))

        #expect(data == payload)
    }

    @Test("分多次读到的块要拼全")
    func concatenatesMultipleReads() {
        let first = Data(#"{"session_id":"abc","#.utf8)
        let second = Data(#""hook_event_name":"Notification"}"#.utf8)

        let data = HookStandardInputReader.read(from: Self.makePipe(writing: first + second))

        #expect(data == first + second)
    }

    @Test("空输入返回空内容，而不是 nil（交给 JSON 校验去拒绝）")
    func emptyInputIsNotNil() {
        let data = HookStandardInputReader.read(from: Self.makePipe(writing: Data()))

        #expect(data != nil)
        #expect(data?.isEmpty == true)
    }

    @Test("超过上限的输入判为异常，返回 nil")
    func oversizedInputIsRejected() {
        let limit = 64
        let handle = Self.makePipe(writing: Data(repeating: 0x61, count: limit + 1))

        let data = HookStandardInputReader.read(from: handle, maximumBytes: limit)

        #expect(data == nil)
    }

    @Test("恰好等于上限的输入是合法的")
    func exactlyAtLimitIsAccepted() {
        let limit = 64
        let payload = Data(repeating: 0x61, count: limit)

        let data = HookStandardInputReader.read(from: Self.makePipe(writing: payload), maximumBytes: limit)

        #expect(data == payload)
    }
}

@Suite("provider 参数解析")
struct AgentProviderArgumentTests {
    @Test("WorkBuddy 与 Claude Code 分属不同 provider，会话不会互相干扰")
    func workbuddyIsItsOwnProvider() {
        #expect(AgentProvider(argument: "workbuddy") == .workbuddy)
        #expect(AgentProvider(argument: "codebuddy") == .workbuddy)
        #expect(AgentProvider(argument: "claude") == .claude)
        #expect(AgentProvider(argument: "codex") == .codex)
        #expect(AgentProvider(argument: "workbuddy") != AgentProvider(argument: "claude"))
    }

    @Test("未知 provider 仍然返回 nil")
    func unknownProviderIsRejected() {
        #expect(AgentProvider(argument: "unknown") == nil)
    }
}
