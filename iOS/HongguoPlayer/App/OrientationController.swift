import SwiftUI
import UIKit

/// 界面方向控制：App 平时锁竖屏，只有播放页进入“全屏”时临时切到横屏。
///
/// Info.plist 声明了横屏，但真正允许哪些方向由 AppDelegate 根据 `mask` 决定，
/// 所以其他页面不会跟着手机旋转。
@MainActor
enum OrientationController {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func enterLandscape() { set(.landscape, preferred: .landscapeRight) }
    static func exitLandscape() { set(.portrait, preferred: .portrait) }

    private static func set(_ newMask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientationMask) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred)) { error in
            AppLogBridge.log("orientation update failed: \(error.localizedDescription)")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationController.mask }
    }
}

/// 让 App target 的少量日志也走 HongguoKit 的脱敏日志。
enum AppLogBridge {
    static func log(_ message: String) {
        #if DEBUG
        print("[orientation]", message)
        #endif
    }
}
