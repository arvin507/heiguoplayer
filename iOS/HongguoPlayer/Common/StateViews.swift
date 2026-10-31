import SwiftUI
import HongguoKit

/// 加载 / 空 / 错误三态的统一外观。
struct LoadingStateView: View {
    var text = "加载中…"
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

struct EmptyStateView: View {
    var title = "暂无内容"
    var systemImage = "tray"
    var message: String?
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let error: AppError
    var retry: (() -> Void)?
    var body: some View {
        ContentUnavailableView {
            Label("出错了", systemImage: icon)
        } description: {
            Text(error.userMessage)
            #if DEBUG
            Text(error.code.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            #endif
        } actions: {
            if error.isRetryable, let retry {
                Button("重试", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        switch error.code {
        case .transport: "wifi.exclamationmark"
        case .rateLimited, .playbackQuotaExhausted: "hourglass"
        case .contentUnavailable: "eye.slash"
        default: "exclamationmark.triangle"
        }
    }
}

/// 根据 LoadState 显示三态，loaded 时显示内容。
struct StateSwitch<Content: View>: View {
    let state: LoadState
    var emptyTitle = "暂无内容"
    var emptyImage = "tray"
    var emptyMessage: String?
    var retry: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch state {
        case .idle, .loading: LoadingStateView()
        case .empty: EmptyStateView(title: emptyTitle, systemImage: emptyImage, message: emptyMessage)
        case .failed(let e): ErrorStateView(error: e, retry: retry)
        case .loaded: content()
        }
    }
}

/// 列表底部：加载更多 / 加载失败重试 / 到底了。
struct PaginatorFooter<Item: Identifiable & Sendable>: View where Item.ID: Hashable & Sendable {
    let paginator: Paginator<Item>
    var body: some View {
        Group {
            if paginator.isLoadingMore {
                ProgressView()
            } else if let e = paginator.loadMoreError {
                Button {
                    paginator.retryLoadMore()
                } label: {
                    Label("\(e.userMessage)，点此重试", systemImage: "arrow.clockwise").font(.footnote)
                }
            } else if !paginator.hasMore, !paginator.items.isEmpty {
                Text("没有更多了").font(.footnote).foregroundStyle(.tertiary)
            } else if paginator.hasMore {
                Color.clear.frame(height: 1).onAppear { paginator.loadMore() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
