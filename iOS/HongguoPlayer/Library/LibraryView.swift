import SwiftUI
import SwiftData
import HongguoKit

/// 我的：观看历史、收藏、追更（全部存本机）。
struct LibraryView: View {
    @State private var mode = Mode.history
    enum Mode: String, CaseIterable { case history = "历史", favorites = "收藏", follows = "追更" }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .history: HistoryList()
                case .favorites: FavoriteList()
                case .follows: FollowList()
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("分类", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .seriesDestinations()
        }
    }
}

private struct HistoryList: View {
    @Environment(\.appEnv) private var env
    @Query(sort: \WatchRecord.updatedAt, order: .reverse) private var records: [WatchRecord]
    @State private var confirmClear = false

    /// 每部剧只显示最近的一条。
    private var latest: [WatchRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.seriesId).inserted }
    }

    var body: some View {
        let items = latest
        if items.isEmpty {
            EmptyStateView(title: "还没有观看记录", systemImage: "clock", message: "看过的剧会出现在这里")
        } else {
            List {
                ForEach(items) { r in
                    NavigationLink(value: SeriesRoute(id: r.seriesId, preview: SeriesItem(id: r.seriesId, title: r.seriesTitle, coverURL: r.coverURL))) {
                        HStack(spacing: 12) {
                            CoverImage(url: r.coverURL, cornerRadius: 6).frame(width: 60, height: 80)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.seriesTitle.isEmpty ? r.seriesId : r.seriesTitle).lineLimit(2)
                                Text(progressText(r)).font(.caption).foregroundStyle(.secondary)
                                Text(r.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .onDelete { idx in for i in idx { env.library.deleteHistory(seriesId: items[i].seriesId) } }
            }
            .listStyle(.plain)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { confirmClear = true }
                }
            }
            .confirmationDialog("清空全部观看记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { env.library.clearHistory() }
            }
        }
    }

    private func progressText(_ r: WatchRecord) -> String {
        if r.isFinished { return "看完第 \(r.episodeNumber) 集" }
        let m = Int(r.progressSeconds) / 60, s = Int(r.progressSeconds) % 60
        return String(format: "看到第 %d 集 %d:%02d", r.episodeNumber, m, s)
    }
}

private struct FavoriteList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.createdAt, order: .reverse) private var favorites: [Favorite]

    var body: some View {
        if favorites.isEmpty {
            EmptyStateView(title: "还没有收藏", systemImage: "heart", message: "在详情页点 ♡ 收藏")
        } else {
            List {
                ForEach(favorites) { f in
                    NavigationLink(value: SeriesRoute(id: f.seriesId, preview: SeriesItem(id: f.seriesId, title: f.title, coverURL: f.coverURL, episodeCount: f.episodeCount))) {
                        SeriesRow(item: SeriesItem(id: f.seriesId, title: f.title, coverURL: f.coverURL, episodeCount: f.episodeCount))
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(favorites[i]) }
                    try? context.save()
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct FollowList: View {
    @Environment(\.modelContext) private var context
    @Environment(FollowUpdateChecker.self) private var checker
    @Query(sort: \FollowedSeries.followedAt, order: .reverse) private var follows: [FollowedSeries]

    var body: some View {
        Group {
            if follows.isEmpty {
                EmptyStateView(title: "还没有追更", systemImage: "bell", message: "在详情页点“追更”，有新集时这里会提示")
            } else {
                List {
                    ForEach(follows.sorted { ($0.hasUpdate ? 1 : 0) > ($1.hasUpdate ? 1 : 0) }) { f in
                        NavigationLink(value: SeriesRoute(id: f.seriesId, preview: SeriesItem(id: f.seriesId, title: f.title, coverURL: f.coverURL, episodeCount: f.latestEpisodeCount))) {
                            HStack(spacing: 12) {
                                CoverImage(url: f.coverURL, cornerRadius: 6).frame(width: 60, height: 80)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.title).lineLimit(2)
                                    Text(f.isFinished ? "已完结 · 共 \(f.latestEpisodeCount) 集" : "连载中 · 已更新 \(f.latestEpisodeCount) 集")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if f.hasUpdate {
                                    Text("+\(f.newEpisodeCount) 新集").font(.caption.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3).background(.red, in: Capsule())
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        let sorted = follows.sorted { ($0.hasUpdate ? 1 : 0) > ($1.hasUpdate ? 1 : 0) }
                        for i in idx { context.delete(sorted[i]) }
                        try? context.save()
                    }
                }
                .listStyle(.plain)
                .refreshable { await checker.checkIfNeeded(force: true) }
            }
        }
        .overlay(alignment: .bottom) {
            if checker.isChecking {
                Label("正在检查更新…", systemImage: "arrow.triangle.2.circlepath").font(.caption)
                    .padding(8).background(.regularMaterial, in: Capsule()).padding()
            }
        }
    }
}
