# 黑果短剧（HongguoPlayer）

用 SwiftUI 写的红果短剧 iOS 个人客户端，接口层使用开源的非官方 SDK [openhongguo](https://github.com/beilunyang/openhongguo)。

## 个人自用声明

- 这是个人学习项目，**只在我自己的设备上运行**，不上架 App Store、不分发、不做任何商业用途。
- 工程里没有任何分发或上架相关的配置，只有 Xcode 自动签名（免费 Apple ID 的 Personal Team，安装包 7 天过期）。
- 通过本 App 看到的短剧、图片、文字等内容，版权归原权利人所有。
- 本 App **只播放 SDK 返回的未加密流地址**，不解密加密分集，加密分集只显示占位提示。

## SDK 来源与许可

| 项目 | 说明 |
|---|---|
| SDK | [beilunyang/openhongguo](https://github.com/beilunyang/openhongguo) v0.1.1，Apache License 2.0 |
| 位置 | `Vendor/Openhongguo/`，许可全文在 `Vendor/Openhongguo/LICENSE`，来源和改动说明在 `Vendor/Openhongguo/NOTICE.md` |
| 为什么是本地副本 | 上游 `Package.swift` 引用的 Release 产物 `OpenhongguoCore.xcframework.zip` 不存在（404），v0.1.1 的 Release 里也没有发布这个文件。所以用 `scripts/build-sdk.sh` 从 v0.1.1 源码编译 xcframework，Swift 封装层（`Client.swift`、`Types.swift`）原样拷贝、未作修改 |
| 以后换回远程包 | 上游补发产物后，把 `Packages/HongguoKit/Package.swift` 的依赖改回 `.package(url: "https://github.com/beilunyang/openhongguo.git", from: "0.1.1")`，删除 `Vendor/` 即可 |

gomobile 生成的代码来自 Go 项目，使用 BSD 许可证。

## 构建

需要 Xcode 16.2 或更新版本，iOS 17 以上。

```sh
# 1. 如果 Vendor/Openhongguo/OpenhongguoCore.xcframework 不存在，先编译 SDK
#    （需要 Go 1.26+ 和 gomobile：go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init）
./scripts/build-sdk.sh

# 2. 打开工程，选择自己的 Team，Run
open HongguoPlayer.xcodeproj
```

命令行构建模拟器版本：

```sh
xcodebuild -project HongguoPlayer.xcodeproj -scheme HongguoPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

单元测试（业务层都在 `HongguoKit` 里，直接在 macOS 上跑，不需要模拟器）：

```sh
cd Packages/HongguoKit && swift test
```

如果 `xcode-select` 指向的是 Command Line Tools，在命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

真机：在 Xcode → Settings → Accounts 登录 Apple ID，在 target 的 Signing 里选 Personal Team，连上手机直接 Run。Bundle ID 默认是 `personal.$(USER).HongguoPlayer`，冲突时自己改一下。

## 图标

App 图标由 `scripts/make_icon.swift` 用 CoreGraphics 绘制，没有用第三方素材。修改后重新生成：

```sh
swift scripts/make_icon.swift HongguoPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

## 架构

```
Views (App target, SwiftUI)
  └─ ViewModels (@Observable, @MainActor)        HongguoKit/ViewModels
       ├─ Repositories (actor，缓存 / 去重 / 重试)   HongguoKit/Repositories
       │    └─ HongguoService 协议                  HongguoKit/Services
       │         ├─ LiveHongguoService（唯一 import Openhongguo 的文件）
       │         └─ MockHongguoService（测试 / 预览）
       └─ LibraryStore（SwiftData：历史、收藏、追更、加密标记）  HongguoKit/Persistence
```

- **业务层放进本地 Swift 包 `HongguoKit`**：不依赖 UIKit 和 AVKit，`swift test` 在 macOS 上几秒就能跑完；App target 里只有视图。
- **SDK 只出现在 `LiveHongguoService.swift` 一个文件里**：SDK 的类型在这里映射成领域模型，`OpenhongguoError` 也在这里映射成 `AppError`。SDK 改版时只改这一处。
- **SDK 自带的重试关掉了（`retryAttempts: 1`）**：限流退避和设备重置统一由 `PlaybackRepository` 控制，避免两层重试叠加。

## 播放额度与错误处理

服务端从 2026-10-29 起基本只给每台匿名设备返回一次播放模型。所以：

| 规则 | 实现 |
|---|---|
| 只在真正要播放时请求播放模型 | `PlaybackRepository` 没有预取接口；推荐流要停留 0.6 秒才请求；自动连播在当前集播完后才请求下一集 |
| 预取只限元数据 | `CatalogRepository.prefetchMetadata` 只拉详情和分集 |
| 串行、同一集合并、结果缓存 | `AsyncGate` 串行；`TaskCoalescer` 合并同一集的并发请求；加密分集的结果永久缓存，未加密的缓存到流地址过期前 30 秒 |
| 取消 | 排队中的请求页面一离开就取消，不发网络请求；已经发出的请求让它跑完并缓存结果（额度已经消耗了） |
| `ANONYMOUS_LIMITED`（只在播放接口上） | `resetDevice()` 后重试，最多 2 次；仍失败就提示“播放次数已用完” |
| `ANONYMOUS_LIMITED`（列表接口） | 当作空结果 |
| `RATE_LIMITED` | 建议等待 ≤ 10 秒时退避重试（最多 2 次）；超过 10 秒立即提示，并进入冷却期，冷却期内不发请求 |
| `DEVICE_REJECTED` | 重置设备后重试 1 次 |
| `TRANSPORT` | 不自动重试，界面给“重试”按钮 |
| `CONTENT_UNAVAILABLE` | 提示“内容已下架或无权访问” |
| 所有错误 | `AppError.userMessage` 是中文提示；`code` 保留原始错误码，Debug 构建会显示在界面上 |
| 加密分集 | 播放时识别，存进 SwiftData；网格里显示锁标记，以后不再请求。同一部剧的其他集默认不自动请求，要点“仍要尝试”；推荐流连续 3 部加密后暂停自动播放 |

设备档案存在 `Application Support/openhongguo/anonymous.json`，目录标记为不参与备份（SDK 默认行为，`LiveHongguoService` 自定义路径时也会这样标记）。日志统一经过 `Redactor`，URL 的查询参数值全部替换成 `***`，不输出带设备 ID 的完整 URL。

## 已知限制

- **几乎所有内容都是加密的。** 2026-10-31 实测抽查了 11 部剧（推荐流、热搜、漫剧榜、AI 剧榜、系列剧榜、电影、上新），第 1 集**全部**是 `cenc-aes-ctr` 加密流。本 App 按约定不解密，所以目前基本找不到能播放的分集。未加密流的播放、断点续播、自动连播逻辑有单元测试覆盖，但**没能用真实的未加密内容做端到端验证**。
- **探测是否加密要消耗一次播放额度**：分集列表里没有“是否加密”字段，只有请求过播放模型才知道。
- **分享链接解析是启发式的**：SDK 没有这个功能。优先取 URL 里的 `series_id` / `book_id` 等参数，其次取 15～20 位的数字串；格式变了可能识别不出来。
- **封面地址有签名过期时间**：历史、收藏里存的封面过期后会显示占位图，进入详情页会刷新。
- **追更提醒只在 App 内**：打开 App 或回到前台时（最多每 10 分钟一次）对比集数，不做后台推送。
- **真机部署受 Xcode 版本限制**：Xcode 16.2 不支持 iOS 27 / iPhone 18,x 这一代设备（没有对应的 Developer Disk Image），需要用更新的 Xcode 构建安装。
- **服务端接口随时可能改版**：SDK 对缺失字段一律取零值；`LiveHongguoService` 会过滤掉 ID 为空的条目，解析失败会显示“数据格式异常”，不会崩溃。

## Debug 启动参数

只在 Debug 构建生效，用来在模拟器里跑验收流程（见 `HongguoPlayer/App/DebugLaunch.swift`）：

| 参数 | 作用 |
|---|---|
| `-debugTab find\|rank\|mine` | 启动后切到指定 Tab |
| `-debugSearch 关键词` | 自动搜索 |
| `-debugOpen ID或链接` | 直接打开详情页 |
| `-debugPlay` | 详情加载完后自动播放 |
| `-debugExitAfter 秒数` | 播放若干秒后退出播放页 |
| `-debugLandscape` | 配合 `-debugExitAfter`，进入播放页后切到横屏全屏 |
| `-debugMock` | 用 Mock 服务代替真实接口，播放 Apple 公开的 HLS 示例流，用来验证播放控件、横屏和断点续播，不消耗播放额度（观看记录会写进模拟器里的本机数据库） |

## 播放页操作

| 操作 | 效果 |
|---|---|
| 上滑 / 下滑 | 下一集 / 上一集 |
| 单击画面 | 播放 / 暂停（横屏时是显示 / 隐藏控件，3 秒后自动隐藏） |
| 双击画面 | 播放 / 暂停 |
| 拖动进度条 | 松手后精确跳转，并立即保存进度 |
| 倍速 | 0.75× / 1× / 1.25× / 1.5× / 2×，变速不变调；切集后保持，下次启动仍记得 |
| 右上角全屏按钮 | 横屏铺满；再点一次、点左上角返回，或把手机转回竖着拿都会退出。其他页面始终保持竖屏 |
