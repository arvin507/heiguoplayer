import Foundation

/// 加密分集的本地准备器：下载 → 解密 → 落到缓存目录，返回可以交给 AVPlayer 的本地文件地址。
///
/// 为什么要落盘而不是自己起本地代理：AVPlayer 对 `file://` 的 mp4 支持最稳，
/// seek 也由系统直接做；代价是首次播放要等整集下载完。一集短剧通常 10~40MB，
/// 下载解密后按 `episodeId + 清晰度` 缓存，同一集再次播放不再走网络。
public actor ProtectedMediaStore {
    public enum Stage: Sendable, Equatable {
        case downloading(Double)
        case decrypting(Double)
        case ready(URL)
    }

    public enum Failure: LocalizedError {
        case http(Int)
        case emptyResponse
        case tooLarge(Int)
        case unsupported(String)
        case keyMissing

        public var errorDescription: String? {
            switch self {
            case .http(let code): "下载加密流失败（HTTP \(code)）"
            case .emptyResponse: "下载加密流失败：没有拿到文件"
            case .tooLarge(let bytes): "加密流体积异常（\(bytes) 字节），已放弃解密"
            case .unsupported(let s): "不支持的加密方案：\(s)"
            case .keyMissing: "缺少内容密钥"
            }
        }
    }

    /// 单个文件的大小上限，防止异常响应把内存打满。
    static let sizeLimit = 400 * 1024 * 1024

    public nonisolated let root: URL
    private let session: URLSession

    public init(root: URL? = nil, session: URLSession = .shared) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root ?? base.appendingPathComponent("hongguo-cenc", isDirectory: true)
        self.root = dir
        self.session = session
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
    }

    /// 解密后的文件位置（纯路径计算，不碰磁盘）。
    public nonisolated func fileURL(episodeId: String, height: Int) -> URL {
        let safe = episodeId.replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent("\(safe)-\(height).mp4")
    }

    public func isCached(episodeId: String, height: Int) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(episodeId: episodeId, height: height).path)
    }

    /// 准备一集加密内容。进度通过 AsyncThrowingStream 上报，最后一个事件是 `.ready`。
    /// 调用方取消所在 Task 时，下载与解密都会停下来。
    public func prepare(episodeId: String, stream: StreamInfo, key: Data) -> AsyncThrowingStream<Stage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try await self.produce(episodeId: episodeId, stream: stream, key: key) { stage in
                        continuation.yield(stage)
                    }
                    continuation.yield(.ready(url))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func produce(episodeId: String, stream: StreamInfo, key: Data,
                         emit: @escaping @Sendable (Stage) -> Void) async throws -> URL {
        guard key.count == 16 else { throw Failure.keyMissing }
        guard CENCDecryptor.supports(stream.encryption) else { throw Failure.unsupported(stream.encryption) }

        let dest = fileURL(episodeId: episodeId, height: stream.height)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        try Task.checkCancellation()
        let temp = try await download(stream.url, emit: emit)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()

        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        if size > Self.sizeLimit { throw Failure.tooLarge(size) }

        emit(.decrypting(0.02))
        let payload = try Data(contentsOf: temp, options: [.uncached])
        let outcome = try await Task.detached(priority: .userInitiated) { () throws -> CENCDecryptor.Outcome in
            try CENCDecryptor.decrypt(payload, key: key) { fraction in
                emit(.decrypting(min(0.98, 0.02 + fraction * 0.96)))
            }
        }.value
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try outcome.data.write(to: dest, options: [.atomic])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = dest
        try? file.setResourceValues(values)
        trimCache()

        AppLog.net("cenc decrypted episode=\(episodeId) samples=\(outcome.sampleCount) bytes=\(outcome.data.count)")
        return dest
    }

    /// 缓存上限（默认 1.5GB）。Caches 目录本来就可能被系统清理，这里再按最近使用时间兜一层。
    private func trimCache(limit: Int = 1_500 * 1024 * 1024) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append((file, values.contentModificationDate ?? .distantPast, size))
        }
        guard total > limit else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= limit { break }
        }
    }

    // MARK: - 下载

    private func download(_ url: URL, emit: @escaping @Sendable (Stage) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url) { temp, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.resume(throwing: Failure.http(http.statusCode))
                        return
                    }
                    guard let temp else {
                        continuation.resume(throwing: Failure.emptyResponse)
                        return
                    }
                    // 系统在回调返回后就会删掉临时文件，先挪到自己的临时名下。
                    let keep = FileManager.default.temporaryDirectory
                        .appendingPathComponent("hg-cenc-\(UUID().uuidString).mp4")
                    do {
                        try? FileManager.default.removeItem(at: keep)
                        try FileManager.default.moveItem(at: temp, to: keep)
                        continuation.resume(returning: keep)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.set(task)
                task.resume()

                Task {
                    while !Task.isCancelled, task.state == .running {
                        emit(.downloading(max(0, min(1, task.progress.fractionCompleted))))
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// 在取消先于任务创建时记住取消，避免漏掉。
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func set(_ task: URLSessionDownloadTask) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { self.task = task }
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = task
        lock.unlock()
        pending?.cancel()
    }
}
