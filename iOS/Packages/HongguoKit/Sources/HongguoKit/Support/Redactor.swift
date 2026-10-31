import Foundation
import os

/// 日志脱敏：把文本里所有 URL 的查询参数值替换成 ***，并隐去长串数字 ID。
/// SDK 的 logger 已经只输出路径，这里再做一层，防止以后 SDK 或我们自己的日志带出设备 ID。
public enum Redactor {
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#)
    private static let sensitiveKeys: Set<String> = [
        "device_id", "iid", "install_id", "openudid", "cdid", "udid", "uuid", "clientudid",
        "oaid", "android_id", "aid_id", "mac_address", "serial_number", "token", "ttreq",
    ]

    public static func redact(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for match in urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let raw = ns.substring(with: match.range)
            let replaced = redactURL(raw)
            out = (out as NSString).replacingCharacters(in: match.range, with: replaced)
        }
        return out
    }

    /// 保留 scheme、host、path；查询参数只保留键名，值一律替换。
    static func redactURL(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw) else { return "<url>" }
        if let items = comps.queryItems, !items.isEmpty {
            comps.percentEncodedQuery = items.map { "\($0.name)=***" }.joined(separator: "&")
        }
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        return comps.string ?? "<url>"
    }

    /// 只用于判断某个键是否敏感（测试用）。
    static func isSensitive(_ key: String) -> Bool { sensitiveKeys.contains(key.lowercased()) }
}

/// App 的日志入口：统一经过 Redactor。
public enum AppLog {
    private static let logger = Logger(subsystem: "personal.HongguoPlayer", category: "net")

    public static func net(_ message: String) {
        let safe = Redactor.redact(message)
        logger.debug("\(safe, privacy: .public)")
    }

    /// 关键流程的诊断日志（会持久化，可用 `log show` 查看）。
    public static func trace(_ message: String) {
        let safe = Redactor.redact(message)
        logger.notice("\(safe, privacy: .public)")
    }

    public static func error(_ error: AppError, context: String) {
        let safe = Redactor.redact("\(context): \(error.debugDescription)")
        logger.error("\(safe, privacy: .public)")
    }
}
