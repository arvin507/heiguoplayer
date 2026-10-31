import SwiftUI
import HongguoKit

/// 全屏播放页：上滑下一集、下滑上一集，播完自动连播，退出时保存进度。
/// 右上角“全屏”切到横屏铺满；横屏时把手机转回竖着拿、或再点一次按钮即退出。
struct PlayerScreen: View {
    @State var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showEpisodes = false
    @State private var isLandscape = false
    @State private var chromeVisible = true
    @State private var hideChromeTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            PlayerSurface(vm: vm, active: true, showsInfo: !isLandscape || chromeVisible,
                          onTap: isLandscape ? { toggleChrome() } : nil)
            if !isLandscape || chromeVisible {
                topBar.transition(.opacity)
            }
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(isLandscape ? .hidden : .automatic)
        .sheet(isPresented: $showEpisodes) {
            EpisodePicker(vm: vm) { showEpisodes = false }
                .presentationDetents([.medium, .large])
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // 横屏全屏时，用户把手机转回竖着拿：退出全屏
            if isLandscape, UIDevice.current.orientation == .portrait { setLandscape(false) }
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear {
            hideChromeTask?.cancel()
            if isLandscape { OrientationController.exitLandscape() }
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .task {
            if let s = DebugLaunch.value("debugExitAfter").flatMap(Double.init) {
                if DebugLaunch.flag("debugLandscape") { setLandscape(true) }
                try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                dismiss()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                if isLandscape { setLandscape(false) } else { dismiss() }
            } label: {
                Image(systemName: isLandscape ? "chevron.left" : "chevron.down")
                    .font(.title3.weight(.semibold)).padding(12)
            }
            .accessibilityLabel(isLandscape ? "退出全屏" : "关闭")
            if isLandscape, let ep = vm.current {
                Text("\(vm.seriesTitle) · 第 \(ep.number) 集").font(.subheadline.weight(.medium)).lineLimit(1)
            }
            Spacer()
            if !isLandscape {
                Button { showEpisodes = true } label: {
                    Label("选集", systemImage: "list.number").font(.subheadline.weight(.medium)).padding(12)
                }
            }
            Button { setLandscape(!isLandscape) } label: {
                Image(systemName: isLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.body.weight(.semibold)).padding(12)
            }
            .accessibilityLabel(isLandscape ? "退出全屏" : "全屏")
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .padding(.horizontal, isLandscape ? 24 : 0)
        .background {
            if isLandscape {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }

    private func setLandscape(_ on: Bool) {
        guard on != isLandscape else { return }
        isLandscape = on
        on ? OrientationController.enterLandscape() : OrientationController.exitLandscape()
        chromeVisible = true
        if on { scheduleHideChrome() } else { hideChromeTask?.cancel() }
    }

    /// 横屏时点一下画面显示 / 隐藏控件，3 秒后自动隐藏。
    private func toggleChrome() {
        withAnimation { chromeVisible.toggle() }
        if chromeVisible { scheduleHideChrome() }
    }

    private func scheduleHideChrome() {
        hideChromeTask?.cancel()
        hideChromeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { chromeVisible = false }
        }
    }
}

/// 播放区域：画面 + 状态覆盖层 + 手势。推荐流和播放页共用。
struct PlayerSurface: View {
    let vm: PlayerViewModel
    /// 推荐流里不在当前屏的时候为 false。
    var active: Bool
    /// 推荐流里由外层 ScrollView 负责上下滑，这里关闭切集手势。
    var episodeSwipe = true
    /// 底部信息区额外留白（推荐流里要让出 Tab 栏）。
    var bottomInset: CGFloat = 0
    /// 是否显示底部的剧名、集数和进度（横屏全屏隐藏控件时为 false）。
    var showsInfo = true
    /// 自定义单击行为；为 nil 时单击切换播放 / 暂停。
    var onTap: (() -> Void)?
    @State private var engine = PlayerEngine()
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: engine.player)
                .opacity(isReady ? 1 : 0)
            overlay
            if showsInfo {
                VStack {
                    Spacer()
                    info
                }
                .transition(.opacity)
            }
            if let toast {
                Text(toast).font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isReady { engine.togglePlay() } }
        .onTapGesture {
            if let onTap { onTap() } else if isReady { engine.togglePlay() }
        }
        .gesture(episodeSwipe ? swipe : nil)
        .onAppear(perform: bind)
        .onChange(of: vm.state) { _, s in apply(s) }
        .onChange(of: active) { _, a in a ? apply(vm.state) : engine.pause() }
        .onDisappear {
            vm.stop(at: engine.currentTime > 0 ? engine.currentTime : nil)
            engine.teardown()
        }
    }

    private var isReady: Bool { if case .ready = vm.state { true } else { false } }

    private func bind() {
        engine.onProgress = { [vm] t, d in vm.progress(seconds: t, duration: d) }
        engine.onFinish = { [vm] in
            if vm.autoplayNext, vm.hasNext { flash("自动播放第 \(vm.index + 2) 集") }
            vm.didFinish()
        }
        engine.onFailure = { [vm] msg, t in vm.playerFailed(msg, at: t) }
        if vm.state == .idle { vm.start() } else { apply(vm.state) }
    }

    private func apply(_ s: PlayerViewModel.State) {
        guard active else { return }
        if case .ready(let url, let start) = s {
            engine.load(url, startAt: start)
        } else {
            engine.unload()
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { v in
            guard abs(v.translation.height) > abs(v.translation.width) * 1.5 else { return }
            if v.translation.height < -60 {
                vm.hasNext ? vm.next() : flash("已经是最后一集")
            } else if v.translation.height > 60 {
                vm.hasPrevious ? vm.previous() : flash("已经是第一集")
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch vm.state {
        case .idle, .resolving:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("正在获取播放地址…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        case .ready:
            if engine.isBuffering { ProgressView().tint(.white) }
            else if !engine.isPlaying && active {
                Image(systemName: "play.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.8))
            }
        case .preparing(let progress):
            VStack(spacing: 12) {
                if progress > 0.01 {
                    ProgressView(value: progress).tint(.white).frame(width: 200)
                } else {
                    // 刚拿到播放模型、还在连 CDN：不确定进度，别让进度条停在 0 像卡死。
                    ProgressView().tint(.white)
                }
                Text(progress > 0.01 ? "正在解密本集… \(Int(progress * 100))%" : "正在准备加密分集…")
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
            }
        case .keyUnavailable:
            placeholder(icon: "key.slash", title: "无法播放加密分集",
                        message: "服务端没有下发这一集的内容密钥。\n可以上下滑动切换到其他集。", retry: nil)
        case .unplayable:
            placeholder(icon: "nosign", title: "该集暂不可播放", message: "服务端禁止播放这一集。", retry: nil)
        case .failed(let e):
            placeholder(icon: e.code == .transport ? "wifi.exclamationmark" : "exclamationmark.triangle",
                        title: "播放失败", message: e.userMessage, retry: e.isRetryable ? { vm.retry() } : nil)
        }
    }

    private func placeholder(icon: String, title: String, message: String, retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40))
            Text(title).font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
            if let retry {
                Button("重试", action: retry).buttonStyle(.borderedProminent)
            }
            #if DEBUG
            if case .failed(let e) = vm.state { Text(e.code.rawValue).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.4)) }
            #endif
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.seriesTitle).font(.headline).lineLimit(1)
            if let ep = vm.current {
                Text("第 \(ep.number) 集 / 共 \(vm.episodes.count) 集").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }
            if isReady, engine.duration > 0 {
                PlaybackControls(engine: engine)
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 24 + bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }
}

struct EpisodePicker: View {
    let vm: PlayerViewModel
    var onPick: () -> Void
    @Environment(\.appEnv) private var env

    var body: some View {
        NavigationStack {
            ScrollView {
                let encrypted = env.library.encryptedEpisodeIds(vm.seriesId)
                let records = env.library.records(for: vm.seriesId)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(Array(vm.episodes.enumerated()), id: \.element.id) { i, ep in
                        EpisodeCell(number: ep.number, status: status(ep, encrypted, records)) {
                            vm.play(at: i)
                            onPick()
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: i == vm.index ? 2 : 0))
                    }
                }
                .padding()
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle("自动连播", isOn: Binding(get: { vm.autoplayNext }, set: { vm.autoplayNext = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                ToolbarItem(placement: .topBarLeading) { Text("自动连播").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func status(_ ep: EpisodeItem, _ enc: Set<String>, _ rec: [Int: WatchRecord]) -> SeriesDetailViewModel.EpisodeStatus {
        if !ep.playable { return .unplayable }
        if enc.contains(ep.id) { return .encrypted }
        guard let r = rec[ep.number] else { return .unwatched }
        if r.isFinished { return .finished }
        return r.durationSeconds > 0 ? .inProgress(min(1, r.progressSeconds / r.durationSeconds)) : .unwatched
    }
}

/// 可拖动的进度条 + 时间 + 倍速。拖动时只更新预览，松手才跳转。
struct PlaybackControls: View {
    let engine: PlayerEngine
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Button { engine.togglePlay() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
            }
            .accessibilityLabel(engine.isPlaying ? "暂停" : "播放")

            Text(Self.format(scrubbing ? scrubValue : engine.currentTime))
                .font(.caption.monospacedDigit())
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : min(engine.currentTime, engine.duration) },
                    set: { scrubValue = $0 }),
                in: 0...max(engine.duration, 1)
            ) { editing in
                if editing {
                    scrubValue = engine.currentTime
                    scrubbing = true
                } else {
                    engine.seek(to: scrubValue)
                    scrubbing = false
                }
            }
            .tint(.white)
            .accessibilityLabel("播放进度")
            Text(Self.format(engine.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))

            Menu {
                ForEach(PlayerEngine.rates, id: \.self) { r in
                    Button {
                        engine.setRate(r)
                    } label: {
                        if r == engine.rate { Label(Self.rateText(r), systemImage: "checkmark") } else { Text(Self.rateText(r)) }
                    }
                }
            } label: {
                Text(engine.rate == 1 ? "倍速" : Self.rateText(engine.rate))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .accessibilityLabel("播放倍速")
        }
    }

    static func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func rateText(_ r: Float) -> String {
        r == r.rounded() ? String(format: "%.1fx", r) : String(format: "%gx", r)
    }
}
