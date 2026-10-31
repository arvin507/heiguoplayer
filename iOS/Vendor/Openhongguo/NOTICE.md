# 第三方代码声明

本目录来自 [beilunyang/openhongguo](https://github.com/beilunyang/openhongguo) 的 tag `v0.1.1`
（commit `155fd783daefc3a1d3f3185ab68905fc83397905`），使用 Apache License 2.0，全文见同目录的 `LICENSE`。

| 文件 | 来源 | 是否修改 |
|---|---|---|
| `Sources/Openhongguo/Client.swift` | `bindings/mobile/ios/Sources/Openhongguo/Client.swift` | 未修改 |
| `Sources/Openhongguo/Types.swift` | `bindings/mobile/ios/Sources/Openhongguo/Types.swift` | 未修改 |
| `OpenhongguoCore.xcframework` | 由 `scripts/build-sdk.sh` 用 gomobile 从 `bindings/mobile/core` 编译 | 编译产物 |
| `Package.swift` | 改写：binaryTarget 改为本地路径 | 已修改 |

gomobile 生成的代码来自 Go 项目，使用 BSD 许可证。
