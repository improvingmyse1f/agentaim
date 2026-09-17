import AgentAimCore
import Darwin
import Foundation

private func argument(after name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func run() {
    // 「读 stdin」的 EOF 语义有过一次静默失败的教训，实现与回归测试都在
    // AgentAimCore.HookStandardInputReader 里，这里不再自带一份。
    guard let providerName = argument(after: "--provider") ?? argument(after: "--source"),
          let provider = AgentProvider(argument: providerName),
          let input = HookStandardInputReader.read(from: .standardInput)
    else {
        return
    }

    let socketURL = argument(after: "--socket").map { URL(fileURLWithPath: $0) } ?? AgentAimIPC.socketURL
    HookEventForwarder.forward(input: input, provider: provider, socketURL: socketURL)
}

run()
exit(EXIT_SUCCESS)
