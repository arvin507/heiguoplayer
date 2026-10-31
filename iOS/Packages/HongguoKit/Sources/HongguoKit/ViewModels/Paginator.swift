import Foundation

/// 通用游标分页：按 ID 去重（服务端会跨页返回重复短剧），处理加载更多、空态、错误。
///
/// 页面消失时调用 cancel()（或依赖 SwiftUI .task 的自动取消），未完成的请求随之取消。
@MainActor
@Observable
public final class Paginator<Item: Identifiable & Sendable> where Item.ID: Hashable & Sendable {
    public typealias Fetch = @Sendable (_ cursor: String?) async throws -> PageResult<Item>

    public private(set) var items: [Item] = []
    public private(set) var state: LoadState = .idle
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: AppError?

    private var fetch: Fetch
    private var cursor: String?
    private var seen = Set<Item.ID>()
    private var loadMoreTask: Task<Void, Never>?
    private var generation = 0
    /// 连续多少页没有新条目就停止（防止服务端一直返回重复内容导致无限加载）。
    private var barrenPages = 0
    static var maxBarrenPages: Int { 3 }

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 换一个数据源（例如筛选条件变化），并清空。
    public func reset(fetch: @escaping Fetch) {
        cancel()
        self.fetch = fetch
        clear()
        state = .idle
    }

    private func clear() {
        items = []
        seen = []
        cursor = nil
        hasMore = false
        loadMoreError = nil
        barrenPages = 0
    }

    /// 首次加载或下拉刷新。在 .task / .refreshable 里 await，取消随页面生命周期。
    public func refresh() async {
        cancel()
        generation += 1
        let gen = generation
        if items.isEmpty { state = .loading }
        do {
            let page = try await fetch(nil)
            guard gen == generation else { return }
            clear()
            append(page)
            state = items.isEmpty ? .empty : .loaded
        } catch {
            guard gen == generation else { return }
            guard let e = AppError.from(error) else {
                // 被取消（页面消失或任务重启）：退回 idle，下次进入时重新加载，而不是卡在 loading
                if items.isEmpty { state = .idle }
                return
            }
            if items.isEmpty { state = .failed(e) } else { loadMoreError = e }
        }
    }

    /// 首次进入页面时调用：已经有数据就不重复加载。
    public func loadIfNeeded() async {
        guard state == .idle || state.error != nil else { return }
        await refresh()
    }

    /// 列表滚到某一项时调用，接近末尾就加载下一页。
    public func onItemAppear(_ item: Item) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }), idx >= items.count - 5 else { return }
        loadMore()
    }

    public func loadMore() {
        guard hasMore, !isLoadingMore, loadMoreError == nil, state == .loaded else { return }
        isLoadingMore = true
        let gen = generation
        let cursor = self.cursor
        let fetch = self.fetch
        loadMoreTask = Task {
            defer { if gen == self.generation { self.isLoadingMore = false } }
            do {
                let page = try await fetch(cursor)
                guard gen == self.generation, !Task.isCancelled else { return }
                self.append(page)
            } catch {
                guard gen == self.generation, let e = AppError.from(error) else { return }
                self.loadMoreError = e
            }
        }
    }

    public func retryLoadMore() {
        loadMoreError = nil
        loadMore()
    }

    public func cancel() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
    }

    private func append(_ page: PageResult<Item>) {
        let fresh = page.items.filter { seen.insert($0.id).inserted }
        items += fresh
        barrenPages = fresh.isEmpty ? barrenPages + 1 : 0
        let advanced = page.cursor != nil && page.cursor != cursor
        cursor = page.cursor
        hasMore = page.hasMore && advanced && barrenPages < Self.maxBarrenPages
    }
}
