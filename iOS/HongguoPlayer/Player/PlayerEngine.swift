import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// AVPlayer 的薄封装：加载地址、从指定秒数起播、上报进度 / 播完 / 失败。
/// 播 SDK 返回的未加密流地址，或解密后的本地文件（加密分集见 CENCDecryptor）。
@MainActor
@Observable
final class PlayerEngine {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// 播放倍速。切集后保持不变，并记住到下次启动。
    private(set) var rate: Float = PlayerEngine.savedRate
    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private static let rateKey = "playbackRate"
    private static var savedRate: Float {
        let r = UserDefaults.standard.float(forKey: rateKey)
        return rates.contains(r) ? r : 1.0
    }

    var onProgress: ((Double, Double) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((String, Double) -> Void)?

    private var loadedURL: URL?
    @ObservationIgnored private let pip = PiPCoordinator()
    /// 本引擎当前是否在计入“保持亮屏”的计数里。
    @ObservationIgnored private var holdsIdleLock = false
    /// 正在播放的引擎数。大于 0 时关闭系统自动锁屏，否则看一阵就熄屏。
    private static var idleLocks = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.onProgress?(self.currentTime, self.duration)
            }
        }
        bufferObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self?.isPlaying = status != .paused
                self?.updateIdleLock()
            }
        }
    }

    /// 把画面层交给画中画控制器：回到桌面时系统自动弹出小窗继续播放。
    func attachPiP(_ layer: AVPlayerLayer) { pip.attach(layer) }

    func load(_ url: URL, startAt: Double) {
        try? AVAudioSession.sharedInstance().setActive(true)
        guard url != loadedURL else {
            player.play()
            return
        }
        loadedURL = url
        currentTime = max(0, startAt)
        duration = 0
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain // 变速不变调
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription ?? "unknown"
            Task { @MainActor in
                guard let self, failed else { return }
                self.onFailure?(message, self.currentTime)
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinish?() }
        }
        player.replaceCurrentItem(with: item)
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        player.play()
    }

    func togglePlay() { isPlaying ? player.pause() : player.play() }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r // play() 使用 defaultRate
        if isPlaying { player.rate = r }
        UserDefaults.standard.set(r, forKey: Self.rateKey)
    }
    func pause() { player.pause() }

    /// 精确跳转。完成后立刻上报一次进度，保证断点续播的位置准确。
    func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            guard done else { return }
            Task { @MainActor in
                guard let self else { return }
                self.onProgress?(self.currentTime, self.duration)
            }
        }
    }

    /// 停止并清空（切集、出错或离开页面）。
    func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        statusObservation = nil
    }

    /// 播放（含缓冲）期间保持亮屏，暂停、离开页面后恢复系统自动锁屏。
    private func updateIdleLock() {
        let want = isPlaying
        guard want != holdsIdleLock else { return }
        holdsIdleLock = want
        Self.idleLocks += want ? 1 : -1
        UIApplication.shared.isIdleTimerDisabled = Self.idleLocks > 0
    }

    func teardown() {
        pip.stop()
        unload()
        isPlaying = false
        updateIdleLock()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        bufferObservation = nil
    }
}

/// 画中画（小窗）：回到桌面时自动进入，点小窗上的“还原”回到 App。
/// 需要 Info.plist 的 UIBackgroundModes=audio 和 .playback 音频会话。
final class PiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?

    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if controller?.playerLayer === layer { return }
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // 播放界面一直在，不需要额外恢复
        completionHandler(true)
    }
}

/// 用 AVPlayerLayer 显示画面（不用 VideoPlayer，避免系统控件和我们的手势冲突）。
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// 画面层创建后回调，用来挂画中画。
    var onLayer: ((AVPlayerLayer) -> Void)?

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.backgroundColor = .black
        onLayer?(v.playerLayer)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
