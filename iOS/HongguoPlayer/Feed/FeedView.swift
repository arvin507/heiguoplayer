import SwiftUI
import HongguoKit

/// 推荐：竖屏沉浸式，一屏一部剧，上下滑切换；停留片刻才开始播放（节约播放额度）。
struct FeedView: View {
    /// 当前 Tab 是否是推荐（切走时暂停）。
    let isActive: Bool
    @Environment(\.appEnv) private var env
    @State private var vm: FeedViewModel?
    @State private var scrolledId: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let vm { content(vm) } else { Color.black }
            }
            .background(.black)
            .toolbar(.hidden, for: .navigationBar)
            .seriesDestinations()
        }
        // 单个 task：先建 ViewModel 再加载。不要用 onAppear + task(id:)，那样任务会被重启一次，
        // 第一次加载被取消、第二次又以为“正在加载”而跳过。
        .task {
            let vm = self.vm ?? FeedViewModel(env: env)
            self.vm = vm
            await vm.load()
            if scrolledId == nil { scrolledId = vm.initialId }
        }
        .onChange(of: scrolledId) { _, id in if isActive, path.isEmpty { vm?.focus(id) } }
        .onChange(of: isActive) { _, a in a && path.isEmpty ? vm?.resume() : vm?.pause() }
        .onChange(of: vm?.player?.state) { _, s in
            switch s {
            case .keyUnavailable?: vm?.noteResult(keyMissing: true)
            case .ready?: vm?.noteResult(keyMissing: false)
            default: break
            }
        }
        .onChange(of: path.isEmpty) { _, empty in
            guard isActive else { return }
            empty ? vm?.resume() : vm?.pause()
        }
    }

    @ViewBuilder private func content(_ vm: FeedViewModel) -> some View {
        switch vm.feed.state {
        case .idle, .loading:
            LoadingStateView().environment(\.colorScheme, .dark)
        case .empty:
            EmptyStateView(title: "暂无推荐", systemImage: "film").environment(\.colorScheme, .dark)
        case .failed(let e):
            ErrorStateView(error: e) { Task { await vm.feed.refresh(); scrolledId = vm.initialId } }
                .environment(\.colorScheme, .dark)
        case .loaded:
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(vm.feed.items) { item in
                        FeedPage(item: item, vm: vm, isCurrent: isActive && item.id == vm.focusedId) {
                            path.append(SeriesRoute(id: item.id, preview: item))
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(item.id)
                    }
                    if vm.feed.isLoadingMore || vm.feed.loadMoreError != nil {
                        PaginatorFooter(paginator: vm.feed)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .environment(\.colorScheme, .dark)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledId)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .refreshable {
                await vm.feed.refresh()
                scrolledId = vm.feed.items.first?.id
            }
        }
    }
}

private struct FeedPage: View {
    let item: SeriesItem
    let vm: FeedViewModel
    let isCurrent: Bool
    var openDetail: () -> Void

    var body: some View {
        ZStack {
            if isCurrent, let player = vm.player, player.seriesId == item.id {
                PlayerSurface(vm: player, active: true, episodeSwipe: false, bottomInset: 64)
                    .id(player.seriesId)
            } else {
                cover
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: openDetail) {
                VStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle").font(.title2)
                    Text("详情").font(.caption2)
                }
                .foregroundStyle(.white).padding(16).shadow(radius: 3)
            }
            .padding(.bottom, 150)
        }
        .clipped()
    }

    private var cover: some View {
        ZStack {
            Color.black
            CoverImage(url: item.coverURL, cornerRadius: 0)
                .blur(radius: 24).opacity(0.5)
            CoverImage(url: item.coverURL, cornerRadius: 12)
                .aspectRatio(3 / 4, contentMode: .fit)
                .padding(48)
            VStack(spacing: 10) {
                Spacer()
                if isCurrent {
                    if let e = vm.prepareError {
                        Text(e.userMessage).font(.footnote).foregroundStyle(.white)
                        if e.isRetryable { Button("重试") { vm.retry() }.buttonStyle(.borderedProminent) }
                    } else if vm.preparingId == item.id {
                        ProgressView().tint(.white)
                    } else if vm.autoplayPaused {
                        Text("连续几部都没拿到内容密钥，已暂停自动播放")
                            .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 32)
                        HStack {
                            Button("播放这一部") { vm.playFocused() }.buttonStyle(.borderedProminent)
                            Button("恢复自动播放") { vm.resumeAutoplay() }.buttonStyle(.bordered).tint(.white)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.headline)
                    if !item.summary.isEmpty { Text(item.summary).font(.footnote).lineLimit(2).opacity(0.8) }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 88)
            }
        }
    }
}
