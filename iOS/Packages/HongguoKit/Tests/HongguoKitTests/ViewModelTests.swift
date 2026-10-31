import XCTest
@testable import HongguoKit

@MainActor
final class ViewModelTests: XCTestCase {

    func testPaginatorDedupesAcrossPages() async {
        let p = Paginator<SeriesItem> { cursor in
            switch cursor {
            case nil: PageResult(items: [si("a"), si("b")], cursor: "1", hasMore: true)
            case "1": PageResult(items: [si("b"), si("c")], cursor: "2", hasMore: false)
            default: .empty
            }
        }
        await p.refresh()
        p.loadMore()
        while p.isLoadingMore { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(p.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(p.hasMore)
    }

    func testPaginatorStopsOnRepeatedDuplicatePages() async {
        let counter = Counter()
        let p = Paginator<SeriesItem> { _ in
            let n = counter.next()
            return PageResult(items: [si("a")], cursor: "c\(n)", hasMore: true)
        }
        await p.refresh()
        for _ in 0..<10 {
            p.loadMore()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(p.hasMore, "连续多页全是重复内容时应停止加载")
        XCTAssertLessThanOrEqual(counter.value, 5)
    }

    func testPaginatorEmptyAndErrorStates() async {
        let empty = Paginator<SeriesItem> { _ in .empty }
        await empty.refresh()
        XCTAssertEqual(empty.state, .empty)

        let failing = Paginator<SeriesItem> { _ in throw AppError(.transport) }
        await failing.refresh()
        XCTAssertEqual(failing.state.error?.code, .transport)
    }

    func testPaginatorIgnoresCancellation() async {
        let p = Paginator<SeriesItem> { _ in throw CancellationError() }
        await p.refresh()
        XCTAssertNil(p.state.error, "取消不是错误，不应显示错误态")
        XCTAssertEqual(p.state, .idle, "取消后不能卡在 loading，下次要能重新加载")
    }

    func testPaginatorReloadsAfterCancelledFirstLoad() async {
        let counter = Counter()
        let p = Paginator<SeriesItem> { _ in
            if counter.next() == 1 { throw CancellationError() }
            return PageResult(items: [si("a")], cursor: nil, hasMore: false)
        }
        await p.loadIfNeeded()
        await p.loadIfNeeded()
        XCTAssertEqual(p.state, .loaded)
        XCTAssertEqual(p.items.count, 1)
    }

    private func env(_ mock: MockHongguoService) -> AppEnvironment { AppEnvironment.mock(mock) }

    private func waitState(_ vm: PlayerViewModel, _ pred: (PlayerViewModel.State) -> Bool) async {
        for _ in 0..<200 where !pred(vm.state) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testProtectedEpisodeWithoutKeyShowsKeyUnavailable() async {
        let mock = MockHongguoService()
        mock.playbackScript = [.success(MockHongguoService.sampleProtectedWithoutKey("x"))]
        let e = env(mock)
        let eps = [ep("s", 1)]
        let vm = PlayerViewModel(seriesId: "s", seriesTitle: "S", coverURL: nil, episodes: eps, startIndex: 0, startAt: 0, env: e)
        vm.start()
        await waitState(vm) { $0 == .keyUnavailable }
        XCTAssertEqual(vm.state, .keyUnavailable)
        XCTAssertTrue(e.library.isEncrypted("s-1"), "加密标记仍要记下来，供选集页显示")
        XCTAssertEqual(mock.playbackCallCount, 1)
    }

    func testResumeFromSavedProgress() async {
        let mock = MockHongguoService()
        let e = env(mock)
        let eps = [ep("s", 1), ep("s", 2)]
        let vm = PlayerViewModel(seriesId: "s", seriesTitle: "S", coverURL: nil, episodes: eps, startIndex: 1, startAt: 0, env: e)
        vm.start()
        await waitState(vm) { if case .ready = $0 { true } else { false } }
        vm.progress(seconds: 42, duration: 90)
        vm.stop(at: 42)

        let rec = e.library.lastWatched("s")
        XCTAssertEqual(rec?.episodeNumber, 2)
        XCTAssertEqual(rec?.progressSeconds, 42)

        let detail = SeriesDetailViewModel(seriesId: "s", env: e)
        mock.episodesResult = { sid, _ in .success(PageResult(items: [ep(sid, 1), ep(sid, 2)], cursor: nil, hasMore: false)) }
        await detail.load()
        XCTAssertEqual(detail.resumeTarget?.episode.number, 2)
        XCTAssertEqual(detail.resumeTarget?.seconds, 42)
        if case .inProgress = detail.status(of: eps[1]) {} else { XCTFail("应显示观看进度") }

        // 再次进入播放页：从 40 秒（回退 2 秒）开始
        let vm2 = PlayerViewModel(seriesId: "s", seriesTitle: "S", coverURL: nil, episodes: eps, startIndex: 1, startAt: 0, env: e)
        vm2.play(at: 1)
        await waitState(vm2) { if case .ready = $0 { true } else { false } }
        if case .ready(_, let start) = vm2.state { XCTAssertEqual(start, 40) } else { XCTFail() }
        XCTAssertEqual(mock.playbackCallCount, 1, "同一集的播放模型应命中缓存")
    }

    func testAutoplayRequestsNextOnlyAfterFinish() async {
        let mock = MockHongguoService()
        let e = env(mock)
        let vm = PlayerViewModel(seriesId: "s", seriesTitle: "S", coverURL: nil, episodes: [ep("s", 1), ep("s", 2)], startIndex: 0, startAt: 0, env: e)
        vm.start()
        await waitState(vm) { if case .ready = $0 { true } else { false } }
        XCTAssertEqual(mock.playbackCallCount, 1, "不应预取下一集的播放模型")
        vm.didFinish()
        XCTAssertEqual(vm.index, 1)
        await waitState(vm) { if case .ready = $0 { true } else { false } }
        XCTAssertEqual(mock.playbackCallCount, 2)
        XCTAssertTrue(e.library.record("s", number: 1)?.isFinished ?? false)
    }

    func testFollowUpdateMarksNewEpisodes() async {
        let mock = MockHongguoService()
        let e = env(mock)
        e.library.toggleFollow(SeriesInfo(id: "s", title: "S", episodeCount: 10, status: .ongoing))
        mock.seriesBatchResult = { ids in .success(ids.map { SeriesInfo(id: $0, title: "S", episodeCount: 12, status: .ongoing) }) }
        await FollowUpdateChecker(env: e).checkIfNeeded()
        XCTAssertEqual(e.library.followed("s")?.newEpisodeCount, 2)
        XCTAssertEqual(e.library.updatedFollowCount, 1)
        e.library.acknowledgeUpdate(SeriesInfo(id: "s", title: "S", episodeCount: 12))
        XCTAssertEqual(e.library.updatedFollowCount, 0)
    }

    func testFavoritesAndHistory() {
        let e = env(MockHongguoService())
        let info = SeriesInfo(id: "s", title: "S")
        e.library.toggleFavorite(info)
        XCTAssertTrue(e.library.isFavorite("s"))
        e.library.toggleFavorite(info)
        XCTAssertFalse(e.library.isFavorite("s"))
        e.library.saveProgress(seriesId: "s", seriesTitle: "S", coverURL: nil, episode: ep("s", 1), seconds: 10, duration: 60)
        e.library.saveProgress(seriesId: "s", seriesTitle: "S", coverURL: nil, episode: ep("s", 2), seconds: 5, duration: 60)
        XCTAssertEqual(e.library.history().count, 1, "历史每部剧一条")
        XCTAssertEqual(e.library.history().first?.episodeNumber, 2)
    }

    func testSearchEmptyResultShowsEmptyState() async {
        let mock = MockHongguoService()
        mock.searchResult = { _, _ in .failure(.limited) }
        let vm = SearchViewModel(catalog: CatalogRepository(service: mock))
        await vm.submit("没有这部剧")
        XCTAssertEqual(vm.results.state, .empty)
    }
}

func si(_ id: String) -> SeriesItem { SeriesItem(id: id, title: id) }

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@MainActor
final class EncryptionGuardTests: XCTestCase {
    func testNextEpisodeIsRequestedEvenIfPreviousWasEncrypted() async {
        // 加密分集现在能解密播放，所以不会再因为「这部剧有加密集」跳过后续请求。
        let mock = MockHongguoService()
        mock.playbackScript = [.success(MockHongguoService.sampleProtectedWithoutKey("x"))]
        let e = AppEnvironment.mock(mock)
        let vm = PlayerViewModel(seriesId: "s", seriesTitle: "S", coverURL: nil, episodes: [ep("s", 1), ep("s", 2), ep("s", 3)],
                                 startIndex: 0, startAt: 0, env: e)
        vm.start()
        for _ in 0..<200 where vm.state != .keyUnavailable { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(vm.state, .keyUnavailable)

        vm.next()
        for _ in 0..<200 where vm.state == .resolving { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(mock.playbackCallCount, 2, "下一集应当正常请求播放模型")
    }

    func testFeedPausesAutoplayAfterKeyMissingStreak() {
        let vm = FeedViewModel(env: AppEnvironment.mock())
        vm.noteResult(keyMissing: true)
        vm.noteResult(keyMissing: true)
        XCTAssertFalse(vm.autoplayPaused)
        vm.noteResult(keyMissing: true)
        XCTAssertTrue(vm.autoplayPaused)
        vm.noteResult(keyMissing: false)
        XCTAssertFalse(vm.autoplayPaused)
    }
}
