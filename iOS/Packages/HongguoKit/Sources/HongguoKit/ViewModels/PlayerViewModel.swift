import Foundation

/// 播放一部剧：选集、请求播放模型（仅在真正要播时）、断点续播、自动连播、加密分集解密。
/// 不持有 AVPlayer：界面拿 `state` 里的 URL 自己播放，再把进度和结束事件回传，方便测试。
@MainActor
@Observable
public final class PlayerViewModel {
    public enum State: Equatable {
        case idle
        case resolving
        /// 可以播放：地址、起播秒数。加密分集给的是解密后的本地文件地址。
        case ready(url: URL, startAt: Double)
        /// 正在下载 / 解密加密分集，progress 是 0...1。
        case preparing(progress: Double)
        /// 加密分集，但服务端没有下发可用的内容密钥。
        case keyUnavailable
        /// 服务端禁止播放该集。
        case unplayable
        case failed(AppError)
    }

    public let seriesId: String
    public private(set) var seriesTitle: String
    public private(set) var coverURL: URL?
    public private(set) var episodes: [EpisodeItem]
    public private(set) var index: Int
    public private(set) var state: State = .idle
    public var autoplayNext = true

    private let env: AppEnvironment
    /// 播完当前集后，后台预解密后面几集；0 表示不预取（推荐流用）。
    private let prefetchCount: Int
    private var pendingStart: Double
    private var resolveTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var streams: [StreamInfo] = []
    private var info: PlaybackInfo?
    /// 可选的清晰度和当前选中的一档，界面据此显示菜单。
    public private(set) var qualityOptions: [QualityOption] = []
    public private(set) var selectedHeight = 0
    private static let heightKey = "preferredHeight"
    /// 用户选的清晰度（高度，0 表示没选过，用默认规则）。记在本机，下次启动仍然有效。
    public static var preferredHeight: Int {
        get { UserDefaults.standard.integer(forKey: heightKey) }
        set { UserDefaults.standard.set(newValue, forKey: heightKey) }
    }
    private var streamCursor = 0
    private var lastSaved: (number: Int, seconds: Double, at: Date)?
    private var duration: Double = 0
    /// 每隔多少秒写一次进度。
    static let saveInterval: TimeInterval = 5

    public init(seriesId: String, seriesTitle: String, coverURL: URL?, episodes: [EpisodeItem],
                startIndex: Int, startAt: Double, env: AppEnvironment, prefetchCount: Int = 0) {
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.coverURL = coverURL
        self.episodes = episodes
        self.index = min(max(0, startIndex), max(0, episodes.count - 1))
        self.pendingStart = startAt
        self.env = env
        self.prefetchCount = max(0, prefetchCount)
    }

    public var current: EpisodeItem? { episodes.indices.contains(index) ? episodes[index] : nil }
    public var hasNext: Bool { index + 1 < episodes.count }
    public var hasPrevious: Bool { index > 0 }

    /// 开始播放当前集。重复调用不会重复请求（仓库层缓存 + 合并）。
    public func start() {
        play(at: index, startAt: pendingStart)
    }

    public func play(at newIndex: Int, startAt: Double? = nil) {
        guard episodes.indices.contains(newIndex) else { return }
        flushProgress()
        resolveTask?.cancel()
        // 换集就重新算预取范围，旧任务停掉（已经排进 store 队列的会继续跑完）。
        prefetchTask?.cancel()
        index = newIndex
        duration = 0
        let ep = episodes[newIndex]
        // startAt 为 nil 或负数：用本机记录的进度续播
        let resume = startAt.flatMap { $0 >= 0 ? $0 : nil } ?? resumeSeconds(for: ep)
        pendingStart = 0

        if !ep.playable { state = .unplayable; return }

        state = .resolving
        let repo = env.playback
        resolveTask = Task {
            do {
                let info = try await repo.playback(for: ep.id)
                guard !Task.isCancelled, self.current?.id == ep.id else { return }
                try await self.startWith(ep: ep, newIndex: newIndex, info: info, preferredHeight: Self.preferredHeight, resume: resume)
            } catch {
                self.fail(error, for: ep)
            }
        }
    }

    /// 当前集能播了之后，把后面几集也下载解密好，切集时直接走本地文件。
    /// 只有详情页起的播放器会传 `prefetchCount > 0`；推荐流不预取，
    /// 否则刷几屏就会把每台设备有限的播放额度耗光。
    private func schedulePrefetch(after index: Int) {
        guard prefetchCount > 0, index + 1 < episodes.count else { return }
        let end = min(index + 1 + prefetchCount, episodes.count)
        let targets = Array(episodes[(index + 1)..<end])
        guard !targets.isEmpty else { return }

        let env = self.env
        prefetchTask = Task { @MainActor in
            for ep in targets {
                if Task.isCancelled { return }
                do {
                    let info = try await env.playback.playback(for: ep.id)
                    if Task.isCancelled { return }
                    guard let stream = Quality.pick(info, preferredHeight: Self.preferredHeight),
                          info.isProtected || stream.isProtected,
                          let key = info.usableKey else { continue }
                    await env.protectedMedia.enqueue([.init(episodeId: ep.id, stream: stream, key: key)])
                } catch {
                    // 额度用尽 / 网络失败：后面的集大概率也一样，停止预取，不再继续消耗额度。
                    AppLog.net("prefetch resolve \(ep.id) failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }


    private func fail(_ error: Error, for ep: EpisodeItem) {
        guard current?.id == ep.id else { return }
        if error is CancellationError { return }
        let mapped: AppError
        if let failure = error as? ProtectedMediaStore.Failure {
            // 下载/解密失败对用户来说就是「这一集没准备好」，按网络类错误提示并可重试。
            mapped = AppError(.transport, debugMessage: failure.localizedDescription)
        } else {
            mapped = AppError.from(error) ?? AppError(.unknown, debugMessage: String(describing: error))
        }
        AppLog.error(mapped, context: "playback")
        state = .failed(mapped)
    }

    /// 拿到播放模型之后：按清晰度选流，未加密直接播，加密的下载 + 解密到本地再播。
    private func startWith(ep: EpisodeItem, newIndex: Int, info: PlaybackInfo, preferredHeight: Int, resume: Double) async throws {
        self.streams = info.streams
        self.streamCursor = 0
        self.info = info
        guard let stream = Quality.pick(info, preferredHeight: preferredHeight) else {
            self.state = .failed(AppError(.noPlayableStream))
            return
        }
        if let i = info.streams.firstIndex(where: { $0.url == stream.url }) { self.streamCursor = i }
        self.qualityOptions = Quality.options(info.streams)
        self.selectedHeight = stream.height
        self.duration = Double(info.durationSeconds)

        // 未加密：直接把远端地址交给 AVPlayer。
        guard info.isProtected || stream.isProtected else {
            self.state = .ready(url: stream.url, startAt: resume)
            self.schedulePrefetch(after: newIndex)
            return
        }

        // 加密：必须有 16 字节内容密钥才解得开。
        guard let key = info.usableKey else {
            self.env.library.markEncrypted(ep.id, seriesId: self.seriesId)
            self.state = .keyUnavailable
            return
        }
        self.env.library.markEncrypted(ep.id, seriesId: self.seriesId)

        let store = self.env.protectedMedia
        let stages = await store.prepare(episodeId: ep.id, stream: stream, key: key)
        for try await stage in stages {
            guard !Task.isCancelled, self.current?.id == ep.id else { return }
            switch stage {
            case .downloading(let p):
                // 下载占前 35%，解密占后 65%，进度条不会来回跳。
                self.state = .preparing(progress: min(0.35, p * 0.35))
            case .decrypting(let p):
                self.state = .preparing(progress: 0.35 + p * 0.65)
            case .ready(let url):
                self.state = .ready(url: url, startAt: resume)
                self.schedulePrefetch(after: newIndex)
            }
        }
    }

    /// 切换清晰度：用已经拿到的播放模型，不再请求（不消耗播放额度），从当前位置接着播。
    /// 加密分集会下载并解密对应清晰度的那一份（按“分集 + 清晰度”缓存）。
    public func setQuality(_ height: Int) {
        guard let ep = current, let info, height != selectedHeight else { return }
        Self.preferredHeight = height
        let resume = (lastSaved?.number == ep.number ? lastSaved?.seconds : nil) ?? 0
        let idx = index
        resolveTask?.cancel()
        prefetchTask?.cancel()
        state = .resolving
        resolveTask = Task {
            do {
                try await self.startWith(ep: ep, newIndex: idx, info: info, preferredHeight: height, resume: resume)
            } catch {
                self.fail(error, for: ep)
            }
        }
    }

    public func retry() { play(at: index) }
    public func next() { if hasNext { play(at: index + 1, startAt: 0) } }
    public func previous() { if hasPrevious { play(at: index - 1) } }

    /// AVPlayer 播放当前地址失败时调用：依次换备用地址、其他清晰度；都失败才报错。不会重新请求播放模型。
    /// 解密后的本地文件没有备用地址，直接报错。
    public func playerFailed(_ message: String, at seconds: Double) {
        guard case .ready(let url, _) = state else { return }
        if url.isFileURL {
            state = .failed(AppError(.noPlayableStream, debugMessage: message))
            return
        }
        let candidates = streams.flatMap { [$0.url, $0.backupURL].compactMap { $0 } }
        if let i = candidates.firstIndex(of: url), i + 1 < candidates.count {
            state = .ready(url: candidates[i + 1], startAt: seconds)
        } else {
            state = .failed(AppError(.noPlayableStream, debugMessage: message))
        }
    }

    /// 播放进度回调（界面每秒左右调用一次）。
    public func progress(seconds: Double, duration: Double) {
        guard let ep = current, seconds.isFinite else { return }
        if duration.isFinite, duration > 0 { self.duration = duration }
        let now = Date()
        if let l = lastSaved, l.number == ep.number, now.timeIntervalSince(l.at) < Self.saveInterval { 
            lastSaved = (ep.number, seconds, l.at)
            return
        }
        save(ep, seconds)
    }

    /// 当前集播完。
    public func didFinish() {
        if let ep = current { save(ep, max(duration, 1)) }
        if autoplayNext, hasNext { play(at: index + 1, startAt: 0) }
    }

    /// 离开页面：取消未完成的请求，写入最后进度。
    public func stop(at seconds: Double? = nil) {
        resolveTask?.cancel()
        if let seconds, let ep = current, case .ready = state { save(ep, seconds) } else { flushProgress() }
    }

    private func flushProgress() {
        guard let l = lastSaved, let ep = current, l.number == ep.number else { return }
        save(ep, l.seconds)
    }

    private func save(_ ep: EpisodeItem, _ seconds: Double) {
        lastSaved = (ep.number, seconds, Date())
        env.library.saveProgress(seriesId: seriesId, seriesTitle: seriesTitle, coverURL: coverURL,
                                 episode: ep, seconds: seconds, duration: duration)
    }

    private func resumeSeconds(for ep: EpisodeItem) -> Double {
        guard let r = env.library.record(seriesId, number: ep.number), !r.isFinished else { return 0 }
        return max(0, r.progressSeconds - 2) // 往回退 2 秒，接上剧情
    }
}
