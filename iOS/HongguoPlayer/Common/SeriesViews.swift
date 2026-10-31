import SwiftUI
import HongguoKit

/// 封面图：加载失败或签名过期时显示占位，不崩溃。
struct CoverImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        // 先占满分到的空间，再让图片在里面铺满并裁剪：scaledToFill 的图片不会把外层布局撑大。
        Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: placeholder(icon: "photo")
                    default: placeholder(icon: nil)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func placeholder(icon: String?) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
        }
    }
}

/// 两列网格卡片。
struct SeriesCard: View {
    let item: SeriesItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: item.coverURL)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if item.episodeCount > 0 {
                        Text("\(item.episodeCount)集")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2, reservesSpace: true)
            if let badge = item.badge {
                Text(badge).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// 列表行：封面 + 标题 + 简介。
struct SeriesRow: View {
    let item: SeriesItem
    var accessory: String?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: item.coverURL, cornerRadius: 6).frame(width: 72, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if item.episodeCount > 0 { Text("\(item.episodeCount)集") }
                    if let badge = item.badge { Text(badge) }
                    if let accessory { Text(accessory) }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// 带分页的两列网格。
struct SeriesGrid: View {
    let paginator: Paginator<SeriesItem>
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(paginator.items) { item in
                NavigationLink(value: SeriesRoute(id: item.id, preview: item)) {
                    SeriesCard(item: item)
                }
                .buttonStyle(.plain)
                .onAppear { paginator.onItemAppear(item) }
            }
        }
        .padding(.horizontal)
        PaginatorFooter(paginator: paginator)
    }
}

extension View {
    /// 每个 Tab 的 NavigationStack 都挂上详情页路由。
    func seriesDestinations() -> some View {
        navigationDestination(for: SeriesRoute.self) { route in
            SeriesDetailView(seriesId: route.id, preview: route.preview)
        }
    }
}
