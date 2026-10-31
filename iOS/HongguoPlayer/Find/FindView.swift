import SwiftUI
import HongguoKit

/// 找剧：搜索（联想、热搜）+ 分类筛选（题材、完结状态…）+ 链接 / ID 直达。
struct FindView: View {
    @Environment(\.appEnv) private var env
    @State private var mode = Mode.search
    @State private var search: SearchViewModel?
    @State private var filter: FilterViewModel?
    @State private var showOpenLink = false
    @State private var path = NavigationPath()

    enum Mode: String, CaseIterable { case search = "搜索", filter = "分类筛选" }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let search, let filter {
                    switch mode {
                    case .search: SearchPane(vm: search)
                    case .filter: FilterPane(vm: filter)
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
            .navigationTitle("找剧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showOpenLink = true } label: { Image(systemName: "link") }
                        .accessibilityLabel("通过链接或 ID 打开")
                }
            }
            .sheet(isPresented: $showOpenLink) {
                OpenLinkSheet { id in path.append(SeriesRoute(id: id)) }
            }
            .seriesDestinations()
        }
        .onAppear {
            if search == nil {
                let vm = SearchViewModel(catalog: env.catalog)
                search = vm
                if let q = DebugLaunch.value("debugSearch") { Task { await vm.submit(q) } }
                if let link = DebugLaunch.value("debugOpen"), let id = SeriesLinkParser.parse(link) { path.append(SeriesRoute(id: id)) }
            }
            if filter == nil { filter = FilterViewModel(catalog: env.catalog) }
        }
    }
}

private struct SearchPane: View {
    @Bindable var vm: SearchViewModel

    var body: some View {
        List {
            if !vm.suggestions.isEmpty, vm.query != vm.submittedQuery {
                Section("联想") {
                    ForEach(vm.suggestions, id: \.self) { s in
                        Button {
                            Task { await vm.submit(s.keyword) }
                        } label: {
                            Label(s.text, systemImage: "magnifyingglass").foregroundStyle(.primary)
                        }
                    }
                }
            } else if let q = vm.submittedQuery {
                results(q)
            } else {
                hot
            }
        }
        .listStyle(.plain)
        .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .always), prompt: vm.cue ?? "搜索短剧")
        .onSubmit(of: .search) { Task { await vm.submit() } }
        .onChange(of: vm.query) { _, new in if new.isEmpty, vm.submittedQuery != nil { vm.clearSearch() } }
        .task { await vm.loadHot() }
        .onDisappear { vm.cancel() }
    }

    @ViewBuilder private func results(_ q: String) -> some View {
        switch vm.results.state {
        case .idle, .loading:
            LoadingStateView(text: "正在搜索「\(q)」…").listRowSeparator(.hidden)
        case .empty:
            EmptyStateView(title: "没有找到「\(q)」", systemImage: "magnifyingglass", message: "换个关键词试试").listRowSeparator(.hidden)
        case .failed(let e):
            ErrorStateView(error: e) { Task { await vm.submit(q) } }.listRowSeparator(.hidden)
        case .loaded:
            ForEach(vm.results.items) { item in
                NavigationLink(value: SeriesRoute(id: item.id, preview: item)) { SeriesRow(item: item) }
                    .onAppear { vm.results.onItemAppear(item) }
            }
            PaginatorFooter(paginator: vm.results).listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private var hot: some View {
        switch vm.hotState {
        case .idle, .loading:
            LoadingStateView().listRowSeparator(.hidden)
        case .failed(let e):
            ErrorStateView(error: e) { Task { await vm.loadHot() } }.listRowSeparator(.hidden)
        case .empty:
            EmptyStateView(title: "暂无热搜", systemImage: "flame").listRowSeparator(.hidden)
        case .loaded:
            if !vm.hot.guesses.isEmpty {
                Section("猜你想搜") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.hot.guesses) { g in
                                NavigationLink(value: SeriesRoute(id: g.id, preview: g)) {
                                    Text(g.title).font(.subheadline).lineLimit(1)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            ForEach(vm.hot.boards) { board in
                Section(board.name) {
                    ForEach(Array(board.items.prefix(10).enumerated()), id: \.element.id) { i, item in
                        NavigationLink(value: SeriesRoute(id: item.id, preview: item)) {
                            HStack {
                                Text("\(i + 1)").font(.headline.monospacedDigit())
                                    .foregroundStyle(i < 3 ? Color.red : Color.secondary).frame(width: 28)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                if let b = item.badge { Text(b).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    ForEach(board.topics.prefix(10), id: \.self) { t in
                        Button(t.text) { Task { await vm.submit(t.keyword) } }.foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

private struct FilterPane: View {
    let vm: FilterViewModel

    var body: some View {
        ScrollView {
            switch vm.panelState {
            case .failed(let e):
                ErrorStateView(error: e) { Task { await vm.load() } }.frame(height: 160)
            case .loaded:
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.rows) { row in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Text(row.name).font(.caption).foregroundStyle(.secondary).frame(minWidth: 36, alignment: .leading)
                                chip("全部", selected: vm.isSelected(row, nil)) { Task { await vm.select(row, nil) } }
                                ForEach(row.choices.filter { !$0.value.isEmpty }) { c in
                                    chip(c.name, selected: vm.isSelected(row, c)) { Task { await vm.select(row, c) } }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical, 8)
            default:
                EmptyView()
            }
            Divider()
            switch vm.results.state {
            case .idle, .loading: LoadingStateView().frame(height: 240)
            case .empty: EmptyStateView(title: "没有符合条件的短剧", systemImage: "line.3.horizontal.decrease.circle").frame(height: 240)
            case .failed(let e): ErrorStateView(error: e) { Task { await vm.results.refresh() } }.frame(height: 240)
            case .loaded: SeriesGrid(paginator: vm.results).padding(.top, 8)
            }
        }
        .refreshable { await vm.results.refresh() }
        .task { await vm.load() }
        .onDisappear { vm.results.cancel() }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// 粘贴分享链接或输入数字 ID，直接进入详情。
struct OpenLinkSheet: View {
    var onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("分享链接或短剧 ID", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("从剪贴板粘贴") { text = UIPasteboard.general.string ?? "" }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) } else { Text("支持纯数字 ID，或包含 ID 的分享链接 / 分享文案。") }
                }
            }
            .navigationTitle("打开短剧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开") {
                        if let id = SeriesLinkParser.parse(text) {
                            dismiss()
                            onOpen(id)
                        } else {
                            error = AppError(.invalidLink).userMessage
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
