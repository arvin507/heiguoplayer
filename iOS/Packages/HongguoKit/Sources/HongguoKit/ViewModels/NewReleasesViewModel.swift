import Foundation

/// 上新日历：前后各一周的日期条 + 当天的作品。
@MainActor
@Observable
public final class NewReleasesViewModel {
    public private(set) var dates: [String] = []
    public private(set) var selectedDate: String?
    public let results: Paginator<NewReleaseItem>

    private let catalog: CatalogRepository

    public init(catalog: CatalogRepository) {
        self.catalog = catalog
        self.results = Paginator { _ in .empty }
        configure()
    }

    private func configure() {
        let catalog = self.catalog
        let date = selectedDate
        results.reset { [weak self] cursor in
            let day = try await catalog.newReleases(date: date, cursor: cursor)
            if cursor == nil { await self?.apply(day) }
            return day.page
        }
    }

    private func apply(_ day: NewReleaseDayInfo) {
        if !day.dates.isEmpty { dates = day.dates }
        if selectedDate == nil, !day.date.isEmpty { selectedDate = day.date }
    }

    public func load() async { await results.loadIfNeeded() }

    public func select(_ date: String) async {
        guard date != selectedDate else { return }
        selectedDate = date
        configure()
        await results.refresh()
    }

    /// "20261031" → "10/31 周五"；今天显示“今天”。
    public static func label(_ yyyymmdd: String, today: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd"
        guard let d = f.date(from: yyyymmdd) else { return yyyymmdd }
        if Calendar.current.isDate(d, inSameDayAs: today) { return "今天" }
        f.dateFormat = "M/d EEE"
        return f.string(from: d)
    }
}
