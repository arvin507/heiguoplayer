import Foundation

/// 按 key 合并并发的相同请求：同一个 key 同时只跑一个任务，后来者等待同一个结果。
///
/// 取消规则：
/// - 某个等待者被取消时，它自己立即抛出 CancellationError，不必等任务结束；
/// - 所有等待者都离开、且任务还没有 commit 时，取消底层任务（例如还在排队的播放请求）；
/// - 任务调用过 commit（表示请求已经发出、额度已经消耗）后，即使没人等也让它跑完，
///   结果由任务自己写入缓存，下次直接复用，不再重复请求。
public actor TaskCoalescer<Key: Hashable & Sendable, Value: Sendable> {
    public typealias Commit = @Sendable () async -> Void

    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Value, Error>
    }

    private struct Entry {
        let generation: Int
        var task: Task<Void, Never>?
        var waiters: [Waiter] = []
        var committed = false
    }

    private var entries: [Key: Entry] = [:]
    private var nextGeneration = 0

    public init() {}

    public func value(
        for key: Key,
        operation: @escaping @Sendable (_ commit: @escaping Commit) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let waiterID = UUID()
        let generation: Int
        if let existing = entries[key] {
            generation = existing.generation
        } else {
            nextGeneration += 1
            generation = nextGeneration
            var entry = Entry(generation: generation)
            entry.task = Task {
                let result: Result<Value, Error>
                do {
                    result = .success(try await operation({ await self.commit(key, generation) }))
                } catch {
                    result = .failure(error)
                }
                self.finish(key, generation, result)
            }
            entries[key] = entry
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Value, Error>) in
                // 与创建任务处在同一段同步代码里，任务不可能先于这里 finish。
                entries[key]?.waiters.append(Waiter(id: waiterID, cont: cont))
            }
        } onCancel: {
            Task { await self.abandon(key, generation, waiterID) }
        }
    }

    /// 正在进行的 key 数量（测试用）。
    public var inFlightCount: Int { entries.count }

    private func commit(_ key: Key, _ generation: Int) {
        guard entries[key]?.generation == generation else { return }
        entries[key]?.committed = true
    }

    private func abandon(_ key: Key, _ generation: Int, _ waiterID: UUID) {
        guard var entry = entries[key], entry.generation == generation,
              let i = entry.waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = entry.waiters.remove(at: i)
        waiter.cont.resume(throwing: CancellationError())
        if entry.waiters.isEmpty && !entry.committed {
            entry.task?.cancel()
            entries[key] = nil // 后来者重新发起，不要挂到已取消的任务上
        } else {
            entries[key] = entry
        }
    }

    private func finish(_ key: Key, _ generation: Int, _ result: Result<Value, Error>) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entries[key] = nil
        for w in entry.waiters { w.cont.resume(with: result) }
    }
}
