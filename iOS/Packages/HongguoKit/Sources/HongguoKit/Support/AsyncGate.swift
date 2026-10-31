import Foundation

/// 异步互斥：同一时刻只放行一个持有者，其余按先来后到排队。排队中的等待者被取消时，
/// 直接抛出 CancellationError 并离开队列，不会占着位置。
public actor AsyncGate {
    private var busy = false
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    public init() {}

    public func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiters.append((id, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().cont.resume()
        }
    }

    /// 在队列里的数量（测试用）。
    public var queuedCount: Int { waiters.count }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: CancellationError())
    }
}
