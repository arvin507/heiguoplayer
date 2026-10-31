// swift-tools-version:5.9
// openhongguo v0.1.1 的本地副本（Apache-2.0，https://github.com/beilunyang/openhongguo）。
//
// 上游 Package.swift 引用的 Release 产物 OpenhongguoCore.xcframework.zip 不存在（404），
// 所以这里用 scripts/build-sdk.sh 从 v0.1.1 源码编译 xcframework，并原样使用上游的
// Swift 封装（Sources/Openhongguo/Client.swift、Types.swift，未修改）。
// 上游补发产物后，把 HongguoKit 的依赖换回
//     .package(url: "https://github.com/beilunyang/openhongguo.git", from: "0.1.1")
// 并删除本目录即可。
import PackageDescription

let package = Package(
    name: "Openhongguo",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "Openhongguo", targets: ["Openhongguo"]),
    ],
    targets: [
        .binaryTarget(name: "OpenhongguoCore", path: "OpenhongguoCore.xcframework"),
        .target(name: "Openhongguo", dependencies: ["OpenhongguoCore"]),
    ]
)
