import Foundation

/// 追更检查：打开 App（以及回到前台，最多每 10 分钟一次）时，批量拉取追更剧的详情，对比集数。
/// 只在 App 内打标记，不做后台推送。
@MainActor
@Observable
public final class FollowUpdateChecker {
    public private(set) var isChecking = false
    public private(set) var lastChecked: Date?
    private let env: AppEnvironment
    private let minInterval: TimeInterval

    public init(env: AppEnvironment, minInterval: TimeInterval = 600) {
        self.env = env
        self.minInterval = minInterval
    }

    public func checkIfNeeded(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let l = lastChecked, Date().timeIntervalSince(l) < minInterval { return }
        let ids = env.library.followedSeries().filter { !$0.isFinished }.map(\.seriesId)
        guard !ids.isEmpty else { lastChecked = Date(); return }
        isChecking = true
        defer { isChecking = false }
        let infos = await env.catalog.seriesBatch(ids)
        guard !Task.isCancelled else { return }
        env.library.applyLatest(infos)
        lastChecked = Date()
    }
}
