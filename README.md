# 黑果短剧

红果短剧的个人客户端，iOS（SwiftUI）和 Android（Jetpack Compose）两个版本，结构一一对应。接口层使用开源的非官方 SDK [openhongguo](https://github.com/beilunyang/openhongguo)。

## 个人自用声明

- 这是**个人学习项目**，只在我自己的设备上运行，**不上架、不分发、不做任何商业用途**。仓库是私有的，不应公开。
- 两端都没有任何分发或上架相关的配置：iOS 用 Xcode 自动签名（免费 Apple ID，安装包 7 天过期），Android 的 release 变体也只用 debug 签名。
- 通过本 App 看到的短剧、图片、文字等内容，版权归原权利人所有。
- 加密分集由 App 在本地解密后播放：用 SDK 下发的 16 字节内容密钥，对 CENC（AES-128-CTR）加密的 MP4 逐样本解密，结果只写进本机缓存，不转码、不对外分发。

## 免责声明

1. 本项目是个人学习项目，仅用于学习和技术研究，**不得用于任何商业用途**。
2. 本项目不提供、不上传、不对外分发任何视频内容。内容均来自第三方服务，版权归原权利人所有；解密后的内容只缓存在使用者自己的设备上。
3. 本项目与红果短剧及其运营方没有任何关联，不代表其立场；相关名称和商标归其所有者所有。接口层使用的是开源的非官方 SDK，随时可能失效。
4. 请遵守所在地的法律法规和相关服务条款。因使用本项目产生的一切后果由使用者自行承担，作者不承担任何责任。

> **删除提醒**：本项目仅供学习交流，请在使用后 24 小时内删除本 App 及缓存的全部内容。如权利人认为内容侵权，请联系删除。

两端 App 在首次启动时会弹出这份声明，需点“我已阅读”才能进入；之后可以在“我的”页左上角（iOS）/ 顶部（Android）的“免责声明”里随时查看。文案在 iOS 的 `HongguoPlayer/App/Disclaimer.swift` 和 Android 的 `ui/Disclaimer.kt` 里，两处保持一致；改动文案时递增 `version`，已同意过旧版本的用户会再弹一次。

## 目录

| 目录 | 说明 |
|---|---|
| [`iOS/`](iOS/README.md) | SwiftUI，iOS 17+，`@Observable` + SwiftData + Swift Concurrency |
| [`android/`](android/README.md) | Jetpack Compose，Android 8.0（API 26）+，Room + 协程 + Media3 ExoPlayer |

构建方法、架构细节、已知限制都在各自目录的 README 里。

## 功能

两端一致：

- **推荐**：竖屏沉浸式信息流，上下滑动切换，停留后自动播放，记住上次位置。
- **找剧**：搜索（联想、热搜）、分类筛选（题材、完结状态等）、用分享链接或纯数字 ID 直接打开详情。
- **榜单**：各类榜单和上新日历。
- **我的**：观看历史、收藏、追更，全部只存本机；追更剧有新集时在 App 内打标记（不做后台推送）。
- **详情页**：封面、简介、选集网格（带观看状态）、收藏 / 追更。
- **播放页**：断点续播、自动连播、上下滑动切集、可拖动进度条、倍速（0.75–2×）、清晰度选择、横屏全屏、回到桌面时小窗（画中画）播放、播放中保持亮屏。

## 架构

两端都是 `Service → Repository → ViewModel → View` 四层：

- **Service**：`HongguoService` 接口，SDK 只出现在 `LiveHongguoService` 一个文件里，错误统一映射为带中文提示的 `AppError`（保留内部错误码用于调试）。
- **Repository**：`PlaybackRepository` 管播放模型的额度与限流（串行请求、按集缓存、`ANONYMOUS_LIMITED` 重置设备重试最多 2 次、`RATE_LIMITED` 退避、`DEVICE_REJECTED` 重试 1 次），`CatalogRepository` 管元数据缓存与分页去重。
- **ViewModel**：统一的 `Paginator`（去重、加载更多、取消）和 加载中 / 空 / 出错 三态。
- **本机数据**：iOS 用 SwiftData，Android 用 Room；观看记录、收藏、追更、加密标记、推荐流位置。
- 设备档案放在不参与备份的目录，网络日志里 URL 查询参数的值会被替换为 `***`。

### 播放额度

服务端基本只给每台匿名设备一次播放模型，所以两端都遵守：

- 播放模型**只在用户真正要播放时请求**，不预取；元数据（详情、分集列表）可以预取。
- 清晰度切换用已经拿到的播放模型，**不会再次请求**。
- 推荐流里快速划过的剧不请求，停留一小会儿才请求。

## SDK 来源与许可

| 项目 | 说明 |
|---|---|
| SDK | [beilunyang/openhongguo](https://github.com/beilunyang/openhongguo)，Apache License 2.0 |
| iOS | v0.1.1，本地副本在 `iOS/Vendor/Openhongguo/`（许可全文和来源说明在同目录 `LICENSE`、`NOTICE.md`）。上游没有发布预编译的 xcframework，所以用 `iOS/scripts/build-sdk.sh` 从源码编译，Swift 封装层原样拷贝、未作修改 |
| Android | Maven Central 的 `io.github.beilunyang:openhongguo:0.1.0`，其 Kotlin 绑定源码与 v0.1.1 的一致 |

## 已知限制

- **几乎所有分集都是加密的**，播放依赖本地解密；服务端没有下发内容密钥的分集无法播放，会显示占位。
- 是否加密只有请求过播放模型才知道，而每次请求都消耗设备额度，所以不会为了“探测”而批量请求。
- **iOS 真机部署受 Xcode 版本限制**：Xcode 16.2 不支持 iOS 27 这一代设备，需要更新的 Xcode。
- 小窗和保持亮屏两端都只做了编译验证，没有在真机上系统地测过。
- 服务端接口随时可能改版：SDK 对缺失字段取零值，解析失败显示“数据格式异常”，不会崩溃。
