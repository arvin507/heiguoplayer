import Foundation

/// 从分享链接或纯数字文本中取出短剧 ID。SDK 没有提供这个能力，这里用启发式规则：
/// 1. 纯数字（允许前后空白）直接当 ID；
/// 2. 文本里的 URL：先找已知的查询参数（series_id、book_id 等），再找路径里的长数字；
/// 3. 最后在整段文本里找第一个 15～20 位的数字串（分享文案里常夹着 ID）。
public enum SeriesLinkParser {
    static let idKeys = ["series_id", "seriesid", "video_series_id", "book_id", "bookid", "item_id", "id"]
    private static let longDigits = try! NSRegularExpression(pattern: #"(?<!\d)\d{15,20}(?!\d)"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>，。]+"#)

    public static func parse(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy(\.isNumber), (6...20).contains(text.count) { return text }

        let ns = text as NSString
        for m in urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let id = idFromURL(ns.substring(with: m.range)) { return id }
        }
        return firstLongDigits(in: text)
    }

    static func idFromURL(_ raw: String) -> String? {
        guard let comps = URLComponents(string: raw) else { return nil }
        let items = comps.queryItems ?? []
        for key in idKeys {
            if let v = items.first(where: { $0.name.lowercased() == key })?.value,
               v.allSatisfy(\.isNumber), v.count >= 6 {
                return v
            }
        }
        return firstLongDigits(in: comps.path)
    }

    private static func firstLongDigits(in s: String) -> String? {
        let ns = s as NSString
        guard let m = longDigits.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }
}
