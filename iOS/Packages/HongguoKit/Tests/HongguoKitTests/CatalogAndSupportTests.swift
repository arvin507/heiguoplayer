import XCTest
@testable import HongguoKit

final class CatalogRepositoryTests: XCTestCase {
    func testEmptySearchReportedAsLimitedIsTreatedAsEmpty() async throws {
        let mock = MockHongguoService()
        mock.searchResult = { _, _ in .failure(.limited) }
        let page = try await CatalogRepository(service: mock).search("不存在的剧", cursor: nil)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(mock.resetCallCount, 0, "列表接口的 ANONYMOUS_LIMITED 不应触发重置设备")
    }

    func testEpisodesPaginateAndDedupe() async throws {
        let mock = MockHongguoService()
        mock.episodesResult = { sid, cursor in
            switch cursor {
            case nil: .success(PageResult(items: [ep(sid, 2), ep(sid, 1)], cursor: "p2", hasMore: true))
            case "p2": .success(PageResult(items: [ep(sid, 2), ep(sid, 3)], cursor: "p3", hasMore: true))
            default: .success(PageResult(items: [], cursor: nil, hasMore: false))
            }
        }
        let eps = try await CatalogRepository(service: mock).episodes("s")
        XCTAssertEqual(eps.map(\.number), [1, 2, 3])
    }

    func testEpisodesStopWhenCursorDoesNotAdvance() async throws {
        let mock = MockHongguoService()
        mock.episodesResult = { sid, _ in .success(PageResult(items: [ep(sid, 1)], cursor: "same", hasMore: true)) }
        let eps = try await CatalogRepository(service: mock).episodes("s")
        XCTAssertEqual(eps.count, 1)
        XCTAssertLessThanOrEqual(mock.count { if case .episodes = $0 { true } else { false } }, 2)
    }

    func testSeriesIsCachedAndCoalesced() async throws {
        let mock = MockHongguoService()
        let repo = CatalogRepository(service: mock)
        async let a = repo.series("s1")
        async let b = repo.series("s1")
        _ = try await (a, b)
        _ = try await repo.series("s1")
        XCTAssertEqual(mock.count { $0 == .series("s1") }, 1)
    }

    func testPrefetchNeverResolvesPlayback() async throws {
        let mock = MockHongguoService()
        mock.episodesResult = { sid, _ in .success(PageResult(items: [ep(sid, 1)], cursor: nil, hasMore: false)) }
        let repo = CatalogRepository(service: mock)
        await repo.prefetchMetadata("s1")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.playbackCallCount, 0)
        let cached = await repo.cachedEpisodes("s1")
        XCTAssertEqual(cached?.count, 1)
    }

    func testContentUnavailablePropagates() async {
        let mock = MockHongguoService()
        mock.seriesResult = { _ in .failure(AppError(.contentUnavailable)) }
        do { _ = try await CatalogRepository(service: mock).series("x"); XCTFail() } catch let e as AppError {
            XCTAssertEqual(e.userMessage, "内容已下架或无权访问")
        } catch { XCTFail("\(error)") }
    }
}

func ep(_ sid: String, _ n: Int) -> EpisodeItem { EpisodeItem(id: "\(sid)-\(n)", seriesId: sid, number: n) }

final class SupportTests: XCTestCase {
    func testRedactorStripsQueryValues() {
        let line = "GET https://api.example.com/reading/x?device_id=1234567890123&iid=987&aid=1967 -> 200"
        let out = Redactor.redact(line)
        XCTAssertFalse(out.contains("1234567890123"))
        XCTAssertFalse(out.contains("987&"))
        XCTAssertTrue(out.contains("device_id=***"))
        XCTAssertTrue(out.contains("https://api.example.com/reading/x"))
        XCTAssertTrue(out.hasSuffix("-> 200"))
    }

    func testLinkParser() {
        XCTAssertEqual(SeriesLinkParser.parse(" 7675400266065136665 "), "7675400266065136665")
        XCTAssertEqual(SeriesLinkParser.parse("https://h5.example.com/share?series_id=7675400266065136665&from=x"), "7675400266065136665")
        XCTAssertEqual(SeriesLinkParser.parse("https://h5.example.com/video/7675400266065136665/detail"), "7675400266065136665")
        XCTAssertEqual(SeriesLinkParser.parse("快来看《全球死考》 https://x.cn/abc?book_id=7675400266065136665 复制打开"), "7675400266065136665")
        XCTAssertEqual(SeriesLinkParser.parse("我在看短剧 7675400266065136665，一起来"), "7675400266065136665")
        XCTAssertNil(SeriesLinkParser.parse("https://example.com/hello"))
        XCTAssertNil(SeriesLinkParser.parse(""))
    }

    func testErrorMessagesAreChineseAndKeepCode() {
        let e = AppError(.transport, debugMessage: "dial tcp: timeout")
        XCTAssertEqual(e.userMessage, "网络连接失败，请检查网络后重试")
        XCTAssertTrue(e.debugDescription.contains("TRANSPORT"))
        XCTAssertNil(AppError.from(CancellationError()))
    }

    func testGateCancelsQueuedWaiter() async throws {
        let gate = AsyncGate()
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do { try await waiter.value; XCTFail() } catch is CancellationError {}
        let queued = await gate.queuedCount
        XCTAssertEqual(queued, 0)
        await gate.release()
        try await gate.acquire() // 没有被泄漏的占位
    }
}


final class SuggestionKeywordTests: XCTestCase {
    func testDirectRowWithContentIdFallsBackToText() {
        XCTAssertEqual(LiveHongguoService.suggestionKeyword(text: "全球死考", keyword: "7512345678901234567"), "全球死考")
    }

    func testNormalKeywordIsKept() {
        XCTAssertEqual(LiveHongguoService.suggestionKeyword(text: "全球死考 第二季", keyword: "全球死考"), "全球死考")
    }

    func testEmptyKeywordUsesText() {
        XCTAssertEqual(LiveHongguoService.suggestionKeyword(text: "全球死考", keyword: ""), "全球死考")
    }

    func testShortNumericKeywordIsKept() {
        // 像“2024”这样的短数字是正常搜索词，不是内容 ID
        XCTAssertEqual(LiveHongguoService.suggestionKeyword(text: "2024", keyword: "2024"), "2024")
    }
}
