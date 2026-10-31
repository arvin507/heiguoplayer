import Foundation

/// 找剧 · 搜索：输入联想（防抖）、热搜、搜索结果分页。
@MainActor
@Observable
public final class SearchViewModel {
    public var query = "" {
        didSet { if query != oldValue { scheduleSuggest() } }
    }
    public private(set) var submittedQuery: String?
    public private(set) var suggestions: [SearchSuggestion] = []
    public private(set) var hot = HotSearchInfo()
    public private(set) var hotState: LoadState = .idle
    public private(set) var cue: String?
    public let results: Paginator<SeriesItem>

    private let catalog: CatalogRepository
    private var suggestTask: Task<Void, Never>?
    /// 联想防抖间隔。
    public var debounce: TimeInterval = 0.3

    public init(catalog: CatalogRepository) {
        self.catalog = catalog
        self.results = Paginator { _ in .empty }
    }

    public func loadHot() async {
        guard hotState != .loaded else { return }
        hotState = .loading
        async let cues = try? catalog.searchCues()
        do {
            hot = try await catalog.hotSearch()
            hotState = (hot.guesses.isEmpty && hot.boards.isEmpty) ? .empty : .loaded
        } catch {
            if let e = AppError.from(error) { hotState = .failed(e) }
        }
        cue = await cues?.first
    }

    private func scheduleSuggest() {
        suggestTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != submittedQuery else {
            suggestions = []
            return
        }
        let catalog = self.catalog
        let delay = debounce
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let list = (try? await catalog.suggest(text)) ?? []
            guard !Task.isCancelled else { return }
            self.suggestions = Array(list.prefix(10))
        }
    }

    /// 提交搜索。空输入时用搜索框里的提示词。
    public func submit(_ text: String? = nil) async {
        let q = (text ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        let final = q.isEmpty ? (cue ?? "") : q
        guard !final.isEmpty else { return }
        suggestTask?.cancel()
        suggestions = []
        if text != nil || q.isEmpty { query = final }
        submittedQuery = final
        let catalog = self.catalog
        results.reset { cursor in try await catalog.search(final, cursor: cursor) }
        await results.refresh()
    }

    public func clearSearch() {
        suggestTask?.cancel()
        query = ""
        submittedQuery = nil
        suggestions = []
        results.reset { _ in .empty }
    }

    public func cancel() {
        suggestTask?.cancel()
        results.cancel()
    }
}
