# 黑果短剧 · Android

个人学习项目，仅自用，不发布、不分发。基于非官方 [openhongguo](https://github.com/beilunyang/openhongguo) SDK（Apache-2.0，Maven Central 的 Kotlin 绑定 `io.github.beilunyang:openhongguo:0.1.0`，与 iOS 端用的 v0.1.1 源码一致）。是 `../iOS` 的 Jetpack Compose 版本，结构一一对应。

## 构建

需要 Android SDK（compileSdk 36）和 JDK 17+（Android Studio 自带的 JBR 即可）。

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

真机需要开启「开发者选项 → USB 调试」。release 变体也用 debug 签名，直接装机，不含任何分发配置。

### 网络不稳时

Gradle 下载大包（例如 KSP 的 `symbol-processing-aa-embeddable`，约 60MB）遇到连接中断会直接失败。可以用 curl（支持断点续传和重试）预先下到 `localrepo/`，目录结构与 Maven 仓库一致，`settings.gradle.kts` 已优先读取：

```bash
V=2.1.20-2.0.1; D=localrepo/com/google/devtools/ksp/symbol-processing-aa-embeddable/$V; mkdir -p $D
for e in jar pom module; do
  curl -L --retry 20 --retry-all-errors -C - -o $D/symbol-processing-aa-embeddable-$V.$e \
    https://repo1.maven.org/maven2/com/google/devtools/ksp/symbol-processing-aa-embeddable/$V/symbol-processing-aa-embeddable-$V.$e
done
```

`localrepo/` 已加入 `.gitignore`。

## 架构

`Service → Repository → ViewModel → Compose`，与 iOS 相同：

| 层 | 位置 | 说明 |
|---|---|---|
| Service | `service/` | `HongguoService` 接口；SDK 只出现在 `LiveHongguoService`，错误统一映射为 `AppError` |
| Repository | `repo/` | `PlaybackRepository`（串行、按集缓存、限流/配额策略）、`CatalogRepository`（TTL 缓存、分页去重、列表接口把 ANONYMOUS_LIMITED 当空） |
| 本机数据 | `data/` | Room：观看记录、收藏、追更、加密标记、推荐流位置；只存本机，不参与备份 |
| ViewModel | `ui/*ViewModel*.kt`、`PlayerController` | `StateFlow`；`Paginator` 统一分页与三态 |
| 界面 | `ui/*Screen*.kt` | 推荐 / 找剧 / 榜单 / 我的 + 详情 + 播放 |

播放用 Media3 ExoPlayer。未加密的流直接播放；加密分集走 `media/` 下的 CENC 解密和本地缓存（`CENCDecryptor`、`ProtectedMediaStore`，与 iOS 的 `Playback/` 对应），拿不到内容密钥时显示占位，记住并标记，不重复请求。播放页有进度条、倍速（0.75–2x）、选集、上下滑动切集、横屏全屏。

### 小窗（画中画）

回到桌面时视频缩成小窗继续播放（`ui/Pip.kt`、`MainActivity`）：

- Android 12+ 用 `setAutoEnterEnabled(true)` 自动进入；更低版本在 `onUserLeaveHint` 手动进入。小窗宽高比跟随视频。
- 小窗里只显示视频：底部导航栏、控件、封面背景和渐变都会隐藏。
- 推荐流和播放页都支持。不在小窗里却退到后台（锁屏、切到别的 App）时会暂停，不会留下“只有声音没有画面”的后台播放；关闭小窗也会停止。
- 画面用 `TextureView` 版本的 `PlayerView`（`res/layout/view_player_texture.xml`），进出小窗、窗口缩放（含小米的小窗模式）时比 `SurfaceView` 更不容易丢画面。

### 保持亮屏

播放（含缓冲）期间设置 `keepScreenOn`，暂停、播完或离开页面后恢复系统自动熄屏（`KeepScreenOn`，在 `BindPlayback` 里统一接入）。

### 搜索联想

SDK 的联想词 `keyword` 对“直达行”是**内容 ID**（长数字串），拿去搜索搜不到。`LiveHongguoService.suggestionKeyword` 遇到 10 位以上的纯数字就改用显示文字；有对应单元测试。

设备档案放在 `noBackupFilesDir`，网络日志经 `Redactor` 脱敏（URL 查询参数值替换为 `***`）。

## 已知限制

- 目前探测到的分集大多是加密的，播放依赖 `media/` 下的解密；服务端没下发内容密钥时只能显示占位。
- **小窗和保持亮屏没有在真机上验证**：只做了编译验证。自动进入、还原、关闭、不同 Android 版本以及小米自带的小窗模式，都需要在手机上实际试一遍。
- 图片用自带的轻量加载器（内存 LRU），没有磁盘缓存。
- 允许明文 HTTP 流量（视频流地址可能不是 https）。
