import Foundation

/// 每个页面都有的四种状态：加载中、有内容、空、出错。
public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(AppError)

    public var error: AppError? { if case .failed(let e) = self { e } else { nil } }
    public var isLoading: Bool { self == .loading }
}
