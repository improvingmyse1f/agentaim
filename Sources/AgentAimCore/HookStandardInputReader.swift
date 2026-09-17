import Foundation

/// 读取 hook 从 stdin 灌进来的 JSON。
///
/// **为什么单独抽出来**：`FileHandle.read(upToCount:)` 在 **EOF 时返回 `nil`**
/// ——它既不抛错，也不返回空 `Data`。早先的实现写成
/// `guard let chunk = try? input.read(...) else { return nil }`，
/// 于是「JSON 已经完整读进来了，接着遇到 EOF」和「读取出错」被压成同一条路径：
/// 整个函数返回 nil，`AgentAimHook` 静默 `exit 0`，一次事件都没转发出去。
/// （2026-09-14 实测：debug / release / dist 三个二进制、沙箱内外全部失败，
/// 探针打印「第 48 字节处 read 返回 nil」，而 payload 正好 48 字节。）
///
/// 所以这里的约定是：**读到 nil 或空块都视为「读完了」**，用它之前读到的内容收场。
public enum HookStandardInputReader {
    /// - Returns: 读到的字节；超过上限时返回 `nil`（视为异常输入，直接丢弃）。
    ///   输入为空时返回空 `Data`，交由调用方的 JSON 校验去拒绝。
    public static func read(
        from input: FileHandle,
        maximumBytes: Int = HookEventSanitizer.maximumInputBytes
    ) -> Data? {
        var data = Data()

        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { break }
            guard let chunk = try? input.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty
            else { break }
            data.append(chunk)
        }

        return data.count <= maximumBytes ? data : nil
    }
}
