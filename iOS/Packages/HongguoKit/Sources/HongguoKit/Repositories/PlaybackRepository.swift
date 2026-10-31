import Foundation

/// 播放模型仓库。2026-10-29 起服务端基本只给每台匿名设备一次播放模型，所以这里：
/// - 只在调用方真正要播放时请求，不提供任何预取接口；
/// - 全局串行（AsyncGate），同一集并发请求合并（TaskCoalescer），结果按集缓存；
/// - ANONYMOUS_LIMITED：重置设备后重试，最多 2 次；DEVICE_REJECTED：重置后重试 1 次；
/// - RATE_LIMITED：建议等待 ≤ 10 秒时退避重试（最多 2 次），超过 10 秒直接失败并进入冷却期，
///   冷却期内的请求不发网络、立即失败，避免连续触发限流；
/// - 其他错误（TRANSPORT 等）不自动重试，交给界面的“重试”按钮。
public actor PlaybackRepository {
    public struct Policy: Sendable {
        public var maxLimitedResets = 2
        public var maxRejectedResets = 1
        public var maxRateLimitRetries = 2
        /// 超过这个等待时间就不在原地等，直接提示用户稍后再试。
        public var maxInlineWait: TimeInterval = 10
        /// 服务端没给建议等待时间时的退避基数（第 n 次重试等待 base × 2ⁿ⁻¹）。
        public var defaultBackoff: TimeInterval = 1
        /// 流地址离过期不足这个时间就视为过期。
        public var expiryMargin: TimeInterval = 30
        public init() {}
    }

    private let service: HongguoService
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date
    private let policy: Policy
    private let gate = AsyncGate()
    private let coalescer = TaskCoalescer<String, PlaybackInfo>()

    private var cache: [String: PlaybackInfo] = [:]
    private var cooldownUntil: Date?

    public init(service: HongguoService, sleeper: Sleeper = TaskSleeper(), policy: Policy = Policy(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.sleeper = sleeper
        self.policy = policy
        self.now = now
    }

    /// 内存里已有的结果（不发请求）。
    /// 加密分集也要按 expiresAt 判过期：它的流地址同样带签名，过期后再用会 403。
    public func cached(_ episodeId: String) -> PlaybackInfo? {
        guard let info = cache[episodeId] else { return nil }
        // 一条可播流都没有（例如服务端只给了 DASH）说明这一集当前确实放不了，
        // 反复请求只会白耗额度，所以这个结果也当作有效缓存。
        if info.streams.isEmpty { return info }
        if let exp = info.expiresAt, exp.timeIntervalSince(now()) < policy.expiryMargin {
            return nil
        }
        return info
    }

    /// 冷却期剩余秒数；nil 表示不在冷却期。
    public func cooldownRemaining() -> TimeInterval? {
        guard let until = cooldownUntil else { return nil }
        let left = until.timeIntervalSince(now())
        return left > 0 ? left : nil
    }

    /// 取得一集的播放模型。只应在用户真正要播放这一集时调用。
    public func playback(for episodeId: String) async throws -> PlaybackInfo {
        if let hit = cached(episodeId) { return hit }
        return try await coalescer.value(for: episodeId) { commit in
            try await self.gate.acquire() // 排队中可以被取消
            do {
                let info = try await self.resolveSerialized(episodeId, commit: commit)
                await self.gate.release()
                return info
            } catch {
                await self.gate.release()
                throw error
            }
        }
    }

    private func resolveSerialized(_ episodeId: String, commit: TaskCoalescer<String, PlaybackInfo>.Commit) async throws -> PlaybackInfo {
        if let hit = cached(episodeId) { return hit }
        try Task.checkCancellation()

        var limitedResets = 0
        var rejectedResets = 0
        var rateRetries = 0
        var lastLimited: AppError?

        while true {
            if let left = cooldownRemaining() {
                throw AppError(.rateLimited, debugMessage: "cooldown", retryAfter: left)
            }
            await commit() // 请求即将发出：从这里起即使页面离开也让它跑完并缓存结果
            do {
                let info = try await service.resolvePlayback(episodeId)
                cache[episodeId] = info
                return info
            } catch let e as AppError {
                switch e.code {
                case .anonymousLimited:
                    lastLimited = e
                    guard limitedResets < policy.maxLimitedResets else {
                        throw AppError(.playbackQuotaExhausted,
                                       debugMessage: "ANONYMOUS_LIMITED after \(limitedResets) resets: \(lastLimited?.debugMessage ?? "")")
                    }
                    limitedResets += 1
                    AppLog.net("playback limited, resetDevice #\(limitedResets)")
                    try await service.resetDevice()

                case .deviceRejected:
                    guard rejectedResets < policy.maxRejectedResets else { throw e }
                    rejectedResets += 1
                    AppLog.net("device rejected, resetDevice")
                    try await service.resetDevice()

                case .rateLimited:
                    let wait = e.retryAfter ?? policy.defaultBackoff * pow(2, Double(rateRetries))
                    guard wait <= policy.maxInlineWait, rateRetries < policy.maxRateLimitRetries else {
                        cooldownUntil = now().addingTimeInterval(max(wait, policy.maxInlineWait))
                        throw AppError(.rateLimited, debugMessage: e.debugMessage, retryAfter: wait)
                    }
                    rateRetries += 1
                    AppLog.net("rate limited, backoff \(wait)s (#\(rateRetries))")
                    try await sleeper.sleep(seconds: wait)

                default:
                    throw e
                }
            }
        }
    }
}
