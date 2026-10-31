import SwiftUI
import SwiftData
import HongguoKit

@main
struct HongguoPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    private let env: AppEnvironment
    @State private var followChecker: FollowUpdateChecker

    init() {
        // 本机存储失败时退回内存存储，保证 App 能打开（数据不持久，界面会照常工作）。
        let container = (try? LibrarySchema.makeContainer()) ?? (try! LibrarySchema.makeContainer(inMemory: true))
        let env = DebugLaunch.flag("debugMock") ? DebugLaunch.mockEnvironment(container: container)
                                                 : AppEnvironment.live(container: container)
        self.container = container
        self.env = env
        _followChecker = State(initialValue: FollowUpdateChecker(env: env))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appEnv, env)
                .environment(followChecker)
        }
        .modelContainer(container)
    }
}

private struct AppEnvKey: EnvironmentKey {
    static let defaultValue: AppEnvironment? = nil
}

extension EnvironmentValues {
    /// 依赖容器。根视图一定会注入；预览里用 mock。
    var appEnv: AppEnvironment {
        get { self[AppEnvKey.self] ?? MainActor.assumeIsolated { AppEnvironment.mock() } }
        set { self[AppEnvKey.self] = newValue }
    }
}
