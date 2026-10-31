package personal.heiguo.ui

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.ViewGroup
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import personal.heiguo.AppEnv
import personal.heiguo.domain.AppError

// ───────────────────────── ExoPlayer 绑定 ─────────────────────────

@Composable
fun rememberExoPlayer(): ExoPlayer {
    val context = LocalContext.current
    val player = remember { ExoPlayer.Builder(context).build() }
    DisposableEffect(player) { onDispose { player.release() } }
    return player
}

/**
 * 把 PlayerController 的状态接到 ExoPlayer：Ready → 起播并跳到起播位置；
 * 播放结束 → didFinish（自动连播）；播放出错 → playerFailed（换备用地址）；
 * 播放期间每秒回报一次进度。
 */
@Composable
fun BindPlayback(controller: PlayerController, player: ExoPlayer, active: Boolean = true) {
    val state by controller.state.collectAsState()
    KeepScreenOn(player)

    DisposableEffect(controller, player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) controller.didFinish()
            }

            override fun onPlayerError(error: PlaybackException) {
                controller.playerFailed(error.errorCodeName, player.currentPosition / 1000.0)
            }
        }
        player.addListener(listener)
        onDispose {
            controller.stop(player.currentPosition / 1000.0)
            player.removeListener(listener)
        }
    }

    LaunchedEffect(state, active) {
        val st = state
        if (st is PlayerState.Ready && active) {
            player.setMediaItem(MediaItem.fromUri(st.url))
            player.prepare()
            if (st.startAt > 0) player.seekTo((st.startAt * 1000).toLong())
            player.playWhenReady = true
        } else {
            player.pause()
        }
    }

    LaunchedEffect(state, active) {
        while (state is PlayerState.Ready && active) {
            delay(1000)
            if (player.isPlaying) controller.progress(player.currentPosition / 1000.0, maxOf(0L, player.duration) / 1000.0)
        }
    }
}

/** 播放（含缓冲）期间保持亮屏，暂停、结束或离开页面后恢复系统自动熄屏。 */
@Composable
fun KeepScreenOn(player: ExoPlayer) {
    val view = androidx.compose.ui.platform.LocalView.current
    DisposableEffect(player, view) {
        fun update() {
            view.keepScreenOn = player.playWhenReady &&
                (player.playbackState == Player.STATE_READY || player.playbackState == Player.STATE_BUFFERING)
        }
        val l = object : Player.Listener {
            override fun onEvents(p: Player, events: Player.Events) = update()
        }
        player.addListener(l)
        update()
        onDispose {
            player.removeListener(l)
            view.keepScreenOn = false
        }
    }
}

@Composable
fun VideoSurface(player: ExoPlayer, modifier: Modifier = Modifier) {
    AndroidView(
        factory = { ctx ->
            // TextureView 版本的 PlayerView，进出小窗、窗口缩放时更不容易丢画面
            (android.view.LayoutInflater.from(ctx).inflate(personal.heiguo.R.layout.view_player_texture, null) as PlayerView).apply {
                this.player = player
            }
        },
        update = { it.player = player },
        modifier = modifier,
    )
}

/** 播放状态占位：解析中 / 解密中 / 无密钥 / 不可播 / 失败。Ready 时不显示。 */
@Composable
fun PlayerStatusOverlay(state: PlayerState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        when (state) {
            PlayerState.Idle, PlayerState.Resolving -> CircularProgressIndicator(color = Color.White)
            is PlayerState.Preparing -> {
                val progress = state.progress
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // 进度为 0 表示还没连上 CDN / 总长度未知，用不确定进度条。
                    if (progress > 0.01f) {
                        LinearProgressIndicator(
                            progress = { progress },
                            color = Color.White,
                            trackColor = Color(0x33FFFFFF),
                            modifier = Modifier.width(200.dp),
                        )
                    } else {
                        CircularProgressIndicator(color = Color.White)
                    }
                    Spacer(Modifier.height(12.dp))
                    Text(
                        if (progress > 0.01f) "正在解密本集… ${(progress * 100).toInt()}%" else "正在准备加密分集…",
                        color = Color.White, style = MaterialTheme.typography.labelMedium,
                    )
                }
            }
            PlayerState.KeyUnavailable -> Notice(Icons.Default.Lock, "无法播放加密分集", "服务端没有下发这一集的内容密钥。\n可以上下滑动切换到其他集。")
            PlayerState.Unplayable -> Notice(Icons.Default.Close, "这一集暂不可播放", "服务端禁止播放该集。")
            is PlayerState.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Notice(Icons.Default.Warning, state.error.userMessage, state.error.code.raw)
                if (state.error.isRetryable) {
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = onRetry) { Text("重试") }
                }
            }
            is PlayerState.Ready -> {}
        }
    }
}

@Composable
private fun Notice(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(24.dp)) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(36.dp))
        Spacer(Modifier.height(8.dp))
        Text(title, color = Color.White, style = MaterialTheme.typography.titleSmall)
        Text(detail, color = Color(0xFFBBBBBB), style = MaterialTheme.typography.labelSmall)
    }
}

// ───────────────────────── 播放页 ─────────────────────────

data class PlayerHostState(val load: LoadState = LoadState.Loading, val controller: PlayerController? = null, val title: String = "")

/** 加载剧信息和分集后创建 PlayerController。播放页离开时随 ViewModel 一起销毁。 */
class PlayerHostViewModel(
    private val seriesId: String,
    private val startNumber: Int,
    private val startAt: Double,
    private val env: AppEnv,
) : ViewModel() {
    private val _ui = MutableStateFlow(PlayerHostState())
    val ui: StateFlow<PlayerHostState> = _ui

    init { load() }

    fun load() {
        _ui.value = PlayerHostState(LoadState.Loading)
        viewModelScope.launch {
            try {
                val series = runCatching { env.catalog.series(seriesId) }.getOrNull()
                val eps = env.catalog.episodes(seriesId)
                if (eps.isEmpty()) { _ui.value = PlayerHostState(LoadState.Empty); return@launch }
                val idx = eps.indexOfFirst { it.number == startNumber }.coerceAtLeast(0)
                // 详情页进来的播放：提前把后面两集解密好，切集不用等下载。
                val c = PlayerController(seriesId, series?.title ?: "", series?.coverUrl, eps, idx, startAt, env,
                    viewModelScope, prefetchCount = 2)
                _ui.value = PlayerHostState(LoadState.Loaded, c, series?.title ?: "")
                c.start()
            } catch (t: Throwable) {
                AppError.from(t)?.let { _ui.value = PlayerHostState(LoadState.Failed(it)) }
            }
        }
    }

    override fun onCleared() {
        _ui.value.controller?.stop()
    }
}

private val SPEEDS = listOf(0.75f, 1f, 1.25f, 1.5f, 2f)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerScreen(seriesId: String, startNumber: Int, startAt: Double, onBack: () -> Unit) {
    val vm = envViewModel<PlayerHostViewModel>(key = "player-$seriesId-$startNumber") { PlayerHostViewModel(seriesId, startNumber, startAt, it) }
    val host by vm.ui.collectAsState()
    val activity = LocalContext.current as Activity
    var fullscreen by remember { mutableStateOf(false) }

    // 横屏全屏：旋转并隐藏系统栏；离开时恢复
    DisposableEffect(fullscreen) {
        val window = activity.window
        val ctl = WindowInsetsControllerCompat(window, window.decorView)
        if (fullscreen) {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            ctl.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            ctl.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            ctl.show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            ctl.show(WindowInsetsCompat.Type.systemBars())
        }
    }
    LaunchedEffect(Unit) { WindowCompat.setDecorFitsSystemWindows(activity.window, true) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        val controller = host.controller
        when {
            controller == null -> {
                LoadStateContent(host.load, onRetry = vm::load, emptyText = "没有分集") {}
                IconButton(onClick = onBack, Modifier.align(Alignment.TopStart).statusBarsPadding()) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回", tint = Color.White)
                }
            }
            else -> PlayerContent(controller, fullscreen, { fullscreen = !fullscreen }, onBack = {
                if (fullscreen) fullscreen = false else onBack()
            })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlayerContent(controller: PlayerController, fullscreen: Boolean, onToggleFullscreen: () -> Unit, onBack: () -> Unit) {
    val player = rememberExoPlayer()
    BindPlayback(controller, player)
    val state by controller.state.collectAsState()
    PipEffect(player, active = state is PlayerState.Ready)
    val inPip by PipState.inPip.collectAsState()
    // 不在小窗里却退到后台（锁屏、切到别的 App）：暂停，不要留下只有声音没有画面的后台播放
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, player) {
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e ->
            if (e == androidx.lifecycle.Lifecycle.Event.ON_STOP && !PipState.inPip.value) player.pause()
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
    }
    val index by controller.index.collectAsState()
    val episode = controller.episodes.getOrNull(index)

    var showControls by remember { mutableStateOf(true) }
    var isPlaying by remember { mutableStateOf(false) }
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(0L) }
    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(0f) }
    var speed by remember { mutableFloatStateOf(1f) }
    var speedMenu by remember { mutableStateOf(false) }
    var pickEpisode by remember { mutableStateOf(false) }

    DisposableEffect(player) {
        val l = object : Player.Listener {
            override fun onIsPlayingChanged(p: Boolean) { isPlaying = p }
        }
        player.addListener(l)
        onDispose { player.removeListener(l) }
    }
    LaunchedEffect(player) {
        while (true) {
            if (!dragging) { position = player.currentPosition; duration = maxOf(0L, player.duration) }
            delay(250)
        }
    }
    LaunchedEffect(speed, state) { player.setPlaybackSpeed(speed) }
    // 控件 3 秒后自动隐藏（播放中）
    LaunchedEffect(showControls, isPlaying, dragging) {
        if (showControls && isPlaying && !dragging) { delay(3000); showControls = false }
    }

    val gesture = Modifier
        // 上下滑动切集：上滑下一集，下滑上一集
        .pointerInput(controller) {
            var total = 0f
            detectVerticalDragGestures(
                onDragStart = { total = 0f },
                onVerticalDrag = { _, dy -> total += dy },
                onDragEnd = {
                    if (total < -120f) controller.next() else if (total > 120f) controller.previous()
                },
            )
        }
        .clickable(indication = null, interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }) {
            showControls = !showControls
        }

    Box(Modifier.fillMaxSize().then(gesture)) {
        VideoSurface(player, Modifier.fillMaxSize())
        PlayerStatusOverlay(state, onRetry = controller::retry, modifier = Modifier.fillMaxSize())

        if (showControls && !inPip) {
            // 顶栏
            Row(
                Modifier.align(Alignment.TopStart).fillMaxWidth().background(Color(0x66000000)).statusBarsPadding().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回", tint = Color.White) }
                Column(Modifier.weight(1f)) {
                    Text(controller.seriesTitle, color = Color.White, maxLines = 1, style = MaterialTheme.typography.titleSmall)
                    Text("第 ${episode?.number ?: 0} 集 / 共 ${controller.episodes.size} 集", color = Color(0xFFCCCCCC), style = MaterialTheme.typography.labelSmall)
                }
            }
            // 底栏：进度条 + 按钮
            Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Color(0x66000000)).navigationBarsPadding().padding(horizontal = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(formatTime((if (dragging) dragValue else position.toFloat()) / 1000.0), color = Color.White, style = MaterialTheme.typography.labelSmall)
                    Slider(
                        value = if (dragging) dragValue else position.toFloat(),
                        onValueChange = { dragging = true; dragValue = it },
                        onValueChangeFinished = { player.seekTo(dragValue.toLong()); position = dragValue.toLong(); dragging = false },
                        valueRange = 0f..maxOf(duration, 1L).toFloat(),
                        modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                    )
                    Text(formatTime(duration / 1000.0), color = Color.White, style = MaterialTheme.typography.labelSmall)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = controller::previous, enabled = controller.hasPrevious) { Text("上一集", color = Color.White) }
                    TextButton(onClick = { if (isPlaying) player.pause() else player.play() }) {
                        if (isPlaying) Text("暂停", color = Color.White) else Icon(Icons.Default.PlayArrow, "播放", tint = Color.White, modifier = Modifier.size(32.dp))
                    }
                    TextButton(onClick = controller::next, enabled = controller.hasNext) { Text("下一集", color = Color.White) }
                    Box {
                        TextButton(onClick = { speedMenu = true }) { Text(if (speed == 1f) "倍速" else "${speed}x", color = Color.White) }
                        DropdownMenu(expanded = speedMenu, onDismissRequest = { speedMenu = false }) {
                            SPEEDS.forEach { s ->
                                DropdownMenuItem(
                                    text = { Text("${s}x" + if (s == speed) "  ✓" else "") },
                                    onClick = { speed = s; speedMenu = false },
                                )
                            }
                        }
                    }
                    TextButton(onClick = { pickEpisode = true }) { Text("选集", color = Color.White) }
                    TextButton(onClick = onToggleFullscreen) {
                        Text(if (fullscreen) "退出全屏" else "全屏", color = Color.White)
                    }
                }
            }
        }
    }

    if (pickEpisode) {
        ModalBottomSheet(onDismissRequest = { pickEpisode = false }) {
            EpisodePicker(controller, index) { controller.play(it, 0.0); pickEpisode = false }
        }
    }
}

@Composable
private fun EpisodePicker(controller: PlayerController, current: Int, onPick: (Int) -> Unit) {
    LazyVerticalGrid(
        GridCells.Adaptive(56.dp), Modifier.fillMaxWidth().heightIn(max = 420.dp).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(controller.episodes.indices.toList()) { i ->
            val ep = controller.episodes[i]
            val selected = i == current
            Box(
                Modifier.clip(RoundedCornerShape(8.dp))
                    .background(if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant)
                    .clickable(enabled = ep.playable) { onPick(i) }.padding(vertical = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("${ep.number}", color = if (selected) Color.White else MaterialTheme.colorScheme.onSurface)
            }
        }
    }
    Spacer(Modifier.height(24.dp))
}
