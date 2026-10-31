package personal.heiguo.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import personal.heiguo.AppEnv
import personal.heiguo.HeiguoApp
import personal.heiguo.domain.AppError
import personal.heiguo.domain.SeriesItem
import java.net.HttpURLConnection
import java.net.URL

@Composable
fun rememberEnv(): AppEnv = (LocalContext.current.applicationContext as HeiguoApp).env

/** 按 key 创建并缓存 ViewModel，注入 AppEnv。 */
@Composable
inline fun <reified VM : ViewModel> envViewModel(key: String? = null, crossinline create: (AppEnv) -> VM): VM {
    val env = rememberEnv()
    return viewModel(key = key, factory = viewModelFactory { initializer { create(env) } })
}

// ───────────── 图片：自带的轻量加载器（内存 LRU + HttpURLConnection），不引入第三方库 ─────────────

object ImageLoader {
    private val cache = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    suspend fun load(url: String, maxDim: Int = 720): Bitmap? {
        cache.get(url)?.let { return it }
        return withContext(Dispatchers.IO) {
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 10_000
                conn.readTimeout = 15_000
                val bytes = try { conn.inputStream.use { it.readBytes() } } finally { conn.disconnect() }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sample = 1
                while (bounds.outWidth / (sample * 2) >= maxDim && bounds.outHeight / (sample * 2) >= maxDim) sample *= 2
                val opts = BitmapFactory.Options().apply { inSampleSize = sample }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)?.also { cache.put(url, it) }
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                throw e
            } catch (_: Throwable) {
                null
            }
        }
    }
}

@Composable
fun RemoteImage(url: String?, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop) {
    var image by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(url) { image = url?.let { ImageLoader.load(it)?.asImageBitmap() } }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceVariant)) {
        image?.let { Image(it, null, Modifier.matchParentSize(), contentScale = contentScale) }
    }
}

// ───────────── 加载 / 空 / 错误三态 ─────────────

@Composable
fun LoadingView(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
fun EmptyView(text: String, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun ErrorView(error: AppError, onRetry: (() -> Unit)?, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(error.userMessage, textAlign = TextAlign.Center)
        Text(error.code.raw, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (onRetry != null && error.isRetryable) {
            Spacer(Modifier.height(12.dp))
            Button(onClick = onRetry) { Text("重试") }
        }
    }
}

/** 按 LoadState 在四种状态间切换。 */
@Composable
fun LoadStateContent(state: LoadState, onRetry: () -> Unit, emptyText: String = "暂无内容", content: @Composable () -> Unit) {
    when (state) {
        LoadState.Idle, LoadState.Loading -> LoadingView()
        LoadState.Empty -> EmptyView(emptyText)
        is LoadState.Failed -> ErrorView(state.error, onRetry)
        LoadState.Loaded -> content()
    }
}

// ───────────── 剧卡片与分页网格 ─────────────

@Composable
fun SeriesCard(item: SeriesItem, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(8.dp))) {
            RemoteImage(item.coverUrl, Modifier.matchParentSize())
            if (item.episodeCount > 0) {
                Text(
                    "${item.episodeCount}集", color = Color.White, style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp)
                        .background(Color(0x99000000), RoundedCornerShape(4.dp)).padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
            item.badge?.let {
                Text(
                    it, color = Color.White, style = MaterialTheme.typography.labelSmall, maxLines = 1,
                    modifier = Modifier.align(Alignment.TopStart).padding(4.dp)
                        .background(Color(0xCCE5322D), RoundedCornerShape(4.dp)).padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
        }
        Text(
            item.title, maxLines = 2, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp),
        )
    }
}

/** 带分页、滚动到底加载更多、三态的剧集网格。 */
@Composable
fun PagedSeriesGrid(
    pager: Paginator<SeriesItem>,
    onOpen: (SeriesItem) -> Unit,
    emptyText: String = "暂无内容",
    header: (@Composable () -> Unit)? = null,
    state: LazyGridState = rememberLazyGridState(),
) {
    val s by pager.state.collectAsState()
    LoadStateContent(s.load, onRetry = pager::refresh, emptyText = emptyText) {
        LazyVerticalGrid(
            GridCells.Fixed(3), Modifier.fillMaxSize(), state,
            contentPadding = PaddingValues(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (header != null) item(span = { GridItemSpan(maxLineSpan) }) { header() }
            itemsIndexed(s.items, key = { _, it -> it.id }) { i, item ->
                LaunchedEffect(i, s.items.size) { pager.onItemVisible(i) }
                SeriesCard(item, { onOpen(item) })
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                    val err = s.moreError
                    when {
                        s.loadingMore -> CircularProgressIndicator(Modifier.size(24.dp))
                        err != null -> TextButton(onClick = pager::retryLoadMore) { Text("${err.userMessage}，点击重试") }
                        !s.hasMore && s.items.isNotEmpty() ->
                            Text("没有更多了", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

fun formatTime(seconds: Double): String {
    val t = seconds.toInt().coerceAtLeast(0)
    return "%02d:%02d".format(t / 60, t % 60)
}
