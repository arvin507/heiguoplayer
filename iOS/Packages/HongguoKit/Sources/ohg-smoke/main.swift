import Foundation
import Openhongguo

// 冒烟工具。
//   ohg-smoke [关键词]   注册设备 → 搜索 → 列出分集（只调元数据接口，不消耗播放额度）
//   ohg-smoke --probe N  抽查推荐流前 N 部剧第 1 集是否加密（每部消耗一次播放额度，N 最多 5）
let profile = FileManager.default.temporaryDirectory.appendingPathComponent("ohg-smoke/anonymous.json")
try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
let client = try OpenhongguoClient.create(profile: profile, options: ClientOptions(retryAttempts: 1, logger: { print("[sdk]", $0) }))
let args = Array(CommandLine.arguments.dropFirst())

func probe(_ seriesId: String, _ title: String) async {
    guard let ep = try? await client.listEpisodes(seriesId).items.first else { print("  \(title)：无分集"); return }
    var result: PlaybackResult?
    for i in 0..<3 {
        do { result = try await client.resolvePlayback(ep.id); break } catch let e as OpenhongguoError where e.code == .anonymousLimited && i < 2 {
            try? await client.resetDevice()
        } catch let e as OpenhongguoError { print("  \(title)：\(e.code.rawValue)"); return } catch { return }
    }
    guard let pb = result?.playback else { return }
    let kinds = pb.streams.map { "\($0.definition)\($0.protected ? "🔒" : "")\($0.hls ? "hls" : "")\($0.dash ? "dash" : "")" }
    print("\(seriesId) \(title) 第1集 protected=\(pb.protected) streams=\(kinds)")
}

// --candidates：从不同来源各取一部（只调元数据接口）
if args.first == "--candidates" {
    for c in ["comic_series_rank", "ai_playlet", "series_album"] {
        if let r = try? await client.shortRank(ShortRankQuery(content: c)), let it = r.items.first(where: { !$0.seriesId.isEmpty }) {
            print("\(c)\t\(it.seriesId)\t\(it.title)")
        }
    }
    if let m = try? await client.search("电影"), let it = m.items.first { print("search:电影\t\(it.id)\t\(it.title)") }
    if let n = try? await client.newReleases(), let it = n.items.first(where: { $0.online }) { print("newRelease\t\(it.seriesId)\t\(it.title)") }
    exit(0)
}

// --probe-ids id...：抽查指定剧的第 1 集（每部消耗一次播放额度，最多 5 部）
if args.first == "--probe-ids" {
    for id in args.dropFirst().prefix(5) { await probe(id, id) }
    exit(0)
}

// --dump-ids id...：打印指定剧第 1 集的完整播放模型（含内容密钥）。
// 只用于诊断加密流，注意每部剧会消耗一次播放额度。
if args.first == "--dump-ids" {
    // 每次 resolvePlayback 消耗播放额度；服务端限流时重置设备再试。
    func resolve(_ episodeId: String) async -> PlaybackResult? {
        for i in 0..<3 {
            do { return try await client.resolvePlayback(episodeId) }
            catch let e as OpenhongguoError where e.code == .anonymousLimited && i < 2 {
                print("  （额度用尽，重置设备后重试）")
                try? await client.resetDevice()
            } catch let e as OpenhongguoError {
                print("  \(e.code.rawValue) \(e.message)"); return nil
            } catch { return nil }
        }
        return nil
    }
    for id in args.dropFirst().prefix(3) {
        guard let ep = try? await client.listEpisodes(id).items.first else { print("\(id)：无分集"); continue }
        guard let r = await resolve(ep.id) else { continue }
        print("== \(id) 第\(ep.number)集 ep=\(ep.id) ==")
        print("protected=\(r.playback.protected) duration=\(r.playback.durationSeconds) audio=\(r.playback.audioUrl)")
        for s in r.playback.streams {
            print("  [\(s.definition)/\(s.quality)] hls=\(s.hls) dash=\(s.dash) prot=\(s.protected) enc=\(s.encryption)")
            print("    url=\(s.url)")
            if !s.backupUrl.isEmpty { print("    backup=\(s.backupUrl)") }
        }
        if let k = r.contentKey { print("  contentKey=\(k.key) version=\(k.version)") }
        if let e = r.contentKeyError { print("  contentKeyError=\(e.code.rawValue) \(e.message)") }
    }
    exit(0)
}

if args.first == "--probe" {
    let n = min(5, Int(args.dropFirst().first ?? "3") ?? 3)
    let page = try await client.discover()
    for s in page.items.prefix(n) {
        guard let ep = try? await client.listEpisodes(s.id).items.first else { continue }
        var result: PlaybackResult?
        for i in 0..<3 {
            do { result = try await client.resolvePlayback(ep.id); break } catch let e as OpenhongguoError where e.code == .anonymousLimited && i < 2 {
                try await client.resetDevice()
            } catch let e as OpenhongguoError { print("  \(s.title)：\(e.code.rawValue)"); break }
        }
        guard let pb = result?.playback else { continue }
        let kinds = pb.streams.map { "\($0.definition)\($0.protected ? "🔒" : "")\($0.hls ? "hls" : "")\($0.dash ? "dash" : "")" }
        print("\(s.id) \(s.title) 第1集 protected=\(pb.protected) streams=\(kinds)")
    }
    exit(0)
}

let query = args.first ?? "全球死考"
let page = try await client.search(query)
print("搜索 \(query)：\(page.items.count) 条，hasMore=\(page.hasMore)")
for s in page.items.prefix(5) { print("  \(s.id) \(s.title) 共\(s.episodeCount)集") }
guard let first = page.items.first else { exit(0) }
let eps = try await client.listEpisodes(first.id)
print("《\(first.title)》分集：\(eps.items.count) 条，hasMore=\(eps.hasMore)")
for e in eps.items.prefix(5) { print("  第\(e.number)集 id=\(e.id) playable=\(e.playable)") }
print("设备档案存在：\(FileManager.default.fileExists(atPath: profile.path))")
