import SwiftUI
import HongguoKit

struct SeriesDetailView: View {
    let seriesId: String
    var preview: SeriesItem?
    @Environment(\.appEnv) private var env
    @State private var vm: SeriesDetailViewModel?
    @State private var playerRequest: PlayerRequest?

    struct PlayerRequest: Identifiable {
        let id = UUID()
        let index: Int
        let startAt: Double
    }

    var body: some View {
        Group {
            if let vm { content(vm) } else { LoadingStateView() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let vm = self.vm ?? SeriesDetailViewModel(seriesId: seriesId, env: env, preview: preview)
            self.vm = vm
            await vm.load()
            if DebugLaunch.flag("debugPlay"), let t = vm.resumeTarget, let i = vm.episodes.firstIndex(of: t.episode) {
                playerRequest = PlayerRequest(index: i, startAt: t.seconds)
            }
        }
        .fullScreenCover(item: $playerRequest, onDismiss: { vm?.refreshLocal() }) { req in
            if let vm, let s = vm.series {
                PlayerScreen(vm: PlayerViewModel(seriesId: s.id, seriesTitle: s.title, coverURL: s.coverURL,
                                                 episodes: vm.episodes, startIndex: req.index, startAt: req.startAt,
                                                 env: env, prefetchCount: 2))
            }
        }
    }

    @ViewBuilder private func content(_ vm: SeriesDetailViewModel) -> some View {
        if case .failed(let e) = vm.state, vm.series == nil || e.code == .contentUnavailable {
            ErrorStateView(error: e) { Task { await vm.load(force: true) } }
        } else if let s = vm.series {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(s, vm)
                    actions(s, vm)
                    if !s.summary.isEmpty {
                        Text(s.summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    episodesSection(vm)
                }
                .padding()
            }
            .refreshable { await vm.load(force: true) }
            .navigationTitle(s.title)
        } else {
            LoadingStateView()
        }
    }

    private func header(_ s: SeriesInfo, _ vm: SeriesDetailViewModel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: s.coverURL, cornerRadius: 10).frame(width: 120, height: 160)
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.title3.bold()).lineLimit(3)
                if !s.statusText.isEmpty {
                    Text(s.statusText).font(.footnote)
                        .foregroundStyle(s.status == .finished ? Color.secondary : Color.orange)
                }
                if !s.tags.isEmpty {
                    Text(s.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if vm.state.isLoading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
    }

    private func actions(_ s: SeriesInfo, _ vm: SeriesDetailViewModel) -> some View {
        HStack(spacing: 12) {
            Button {
                if let t = vm.resumeTarget, let i = vm.episodes.firstIndex(of: t.episode) {
                    playerRequest = PlayerRequest(index: i, startAt: t.seconds)
                }
            } label: {
                Label(vm.resumeLabel, systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.resumeTarget == nil)

            Button { vm.toggleFavorite() } label: {
                Image(systemName: vm.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
            .tint(vm.isFavorite ? .pink : nil)
            .accessibilityLabel(vm.isFavorite ? "取消收藏" : "收藏")

            Button { vm.toggleFollow() } label: {
                Label(vm.isFollowed ? "已追" : "追更", systemImage: vm.isFollowed ? "bell.fill" : "bell")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    @ViewBuilder private func episodesSection(_ vm: SeriesDetailViewModel) -> some View {
        HStack(spacing: 10) {
            Text("选集").font(.headline)
            Spacer()
            if !vm.episodes.isEmpty { Text("共 \(vm.episodes.count) 集").font(.caption).foregroundStyle(.secondary) }
        }
        switch vm.episodesState {
        case .idle, .loading: ProgressView().frame(maxWidth: .infinity).padding()
        case .empty: Text("暂无分集").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
        case .failed(let e): ErrorStateView(error: e) { Task { await vm.load(force: true) } }.frame(height: 200)
        case .loaded:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(vm.episodes.enumerated()), id: \.element.id) { i, ep in
                    EpisodeCell(number: ep.number, status: vm.status(of: ep)) {
                        playerRequest = PlayerRequest(index: i, startAt: -1)
                    }
                }
            }
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("看过", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("在看", systemImage: "circle.lefthalf.filled").foregroundStyle(Color.accentColor)
            Label("加密", systemImage: "lock.fill").foregroundStyle(.secondary)
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
    }
}

struct EpisodeCell: View {
    let number: Int
    let status: SeriesDetailViewModel.EpisodeStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) { progressBar }
                    .foregroundStyle(status == .unplayable ? .tertiary : .primary)
                badge.font(.system(size: 9)).padding(3)
            }
        }
        .buttonStyle(.plain)
        .disabled(status == .unplayable)
        .accessibilityLabel("第 \(number) 集")
    }

    private var background: some ShapeStyle {
        switch status {
        case .finished: AnyShapeStyle(Color.green.opacity(0.12))
        case .inProgress: AnyShapeStyle(Color.accentColor.opacity(0.15))
        case .encrypted: AnyShapeStyle(Color.secondary.opacity(0.12))
        default: AnyShapeStyle(.quaternary)
        }
    }

    @ViewBuilder private var progressBar: some View {
        if case .inProgress(let f) = status {
            GeometryReader { g in
                Capsule().fill(Color.accentColor).frame(width: g.size.width * f, height: 3)
            }
            .frame(height: 3)
            .padding(.horizontal, 6).padding(.bottom, 3)
        }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .encrypted: Image(systemName: "lock.fill").foregroundStyle(.secondary)
        case .unplayable: Image(systemName: "nosign").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}
