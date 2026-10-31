import Foundation

public struct QualityOption: Hashable, Identifiable, Sendable {
    public var height: Int
    public var label: String
    public var id: Int { height }
    public init(height: Int, label: String) { self.height = height; self.label = label }
}

/// 清晰度的选项与选择规则（纯函数，方便测试）。
public enum Quality {
    public static func label(_ s: StreamInfo) -> String {
        if !s.definition.isEmpty { return s.definition }
        return s.height > 0 ? "\(s.height)p" : "默认"
    }

    /// 可选的清晰度：按高度去重（同一高度取排在前面的，也就是码率更高的那条），从高到低。
    public static func options(_ streams: [StreamInfo]) -> [QualityOption] {
        var seen = Set<Int>()
        return streams.filter { $0.height > 0 && seen.insert($0.height).inserted }
            .sorted { $0.height > $1.height }
            .map { QualityOption(height: $0.height, label: label($0)) }
    }

    /// 选一条流。preferredHeight 为 0（没选过）时用默认规则；
    /// 否则优先同高度，其次不超过它的最高一档，再不行就取最低的一档。
    public static func pick(_ info: PlaybackInfo, preferredHeight: Int) -> StreamInfo? {
        let list = info.streams
        guard !list.isEmpty else { return nil }
        guard preferredHeight > 0 else { return info.preferredStream }
        if let exact = list.first(where: { $0.height == preferredHeight }) { return exact }
        if let below = list.filter({ $0.height > 0 && $0.height <= preferredHeight }).max(by: { $0.height < $1.height }) { return below }
        return list.filter { $0.height > 0 }.min(by: { $0.height < $1.height }) ?? list.first
    }
}
