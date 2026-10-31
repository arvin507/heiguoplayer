// swift-tools-version:6.0
// HongguoKit：App 的业务层（Services → Repositories → ViewModels，以及 SwiftData 模型）。
// 不依赖 UIKit/AVKit，所以单元测试可以直接在 macOS 上用 `swift test` 跑。
import PackageDescription

let package = Package(
    name: "HongguoKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "HongguoKit", targets: ["HongguoKit"]),
    ],
    dependencies: [
        // 上游 Release 缺少 xcframework，暂用本地副本，见 Vendor/Openhongguo/NOTICE.md。
        .package(path: "../../Vendor/Openhongguo"),
    ],
    targets: [
        .target(
            name: "HongguoKit",
            dependencies: [.product(name: "Openhongguo", package: "Openhongguo")]
        ),
        // 阶段 0 的冒烟程序：注册设备 → 搜索 → 列出分集。只在 macOS 上手动运行。
        .executableTarget(name: "ohg-smoke", dependencies: [.product(name: "Openhongguo", package: "Openhongguo")]),
        // 诊断工具：把一个 CENC 加密的 mp4 解成明文，用来核对解密器。只在 macOS 上手动运行。
        .executableTarget(name: "cenc-probe", dependencies: ["HongguoKit"]),
        .testTarget(name: "HongguoKitTests", dependencies: ["HongguoKit"]),
    ],
    swiftLanguageModes: [.v5]
)
