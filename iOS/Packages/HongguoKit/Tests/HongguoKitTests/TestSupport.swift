import Foundation
@testable import HongguoKit

/// 不真正等待、只记录等待时长的 Sleeper。
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [TimeInterval] = []
    var waits: [TimeInterval] { lock.withLock { _waits } }
    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { _waits.append(seconds) }
        try Task.checkCancellation()
    }
}

/// 可手动拨动的时钟。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date()
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

extension AppError {
    static let limited = AppError(.anonymousLimited, debugMessage: "empty body")
    static func rate(_ s: TimeInterval?) -> AppError { AppError(.rateLimited, debugMessage: "429", retryAfter: s) }
}
