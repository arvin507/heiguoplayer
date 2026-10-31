import SwiftUI
import SwiftData
import HongguoKit

/// 路由：所有能进入详情页的地方都 push 这个值。
struct SeriesRoute: Hashable {
    let id: String
    var preview: SeriesItem?
}

enum RootTab: Hashable { case feed, find, rank, mine }

struct RootView: View {
    @Environment(\.appEnv) private var env
    @Environment(FollowUpdateChecker.self) private var followChecker
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = .feed
    /// 已经同意过的免责声明版本；0 表示还没同意。
    @AppStorage("disclaimerAcceptedVersion") private var acceptedVersion = 0
    @Query(filter: #Predicate<FollowedSeries> { $0.latestEpisodeCount > $0.knownEpisodeCount })
    private var updatedFollows: [FollowedSeries]

    var body: some View {
        TabView(selection: $tab) {
            FeedView(isActive: tab == .feed)
                .tabItem { Label("推荐", systemImage: "play.rectangle.on.rectangle") }
                .tag(RootTab.feed)
            FindView()
                .tabItem { Label("找剧", systemImage: "magnifyingglass") }
                .tag(RootTab.find)
            RankTabView()
                .tabItem { Label("榜单", systemImage: "chart.bar") }
                .tag(RootTab.rank)
            LibraryView()
                .tabItem { Label("我的", systemImage: "person") }
                .badge(updatedFollows.count)
                .tag(RootTab.mine)
        }
        .overlay(alignment: .top) {
            if let e = env.startupError {
                Text("初始化失败：\(e.userMessage)")
                    .font(.footnote).padding(8).background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
        }
        // 首次启动（或声明更新后）必须先阅读免责声明。Debug 验收参数启动时跳过。
        .fullScreenCover(isPresented: Binding(
            get: { acceptedVersion < Disclaimer.version && !DebugLaunch.isDebugRun },
            set: { _ in }
        )) {
            DisclaimerView(requireAccept: true) { acceptedVersion = Disclaimer.version }
        }
        .task { await followChecker.checkIfNeeded() }
        .onAppear {
            switch DebugLaunch.value("debugTab") {
            case "find": tab = .find
            case "rank": tab = .rank
            case "mine": tab = .mine
            default: if DebugLaunch.value("debugSearch") != nil || DebugLaunch.value("debugOpen") != nil { tab = .find }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await followChecker.checkIfNeeded() } }
        }
    }
}
