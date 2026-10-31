package personal.heiguo.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import personal.heiguo.domain.SeriesItem

/** 推荐：竖屏一屏一部剧，上下滑动切换，停留后自动播放，记住位置。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FeedScreen(onOpenDetail: (SeriesItem) -> Unit, bottomInset: androidx.compose.ui.unit.Dp = 0.dp) {
    val vm = envViewModel<FeedViewModel> { FeedViewModel(it) }
    val pager by vm.feed.state.collectAsState()
    val ui by vm.ui.collectAsState()

    LaunchedEffect(Unit) { vm.load() }

    // 离开页面（切 Tab / 进入后台）时停止播放，回来时重新开始
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e ->
            // 进入小窗时 Activity 会 pause 但不会 stop，所以用 ON_STOP 判断：小窗里继续播，退出小窗或锁屏才停
            if (e == Lifecycle.Event.ON_STOP && !PipState.inPip.value) vm.pause()
            if (e == Lifecycle.Event.ON_START && vm.feed.state.value.items.isNotEmpty()) vm.resume()
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs); vm.pause() }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        LoadStateContent(pager.load, onRetry = vm.feed::refresh, emptyText = "暂时没有推荐内容") {
            val items = pager.items
            val pagerState = rememberPagerState(initialPage = vm.initialIndex().coerceIn(0, maxOf(0, items.size - 1))) { items.size }
            LaunchedEffect(pagerState) {
                snapshotFlow { pagerState.settledPage }.collect { vm.focus(it) }
            }
            VerticalPager(pagerState, Modifier.fillMaxSize(), key = { items[it].id }) { page ->
                FeedPage(items[page], ui, vm, bottomInset, onOpenDetail)
            }
        }
    }
}

@Composable
private fun FeedPage(item: SeriesItem, ui: FeedUiState, vm: FeedViewModel, bottomInset: androidx.compose.ui.unit.Dp, onOpenDetail: (SeriesItem) -> Unit) {
    val focused = ui.focusedId == item.id
    val player = if (focused) ui.player else null
    val inPip by PipState.inPip.collectAsState()
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (!inPip) {
            RemoteImage(item.coverUrl, Modifier.fillMaxSize(), ContentScale.Crop)
            Box(Modifier.fillMaxSize().background(Color(0x66000000)))
        }

        if (player != null) {
            val exo = rememberExoPlayer()
            BindPlayback(player, exo)
            val st by player.state.collectAsState()
            PipEffect(exo, active = st is PlayerState.Ready)
            if (st is PlayerState.Ready) VideoSurface(exo, Modifier.fillMaxSize())
            PlayerStatusOverlay(st, onRetry = player::retry, modifier = Modifier.fillMaxSize())
        } else if (focused) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                val err = ui.prepareError
                when {
                    err != null -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(err.userMessage, color = Color.White)
                        if (err.isRetryable) Button(onClick = vm::retry, Modifier.padding(top = 8.dp)) { Text("重试") }
                    }
                    ui.autoplayPaused -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("连续几部都没拿到内容密钥，已暂停自动播放", color = Color.White)
                        Button(onClick = vm::playFocused, Modifier.padding(top = 8.dp)) { Text("播放这一部") }
                        TextButton(onClick = vm::resumeAutoplay) { Text("恢复自动播放", color = Color.White) }
                    }
                    ui.preparingId == item.id -> CircularProgressIndicator(color = Color.White)
                }
            }
        }

        if (!inPip) {
            // 顶部渐变：让状态栏的时间、电量压在封面或视频上也看得清（不拦截点击和滑动）
            Box(
                Modifier.align(Alignment.TopStart).fillMaxWidth().height(120.dp)
                    .background(Brush.verticalGradient(listOf(Color(0x99000000), Color.Transparent))),
            )

            // 底部信息
            Column(
                Modifier.align(Alignment.BottomStart).fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xCC000000))))
                    .padding(start = 16.dp, end = 16.dp, top = 40.dp, bottom = 16.dp + bottomInset)
                    .clickable { onOpenDetail(item) },
            ) {
                Text(item.title, color = Color.White, style = MaterialTheme.typography.titleMedium)
                if (item.summary.isNotEmpty()) {
                    Text(item.summary, color = Color(0xFFDDDDDD), maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                }
                Text("共 ${item.episodeCount} 集 · 点击查看详情", color = Color(0xFFAAAAAA), style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
