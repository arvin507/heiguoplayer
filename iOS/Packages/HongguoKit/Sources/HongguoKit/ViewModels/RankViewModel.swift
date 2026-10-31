import Foundation

/// 榜单：内容（全部、真人剧、漫剧…）× 榜（热播榜、新剧榜…），一页一页加载。
@MainActor
@Observable
public final class RankViewModel {
    public private(set) var contents: [RankContentInfo] = []
    public private(set) var content: String?
    public private(set) var board: String?
    public let results: Paginator<SeriesItem>

    private let catalog: CatalogRepository

    public init(catalog: CatalogRepository) {
        self.catalog = catalog
        self.results = Paginator { _ in .empty }
        configure()
    }

    public var boards: [RankBoardInfo] { contents.first { $0.id == content }?.boards ?? [] }

    private func configure() {
        let catalog = self.catalog
        let content = self.content
        let board = self.board
        results.reset { [weak self] cursor in
            let page = try await catalog.rank(content: content, board: board, cursor: cursor)
            if cursor == nil {
                await self?.applyDirectory(page)
            }
            return page.page
        }
    }

    private func applyDirectory(_ page: RankPageInfo) {
        if !page.contents.isEmpty { contents = page.contents }
        if content == nil, !page.content.isEmpty { content = page.content }
        if board == nil, !page.board.isEmpty { board = page.board }
    }

    public func load() async { await results.loadIfNeeded() }

    public func selectContent(_ id: String) async {
        guard id != content else { return }
        content = id
        board = nil
        configure()
        await results.refresh()
    }

    public func selectBoard(_ id: String) async {
        guard id != board else { return }
        board = id
        configure()
        await results.refresh()
    }
}
