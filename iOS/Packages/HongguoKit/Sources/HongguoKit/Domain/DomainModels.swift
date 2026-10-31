import Foundation

// 业务层自己的领域模型。SDK 的类型只出现在 Services/LiveHongguoService.swift 里，
// SDK 改版时只需要改那一处映射。

public struct PageResult<Item: Sendable>: Sendable {
    public var items: [Item]
    public var cursor: String?
    public var hasMore: Bool

    public init(items: [Item], cursor: String?, hasMore: Bool) {
        self.items = items
        self.cursor = cursor
        self.hasMore = hasMore
    }

    public static var empty: PageResult { PageResult(items: [], cursor: nil, hasMore: false) }
}

public enum SeriesStatusKind: Sendable, Equatable {
    case ongoing, finished, unknown
}

/// 列表里的一部剧（搜索、筛选、榜单、上新都映射成它）。
public struct SeriesItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var coverURL: URL?
    public var episodeCount: Int
    /// 卡片右下角的辅助文字，例如热度或名次。
    public var badge: String?

    public init(id: String, title: String, summary: String = "", coverURL: URL? = nil, episodeCount: Int = 0, badge: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.coverURL = coverURL
        self.episodeCount = episodeCount
        self.badge = badge
    }
}

public struct SeriesInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var coverURL: URL?
    public var episodeCount: Int
    public var status: SeriesStatusKind
    public var statusText: String
    public var tags: [String]

    public init(id: String, title: String, summary: String = "", coverURL: URL? = nil, episodeCount: Int = 0,
                status: SeriesStatusKind = .unknown, statusText: String = "", tags: [String] = []) {
        self.id = id
        self.title = title
        self.summary = summary
        self.coverURL = coverURL
        self.episodeCount = episodeCount
        self.status = status
        self.statusText = statusText
        self.tags = tags
    }
}

public struct EpisodeItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var seriesId: String
    public var number: Int
    public var title: String
    /// 服务端禁止播放时为 false。
    public var playable: Bool
    public var coverURL: URL?

    public init(id: String, seriesId: String, number: Int, title: String = "", playable: Bool = true, coverURL: URL? = nil) {
        self.id = id
        self.seriesId = seriesId
        self.number = number
        self.title = title
        self.playable = playable
        self.coverURL = coverURL
    }
}

public struct StreamInfo: Hashable, Sendable {
    public var url: URL
    public var backupURL: URL?
    public var definition: String
    public var height: Int
    public var bitrate: Int
    public var hls: Bool
    public var dash: Bool
    /// 这条流是 CENC 加密的，AVPlayer 不能直接播，必须先解密。
    public var isProtected: Bool
    /// 服务端给的加密方案，例如 "cenc-aes-ctr"。
    public var encryption: String

    public init(url: URL, backupURL: URL? = nil, definition: String = "", height: Int = 0, bitrate: Int = 0,
                hls: Bool = false, dash: Bool = false, isProtected: Bool = false, encryption: String = "") {
        self.url = url
        self.backupURL = backupURL
        self.definition = definition
        self.height = height
        self.bitrate = bitrate
        self.hls = hls
        self.dash = dash
        self.isProtected = isProtected
        self.encryption = encryption
    }
}

/// 加密分集的内容密钥（CENC AES-128）。
public struct ContentKey: Hashable, Sendable {
    /// 16 字节 AES 密钥的小写十六进制串（32 个字符），与 SDK / ffmpeg 的表示一致。
    public var hex: String
    /// 服务端的方案标记，目前是 "1"。
    public var version: String

    public init(hex: String, version: String = "") {
        self.hex = hex
        self.version = version
    }

    /// 解析成 16 字节密钥；长度或字符不合法的返回 nil。
    public var keyData: Data? {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard h.count == 32 else { return nil }
        var out = Data(capacity: 16)
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let byte = UInt8(h[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}

public struct PlaybackInfo: Hashable, Sendable {
    public var episodeId: String
    /// 加密分集。加密流不能直接给 AVPlayer，要先按 contentKey 解密。
    public var isProtected: Bool
    /// 可播放的流，按清晰度从高到低。加密流的 url 指向 CENC 加密的 MP4。
    public var streams: [StreamInfo]
    public var durationSeconds: Int
    /// 流地址失效时间；nil 表示服务端没给。
    public var expiresAt: Date?
    /// 加密分集的内容密钥；未加密、或服务端推导失败时为 nil。
    public var contentKey: ContentKey?

    public init(episodeId: String, isProtected: Bool, streams: [StreamInfo], durationSeconds: Int = 0,
                expiresAt: Date? = nil, contentKey: ContentKey? = nil) {
        self.episodeId = episodeId
        self.isProtected = isProtected
        self.streams = streams
        self.durationSeconds = durationSeconds
        self.expiresAt = expiresAt
        self.contentKey = contentKey
    }

    /// 首选流：1080p 以下里最高的一档，兼顾流量和画质。
    public var preferredStream: StreamInfo? {
        streams.first(where: { $0.height > 0 && $0.height <= 1080 }) ?? streams.first
    }

    /// 能不能拿到可用的 16 字节密钥。
    public var usableKey: Data? { contentKey?.keyData }
}

public struct SearchSuggestion: Hashable, Sendable {
    public var text: String
    /// 点选后提交的关键词；直达行可能是内容 ID。
    public var keyword: String

    public init(text: String, keyword: String) {
        self.text = text
        self.keyword = keyword
    }
}

public struct HotBoardInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var items: [SeriesItem]
    /// 话题榜：显示文字 + 点击后搜索的词。
    public var topics: [SearchSuggestion]

    public init(name: String, items: [SeriesItem], topics: [SearchSuggestion]) {
        self.name = name
        self.items = items
        self.topics = topics
    }
}

public struct HotSearchInfo: Hashable, Sendable {
    public var guesses: [SeriesItem]
    public var boards: [HotBoardInfo]

    public init(guesses: [SeriesItem] = [], boards: [HotBoardInfo] = []) {
        self.guesses = guesses
        self.boards = boards
    }
}

public struct FilterChoice: Hashable, Sendable, Identifiable {
    public var id: String { value }
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// 筛选面板的一行，例如题材（category_dim_theme）、完结状态（creation_status）。
public struct FilterRowInfo: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var choices: [FilterChoice]
    public init(key: String, name: String, choices: [FilterChoice]) { self.key = key; self.name = name; self.choices = choices }
}

public struct RankBoardInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct RankContentInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var boards: [RankBoardInfo]
    public init(id: String, name: String, boards: [RankBoardInfo]) { self.id = id; self.name = name; self.boards = boards }
}

public struct RankPageInfo: Sendable {
    public var contents: [RankContentInfo]
    public var content: String
    public var board: String
    /// 只含短剧行（演员行没有 seriesId，已过滤）。badge 是名次 + 热度。
    public var page: PageResult<SeriesItem>
    public init(contents: [RankContentInfo], content: String, board: String, page: PageResult<SeriesItem>) {
        self.contents = contents; self.content = content; self.board = board; self.page = page
    }
}

public struct NewReleaseItem: Hashable, Sendable, Identifiable {
    public var id: String { series.id }
    public var series: SeriesItem
    public var online: Bool
    public var note: String
    public var categories: [String]
    public init(series: SeriesItem, online: Bool, note: String, categories: [String]) {
        self.series = series; self.online = online; self.note = note; self.categories = categories
    }
}

public struct NewReleaseDayInfo: Sendable {
    /// YYYYMMDD
    public var date: String
    public var dates: [String]
    public var page: PageResult<NewReleaseItem>
    public init(date: String, dates: [String], page: PageResult<NewReleaseItem>) { self.date = date; self.dates = dates; self.page = page }
}
