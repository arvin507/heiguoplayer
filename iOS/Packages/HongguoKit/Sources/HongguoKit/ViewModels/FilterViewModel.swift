import Foundation

/// 找剧 · 分类筛选：面板（题材、分类、完结状态…）+ 结果分页。
@MainActor
@Observable
public final class FilterViewModel {
    public private(set) var rows: [FilterRowInfo] = []
    public private(set) var panelState: LoadState = .idle
    /// 每行选中的值；不在字典里表示“全部”。
    public private(set) var selections: [String: String] = [:]
    public let results: Paginator<SeriesItem>

    private let catalog: CatalogRepository

    /// 完结状态行的 key（SDK 文档：creation_status）。
    public static let statusKey = "creation_status"

    public init(catalog: CatalogRepository) {
        self.catalog = catalog
        let c = catalog
        self.results = Paginator { cursor in try await c.filter(selections: [:], cursor: cursor) }
    }

    public func load() async {
        if panelState != .loaded {
            panelState = .loading
            do {
                rows = try await catalog.filterPanel()
                panelState = rows.isEmpty ? .empty : .loaded
            } catch {
                if let e = AppError.from(error) { panelState = .failed(e) }
            }
        }
        await results.loadIfNeeded()
    }

    public func isSelected(_ row: FilterRowInfo, _ choice: FilterChoice?) -> Bool {
        guard let choice else { return selections[row.key] == nil }
        return selections[row.key] == choice.value
    }

    /// 选择某行的某个值；choice 为 nil 表示“全部”。
    public func select(_ row: FilterRowInfo, _ choice: FilterChoice?) async {
        if let choice, !choice.value.isEmpty { selections[row.key] = choice.value } else { selections[row.key] = nil }
        let query = selections.mapValues { [$0] }
        let catalog = self.catalog
        results.reset { cursor in try await catalog.filter(selections: query, cursor: cursor) }
        await results.refresh()
    }

    public var selectionSummary: String {
        rows.compactMap { row in
            selections[row.key].flatMap { v in row.choices.first { $0.value == v }?.name }
        }.joined(separator: " · ")
    }
}
