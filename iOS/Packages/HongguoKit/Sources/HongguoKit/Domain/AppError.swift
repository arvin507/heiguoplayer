import Foundation

/// 业务层统一的错误。code 保留 SDK 的错误码用于调试，userMessage 是给用户看的中文。
public struct AppError: Error, Equatable, Sendable, LocalizedError {
    public enum Code: String, Sendable {
        // 与 SDK 一一对应
        case invalidOptions = "INVALID_OPTIONS"
        case profileNotFound = "PROFILE_NOT_FOUND"
        case signerUnavailable = "SIGNER_UNAVAILABLE"
        case authenticationRequired = "AUTHENTICATION_REQUIRED"
        case notProtected = "NOT_PROTECTED"
        case drmProtected = "DRM_PROTECTED"
        case anonymousLimited = "ANONYMOUS_LIMITED"
        case rateLimited = "RATE_LIMITED"
        case transport = "TRANSPORT"
        case signatureRejected = "SIGNATURE_REJECTED"
        case contentUnavailable = "CONTENT_UNAVAILABLE"
        case paramInvalid = "PARAM_INVALID"
        case challengeRequired = "CHALLENGE_REQUIRED"
        case deviceRejected = "DEVICE_REJECTED"
        case endOfList = "END_OF_LIST"
        case albumUnavailable = "ALBUM_UNAVAILABLE"
        case cancelled = "CANCELLED"
        case unknown = "UNKNOWN"
        // App 自己的
        /// 播放额度用尽：重置设备重试后仍拿不到播放模型。
        case playbackQuotaExhausted = "APP_PLAYBACK_QUOTA_EXHAUSTED"
        /// 拿到了播放模型，但没有 AVPlayer 能直接播放的流。
        case noPlayableStream = "APP_NO_PLAYABLE_STREAM"
        /// 响应解析失败，可能是接口改版。
        case decoding = "APP_DECODING"
        /// 分享链接或 ID 无法识别。
        case invalidLink = "APP_INVALID_LINK"
    }

    public var code: Code
    /// 原始信息，只用于调试日志，不展示给用户。
    public var debugMessage: String
    /// 服务端建议的等待时间（秒），nil 表示没有建议。
    public var retryAfter: TimeInterval?

    public init(_ code: Code, debugMessage: String = "", retryAfter: TimeInterval? = nil) {
        self.code = code
        self.debugMessage = debugMessage
        self.retryAfter = retryAfter
    }

    /// 界面上是否显示“重试”按钮。
    public var isRetryable: Bool {
        switch code {
        case .transport, .rateLimited, .unknown, .decoding, .playbackQuotaExhausted, .anonymousLimited, .deviceRejected: true
        default: false
        }
    }

    public var userMessage: String {
        switch code {
        case .transport: "网络连接失败，请检查网络后重试"
        case .rateLimited:
            if let s = retryAfter, s > 0 { "请求太频繁，请约 \(Int(s.rounded(.up))) 秒后再试" } else { "请求太频繁，请稍后再试" }
        case .contentUnavailable: "内容已下架或无权访问"
        case .anonymousLimited: "暂时没有获取到内容，请稍后再试"
        case .playbackQuotaExhausted: "当前设备的播放次数已用完，已自动更换设备重试仍未成功，请稍后再试"
        case .deviceRejected: "设备被服务端拒绝，请稍后重试"
        case .drmProtected: "该集是加密内容，没有拿到可用的内容密钥"
        case .noPlayableStream: "该集没有可直接播放的视频流"
        case .authenticationRequired: "该内容需要登录才能观看，本 App 不支持"
        case .challengeRequired: "服务端要求人机验证，请稍后再试"
        case .albumUnavailable: "没有找到其他季"
        case .endOfList: "没有更多内容了"
        case .invalidLink: "无法识别的链接或 ID"
        case .decoding: "数据格式异常，接口可能已改版"
        case .paramInvalid, .invalidOptions: "请求参数有误"
        case .signatureRejected, .signerUnavailable: "请求签名失败，请稍后再试"
        case .profileNotFound: "设备信息缺失，请重试"
        case .notProtected: "内容密钥请求无效"
        case .cancelled: "已取消"
        case .unknown: "出了点问题，请稍后再试"
        }
    }

    public var errorDescription: String? { userMessage }

    /// 调试用：错误码 + 原始信息。
    public var debugDescription: String { "[\(code.rawValue)] \(debugMessage)" }
}

extension AppError {
    /// 把任意错误归一成 AppError；CancellationError 原样返回 nil，调用方应当直接忽略。
    public static func from(_ error: Error) -> AppError? {
        if error is CancellationError { return nil }
        if let e = error as? AppError { return e.code == .cancelled ? nil : e }
        if error is DecodingError { return AppError(.decoding, debugMessage: String(describing: error)) }
        if let u = error as? URLError {
            return u.code == .cancelled ? nil : AppError(.transport, debugMessage: u.localizedDescription)
        }
        return AppError(.unknown, debugMessage: String(describing: error))
    }
}
