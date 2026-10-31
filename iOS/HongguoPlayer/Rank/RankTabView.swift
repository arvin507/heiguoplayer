import SwiftUI
import HongguoKit

/// 榜单：排行榜 + 上新日历。
struct RankTabView: View {
    @Environment(\.appEnv) private var env
    @State private var mode = Mode.rank
    @State private var rank: RankViewModel?
    @State private var releases: NewReleasesViewModel?

    enum Mode: String, CaseIterable { case rank = "排行榜", calendar = "上新日历" }

    var body: some View {
        NavigationStack {
            Group {
                if let rank, let releases {
                    switch mode {
                    case .rank: RankPane(vm: rank)
                    case .calendar: CalendarPane(vm: releases)
                    }
                } else {
                    LoadingStateView()
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("榜单")
            .navigationBarTitleDisplayMode(.inline)
            .seriesDestinations()
        }
        .onAppear {
            if rank == nil { rank = RankViewModel(catalog: env.catalog) }
            if releases == nil { releases = NewReleasesViewModel(catalog: env.catalog) }
        }
    }
}

private struct RankPane: View {
    let vm: RankViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !vm.contents.isEmpty {
                tabs(vm.contents.map { ($0.id, $0.name) }, selected: vm.content) { id in Task { await vm.selectContent(id) } }
            }
            if !vm.boards.isEmpty {
                tabs(vm.boards.map { ($0.id, $0.name) }, selected: vm.board, small: true) { id in Task { await vm.selectBoard(id) } }
            }
            StateSwitch(state: vm.results.state, emptyTitle: "榜单暂无内容", emptyImage: "chart.bar",
                        retry: { Task { await vm.results.refresh() } }) {
                List {
                    ForEach(vm.results.items) { item in
                        NavigationLink(value: SeriesRoute(id: item.id, preview: item)) { SeriesRow(item: item) }
                            .onAppear { vm.results.onItemAppear(item) }
                    }
                    PaginatorFooter(paginator: vm.results).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { await vm.results.refresh() }
            }
        }
        .task { await vm.load() }
        .onDisappear { vm.results.cancel() }
    }

    private func tabs(_ items: [(String, String)], selected: String?, small: Bool = false, action: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: small ? 12 : 16) {
                ForEach(items, id: \.0) { id, name in
                    Button { action(id) } label: {
                        Text(name)
                            .font(small ? .footnote : .subheadline.weight(id == selected ? .semibold : .regular))
                            .foregroundStyle(id == selected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
    }
}

private struct CalendarPane: View {
    let vm: NewReleasesViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !vm.dates.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.dates, id: \.self) { d in
                                Button { Task { await vm.select(d) } } label: {
                                    Text(NewReleasesViewModel.label(d)).font(.footnote)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(d == vm.selectedDate ? Color.accentColor : Color.clear, in: Capsule())
                                        .foregroundStyle(d == vm.selectedDate ? Color.white : .primary)
                                }
                                .buttonStyle(.plain)
                                .id(d)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 8)
                    }
                    .onAppear { if let s = vm.selectedDate { proxy.scrollTo(s, anchor: .center) } }
                }
            }
            StateSwitch(state: vm.results.state, emptyTitle: "这天没有上新", emptyImage: "calendar",
                        retry: { Task { await vm.results.refresh() } }) {
                List {
                    ForEach(vm.results.items) { r in
                        NavigationLink(value: SeriesRoute(id: r.series.id, preview: r.series)) {
                            SeriesRow(item: r.series, accessory: r.online ? nil : (r.note.isEmpty ? "预告" : r.note))
                        }
                        .onAppear { vm.results.onItemAppear(r) }
                    }
                    PaginatorFooter(paginator: vm.results).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { await vm.results.refresh() }
            }
        }
        .task { await vm.load() }
        .onDisappear { vm.results.cancel() }
    }
}
