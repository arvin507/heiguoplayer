import Foundation
import SwiftData

/// 每集一条观看记录：剧 ID、集号、进度秒数、更新时间。
/// 剧名和封面冗余存一份，历史页不用联网也能显示。
@Model
public final class WatchRecord {
    /// "\(seriesId)#\(episodeNumber)"
    @Attribute(.unique) public var key: String
    public var seriesId: String
    public var episodeId: String
    public var episodeNumber: Int
    public var progressSeconds: Double
    public var durationSeconds: Double
    public var updatedAt: Date
    public var seriesTitle: String
    public var coverURLString: String?

    public init(seriesId: String, episodeId: String, episodeNumber: Int, progressSeconds: Double, durationSeconds: Double,
                seriesTitle: String, coverURL: URL?, updatedAt: Date = .now) {
        self.key = WatchRecord.key(seriesId, episodeNumber)
        self.seriesId = seriesId
        self.episodeId = episodeId
        self.episodeNumber = episodeNumber
        self.progressSeconds = progressSeconds
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
        self.seriesTitle = seriesTitle
        self.coverURLString = coverURL?.absoluteString
    }

    public static func key(_ seriesId: String, _ number: Int) -> String { "\(seriesId)#\(number)" }

    /// 看到末尾 10 秒以内（或 95%）算看完。
    public var isFinished: Bool {
        durationSeconds > 0 && (progressSeconds >= durationSeconds - 10 || progressSeconds / durationSeconds >= 0.95)
    }

    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}

@Model
public final class Favorite {
    @Attribute(.unique) public var seriesId: String
    public var title: String
    public var coverURLString: String?
    public var episodeCount: Int
    public var createdAt: Date

    public init(seriesId: String, title: String, coverURL: URL?, episodeCount: Int, createdAt: Date = .now) {
        self.seriesId = seriesId
        self.title = title
        self.coverURLString = coverURL?.absoluteString
        self.episodeCount = episodeCount
        self.createdAt = createdAt
    }

    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}

/// 追更：knownEpisodeCount 是用户上次看到的最新集数，latestEpisodeCount 是最近一次检查得到的集数。
@Model
public final class FollowedSeries {
    @Attribute(.unique) public var seriesId: String
    public var title: String
    public var coverURLString: String?
    public var knownEpisodeCount: Int
    public var latestEpisodeCount: Int
    public var isFinished: Bool
    public var followedAt: Date
    public var lastCheckedAt: Date?

    public init(seriesId: String, title: String, coverURL: URL?, episodeCount: Int, isFinished: Bool, followedAt: Date = .now) {
        self.seriesId = seriesId
        self.title = title
        self.coverURLString = coverURL?.absoluteString
        self.knownEpisodeCount = episodeCount
        self.latestEpisodeCount = episodeCount
        self.isFinished = isFinished
        self.followedAt = followedAt
    }

    public var hasUpdate: Bool { latestEpisodeCount > knownEpisodeCount }
    public var newEpisodeCount: Int { max(0, latestEpisodeCount - knownEpisodeCount) }
    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}

/// 已知是加密的分集。播放时才能知道是否加密（会消耗一次播放额度），所以记下来，
/// 以后分集网格直接标“加密”，点了也不再请求。
@Model
public final class EncryptedEpisode {
    @Attribute(.unique) public var episodeId: String
    public var seriesId: String
    public var detectedAt: Date

    public init(episodeId: String, seriesId: String, detectedAt: Date = .now) {
        self.episodeId = episodeId
        self.seriesId = seriesId
        self.detectedAt = detectedAt
    }
}

/// 推荐流的位置（只存一条）。
@Model
public final class FeedPosition {
    @Attribute(.unique) public var slot: String
    public var seriesId: String
    public var updatedAt: Date

    public init(seriesId: String, updatedAt: Date = .now) {
        self.slot = "feed"
        self.seriesId = seriesId
        self.updatedAt = updatedAt
    }
}

public enum LibrarySchema {
    public static let models: [any PersistentModel.Type] = [
        WatchRecord.self, Favorite.self, FollowedSeries.self, EncryptedEpisode.self, FeedPosition.self,
    ]

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        // 不开 CloudKit 同步：所有数据只存本机。
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: Schema(models), configurations: config)
    }
}
