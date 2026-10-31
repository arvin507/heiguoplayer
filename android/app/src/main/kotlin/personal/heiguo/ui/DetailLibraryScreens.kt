package personal.heiguo.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import personal.heiguo.domain.EpisodeItem
import personal.heiguo.domain.SeriesStatusKind

// ───────────────────────── 详情 ─────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeriesDetailScreen(seriesId: String, onBack: () -> Unit, onPlay: (episodeNumber: Int, atSeconds: Double) -> Unit) {
    val vm = envViewModel<SeriesDetailViewModel>(key = "detail-$seriesId") { SeriesDetailViewModel(seriesId, it) }
    val ui by vm.ui.collectAsState()

    LaunchedEffect(seriesId) { vm.load() }
    // 从播放页返回时刷新观看状态
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) vm.refreshLocal() }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(ui.series?.title ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = {
                    if (ui.series != null) {
                        IconButton(onClick = vm::toggleFollow) {
                            Icon(Icons.Default.Notifications, "追更",
                                tint = if (ui.isFollowed) MaterialTheme.colorScheme.primary else LocalContentColor.current)
                        }
                        IconButton(onClick = vm::toggleFavorite) {
                            Icon(if (ui.isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder, "收藏",
                                tint = if (ui.isFavorite) MaterialTheme.colorScheme.primary else LocalContentColor.current)
                        }
                    }
                },
            )
        },
        bottomBar = {
            ui.resume?.let { r ->
                Surface(tonalElevation = 3.dp) {
                    Button(
                        onClick = { onPlay(r.episode.number, r.seconds) },
                        modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp),
                    ) { Icon(Icons.Default.PlayArrow, null); Spacer(Modifier.width(4.dp)); Text(r.label) }
                }
            }
        },
    ) { pad ->
        val failed = ui.state as? LoadState.Failed
        if (ui.series == null && failed != null) {
            Box(Modifier.padding(pad)) { ErrorView(failed.error, onRetry = { vm.load(force = true) }) }
        } else if (ui.series == null) {
            Box(Modifier.padding(pad)) { LoadingView() }
        } else {
            val series = ui.series!!
            LazyVerticalGrid(
                GridCells.Adaptive(56.dp), Modifier.padding(pad).fillMaxSize(),
                contentPadding = PaddingValues(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        RemoteImage(series.coverUrl, Modifier.width(110.dp).aspectRatio(3f / 4f).clip(RoundedCornerShape(10.dp)))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(series.title, style = MaterialTheme.typography.titleMedium)
                            val st = series.statusText.ifEmpty { if (series.episodeCount > 0) "共${series.episodeCount}集" else "" }
                            if (st.isNotEmpty()) {
                                Text(
                                    st, style = MaterialTheme.typography.labelMedium,
                                    color = if (series.status == SeriesStatusKind.FINISHED) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
                                )
                            }
                            if (series.tags.isNotEmpty()) Text(series.tags.joinToString(" · "), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (series.summary.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) { ExpandableText(series.summary) }
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("选集", style = MaterialTheme.typography.titleSmall)
                    }
                }
                when (val es = ui.episodesState) {
                    LoadState.Idle, LoadState.Loading -> item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().height(80.dp)) { LoadingView() } }
                    LoadState.Empty -> item(span = { GridItemSpan(maxLineSpan) }) { Text("暂无分集", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    is LoadState.Failed -> item(span = { GridItemSpan(maxLineSpan) }) {
                        Column { Text(es.error.userMessage); if (es.error.isRetryable) TextButton(onClick = { vm.load(force = true) }) { Text("重试") } }
                    }
                    LoadState.Loaded -> items(ui.episodes, key = { it.id }) { ep ->
                        EpisodeCell(ep, SeriesDetailViewModel.status(ui, ep)) { onPlay(ep.number, -1.0) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ExpandableText(text: String) {
    var expanded by remember { mutableStateOf(false) }
    Text(
        text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = if (expanded) Int.MAX_VALUE else 3, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.clickable { expanded = !expanded },
    )
}

@Composable
private fun EpisodeCell(ep: EpisodeItem, status: EpisodeStatus, onClick: () -> Unit) {
    val enabled = status != EpisodeStatus.Unplayable
    Box(
        Modifier.clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(enabled = enabled, onClick = onClick).padding(vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        val dim = status == EpisodeStatus.Finished || status == EpisodeStatus.Unplayable
        Text("${ep.number}", color = if (dim) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
        when (status) {
            is EpisodeStatus.InProgress -> LinearProgressIndicator(
                progress = { status.fraction }, modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(3.dp).offset(y = 12.dp),
            )
            EpisodeStatus.Finished -> Icon(Icons.Default.Check, null, Modifier.align(Alignment.TopEnd).size(12.dp).offset(x = (-2).dp, y = (-10).dp), tint = MaterialTheme.colorScheme.primary)
            EpisodeStatus.Encrypted -> Icon(Icons.Default.Lock, "加密", Modifier.align(Alignment.TopEnd).size(12.dp).offset(x = (-2).dp, y = (-10).dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            EpisodeStatus.Unplayable -> Icon(Icons.Default.Close, "不可播", Modifier.align(Alignment.TopEnd).size(12.dp).offset(x = (-2).dp, y = (-10).dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> {}
        }
    }
}

// ───────────────────────── 我的 ─────────────────────────

@Composable
fun LibraryScreen(onOpenSeries: (String) -> Unit, onPlay: (String, Int, Double) -> Unit) {
    val vm = envViewModel<LibraryViewModel> { LibraryViewModel(it) }
    val ui by vm.ui.collectAsState()
    var tab by remember { mutableIntStateOf(0) }
    var confirmClear by remember { mutableStateOf(false) }
    val titles = listOf("历史", "收藏", if (ui.updatedFollowCount > 0) "追更 (${ui.updatedFollowCount})" else "追更")

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        TabRow(selectedTabIndex = tab) { titles.forEachIndexed { i, t -> Tab(tab == i, { tab = i }, text = { Text(t) }) } }
        when (tab) {
            0 -> if (ui.history.isEmpty()) EmptyView("还没有观看记录") else Column {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = { confirmClear = true }) { Text("清空") }
                }
                LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(ui.history, key = { it.seriesId }) { r ->
                        Row(Modifier.fillMaxWidth().clickable { onPlay(r.seriesId, r.episodeNumber, -1.0) }, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            RemoteImage(r.coverUrl, Modifier.width(60.dp).aspectRatio(3f / 4f).clip(RoundedCornerShape(6.dp)))
                            Column(Modifier.weight(1f)) {
                                Text(r.seriesTitle.ifEmpty { "未命名" }, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    "看到第 ${r.episodeNumber} 集 · " + if (r.isFinished) "已看完" else formatTime(r.progressSeconds),
                                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            IconButton(onClick = { onOpenSeries(r.seriesId) }) { Icon(Icons.Default.Info, "详情") }
                            IconButton(onClick = { vm.deleteHistory(r.seriesId) }) { Icon(Icons.Default.Delete, "删除") }
                        }
                    }
                }
            }
            1 -> if (ui.favorites.isEmpty()) EmptyView("还没有收藏") else LazyVerticalGrid(
                GridCells.Fixed(3), contentPadding = PaddingValues(12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(ui.favorites, key = { it.seriesId }) { f ->
                    SeriesCard(personal.heiguo.domain.SeriesItem(f.seriesId, f.title, coverUrl = f.coverUrl, episodeCount = f.episodeCount), { onOpenSeries(f.seriesId) })
                }
            }
            else -> if (ui.follows.isEmpty()) EmptyView("还没有追更的剧") else LazyVerticalGrid(
                GridCells.Fixed(3), contentPadding = PaddingValues(12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(ui.follows, key = { it.seriesId }) { f ->
                    SeriesCard(
                        personal.heiguo.domain.SeriesItem(
                            f.seriesId, f.title, coverUrl = f.coverUrl, episodeCount = f.latestEpisodeCount,
                            badge = if (f.hasUpdate) "新${f.newEpisodeCount}集" else if (f.isFinished) "已完结" else null,
                        ),
                        { onOpenSeries(f.seriesId) },
                    )
                }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空观看历史？") },
            text = { Text("只清除本机的观看记录，不影响收藏和追更。") },
            confirmButton = { TextButton(onClick = { vm.clearHistory(); confirmClear = false }) { Text("清空") } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("取消") } },
        )
    }
}
