import XCTest
@testable import HongguoKit

final class PlaybackRepositoryTests: XCTestCase {
    private func make(_ mock: MockHongguoService, clock: TestClock = TestClock(), sleeper: RecordingSleeper = RecordingSleeper()) -> PlaybackRepository {
        PlaybackRepository(service: mock, sleeper: sleeper, now: { clock.now })
    }

    func testSuccessIsCachedAndNotRequestedTwice() async throws {
        let mock = MockHongguoService()
        let repo = make(mock)
        _ = try await repo.playback(for: "e1")
        _ = try await repo.playback(for: "e1")
        XCTAssertEqual(mock.playbackCallCount, 1)
    }

    func testAnonymousLimitedResetsDeviceThenSucceeds() async throws {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(.limited), .success(MockHongguoService.samplePlayback("x"))]
        let info = try await make(mock).playback(for: "e1")
        XCTAssertFalse(info.streams.isEmpty)
        XCTAssertEqual(mock.calls, [.resolvePlayback("e1"), .resetDevice, .resolvePlayback("e1")])
    }

    func testAnonymousLimitedGivesUpAfterTwoResets() async {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(.limited)]
        do {
            _ = try await make(mock).playback(for: "e1")
            XCTFail("应当失败")
        } catch let e as AppError {
            XCTAssertEqual(e.code, .playbackQuotaExhausted)
            XCTAssertFalse(e.userMessage.isEmpty)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(mock.resetCallCount, 2)
        XCTAssertEqual(mock.playbackCallCount, 3) // 1 次原始 + 2 次重试，不会无限重试
    }

    func testDeviceRejectedResetsOnce() async {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(AppError(.deviceRejected))]
        do { _ = try await make(mock).playback(for: "e1"); XCTFail() } catch let e as AppError {
            XCTAssertEqual(e.code, .deviceRejected)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(mock.resetCallCount, 1)
        XCTAssertEqual(mock.playbackCallCount, 2)
    }

    func testDeviceRejectedThenSuccess() async throws {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(AppError(.deviceRejected)), .success(MockHongguoService.samplePlayback("x"))]
        _ = try await make(mock).playback(for: "e1")
        XCTAssertEqual(mock.resetCallCount, 1)
    }

    func testShortRateLimitBacksOffWithServerHint() async throws {
        let mock = MockHongguoService()
        let sleeper = RecordingSleeper()
        mock.playbackScript = [.failure(.rate(3)), .success(MockHongguoService.samplePlayback("x"))]
        _ = try await make(mock, sleeper: sleeper).playback(for: "e1")
        XCTAssertEqual(sleeper.waits, [3])
        XCTAssertEqual(mock.playbackCallCount, 2)
    }

    func testRateLimitWithoutHintUsesExponentialBackoffAndStops() async {
        let mock = MockHongguoService()
        let sleeper = RecordingSleeper()
        mock.playbackScript = [.failure(.rate(nil))]
        do { _ = try await make(mock, sleeper: sleeper).playback(for: "e1"); XCTFail() } catch let e as AppError {
            XCTAssertEqual(e.code, .rateLimited)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(sleeper.waits, [1, 2])
        XCTAssertEqual(mock.playbackCallCount, 3)
    }

    func testLongRateLimitFailsFastAndEntersCooldown() async throws {
        let mock = MockHongguoService()
        let sleeper = RecordingSleeper()
        let clock = TestClock()
        mock.playbackScript = [.failure(.rate(30)), .success(MockHongguoService.samplePlayback("x"))]
        let repo = make(mock, clock: clock, sleeper: sleeper)
        do { _ = try await repo.playback(for: "e1"); XCTFail() } catch let e as AppError {
            XCTAssertEqual(e.code, .rateLimited)
            XCTAssertEqual(e.retryAfter, 30)
            XCTAssertTrue(e.userMessage.contains("30"))
        }
        XCTAssertTrue(sleeper.waits.isEmpty, "超过 10 秒不应原地等待")

        // 冷却期内连续点击：不发请求，立即失败
        for _ in 0..<5 {
            do { _ = try await repo.playback(for: "e2"); XCTFail() } catch let e as AppError { XCTAssertEqual(e.code, .rateLimited) }
        }
        XCTAssertEqual(mock.playbackCallCount, 1)

        clock.advance(31)
        _ = try await repo.playback(for: "e2")
        XCTAssertEqual(mock.playbackCallCount, 2)
    }

    func testTransportIsNotRetriedAutomatically() async {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(AppError(.transport))]
        do { _ = try await make(mock).playback(for: "e1"); XCTFail() } catch let e as AppError {
            XCTAssertEqual(e.code, .transport)
            XCTAssertTrue(e.isRetryable)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(mock.playbackCallCount, 1)
    }

    func testFailureIsNotCachedSoManualRetryWorks() async throws {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(AppError(.transport)), .success(MockHongguoService.samplePlayback("x"))]
        let repo = make(mock)
        _ = try? await repo.playback(for: "e1")
        _ = try await repo.playback(for: "e1")
        XCTAssertEqual(mock.playbackCallCount, 2)
    }

    func testProtectedResultIsCachedWhileStreamIsFresh() async throws {
        let mock = MockHongguoService()
        let clock = TestClock()
        mock.playbackScript = [.success(MockHongguoService.samplePlayback("x", protected: true))]
        let repo = make(mock, clock: clock)
        let a = try await repo.playback(for: "e1")
        XCTAssertTrue(a.isProtected)
        XCTAssertNotNil(a.contentKey, "加密分集要带上内容密钥")
        XCTAssertFalse(a.streams.isEmpty, "加密流也要保留，否则没法解密")
        clock.advance(60)
        _ = try await repo.playback(for: "e1")
        XCTAssertEqual(mock.playbackCallCount, 1, "地址没过期时应命中缓存")
    }

    func testExpiredStreamIsResolvedAgain() async throws {
        let mock = MockHongguoService()
        let clock = TestClock()
        var p = MockHongguoService.samplePlayback("x")
        p.expiresAt = clock.now.addingTimeInterval(120)
        mock.playbackScript = [.success(p)]
        let repo = make(mock, clock: clock)
        _ = try await repo.playback(for: "e1")
        clock.advance(100) // 离过期不足 30 秒
        _ = try await repo.playback(for: "e1")
        XCTAssertEqual(mock.playbackCallCount, 2)
    }

    func testConcurrentSameEpisodeIsCoalesced() async throws {
        let mock = MockHongguoService()
        mock.playbackDelay = 0.05
        let repo = make(mock)
        try await withThrowingTaskGroup(of: PlaybackInfo.self) { group in
            for _ in 0..<5 { group.addTask { try await repo.playback(for: "e1") } }
            for try await _ in group {}
        }
        XCTAssertEqual(mock.playbackCallCount, 1)
    }

    func testRequestsAreSerialized() async throws {
        let mock = SerialProbeService()
        let repo = PlaybackRepository(service: mock, sleeper: RecordingSleeper())
        try await withThrowingTaskGroup(of: PlaybackInfo.self) { group in
            for i in 0..<4 { group.addTask { try await repo.playback(for: "e\(i)") } }
            for try await _ in group {}
        }
        XCTAssertEqual(mock.maxConcurrent, 1)
        XCTAssertEqual(mock.total, 4)
    }

    func testQueuedRequestIsCancelledWithoutHittingNetwork() async throws {
        let mock = MockHongguoService()
        mock.playbackDelay = 0.3
        let repo = make(mock)
        let first = Task { try await repo.playback(for: "e1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { try await repo.playback(for: "e2") } // 排在 e1 后面
        try await Task.sleep(nanoseconds: 50_000_000)
        second.cancel()
        do { _ = try await second.value; XCTFail("应当被取消") } catch is CancellationError {} catch { XCTFail("\(error)") }
        _ = try await first.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.calls.filter { $0 == .resolvePlayback("e2") }.count, 0, "排队中被取消的请求不应发出")
    }

    func testStartedRequestKeepsRunningAndIsCachedAfterCallerLeaves() async throws {
        let mock = MockHongguoService()
        mock.playbackDelay = 0.2
        let repo = make(mock)
        let t = Task { try await repo.playback(for: "e1") }
        try await Task.sleep(nanoseconds: 50_000_000) // 请求已发出
        t.cancel()
        do { _ = try await t.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cached = await repo.cached("e1")
        XCTAssertNotNil(cached, "已消耗额度的结果应当缓存")
        _ = try await repo.playback(for: "e1")
        XCTAssertEqual(mock.playbackCallCount, 1)
    }

    func testResetDeviceFailureStopsRetrying() async {
        let mock = MockHongguoService()
        mock.playbackScript = [.failure(.limited)]
        mock.resetDeviceError = AppError(.transport)
        do { _ = try await make(mock).playback(for: "e1"); XCTFail() } catch let e as AppError {
            XCTAssertEqual(e.code, .transport)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(mock.playbackCallCount, 1)
    }
}

/// 记录 resolvePlayback 的最大并发数。
final class SerialProbeService: HongguoService, @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var total = 0

    func resolvePlayback(_ episodeId: String) async throws -> PlaybackInfo {
        lock.withLock { current += 1; total += 1; maxConcurrent = max(maxConcurrent, current) }
        try await Task.sleep(nanoseconds: 20_000_000)
        lock.withLock { current -= 1 }
        return MockHongguoService.samplePlayback(episodeId)
    }
    func resetDevice() async throws {}
    func discover(cursor: String?) async throws -> PageResult<SeriesItem> { .empty }
    func search(_ query: String, cursor: String?) async throws -> PageResult<SeriesItem> { .empty }
    func suggest(_ prefix: String) async throws -> [SearchSuggestion] { [] }
    func hotSearch() async throws -> HotSearchInfo { HotSearchInfo() }
    func searchCues() async throws -> [String] { [] }
    func series(_ seriesId: String) async throws -> SeriesInfo { SeriesInfo(id: seriesId, title: "") }
    func seriesBatch(_ seriesIds: [String]) async throws -> [SeriesInfo] { [] }
    func episodes(_ seriesId: String, cursor: String?) async throws -> PageResult<EpisodeItem> { .empty }
    func filterPanel() async throws -> [FilterRowInfo] { [] }
    func filter(selections: [String: [String]], cursor: String?) async throws -> PageResult<SeriesItem> { .empty }
    func rank(content: String?, board: String?, cursor: String?) async throws -> RankPageInfo { RankPageInfo(contents: [], content: "", board: "", page: .empty) }
    func newReleases(date: String?, cursor: String?) async throws -> NewReleaseDayInfo { NewReleaseDayInfo(date: "", dates: [], page: .empty) }
}
