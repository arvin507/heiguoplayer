package personal.heiguo.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import personal.heiguo.domain.*
import personal.heiguo.support.SeriesLinkParser

// ───────────────────────── 找剧 ─────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FindScreen(onOpen: (SeriesItem) -> Unit, onOpenId: (String) -> Unit) {
    val search = envViewModel<SearchViewModel> { SearchViewModel(it) }
    val filter = envViewModel<FilterViewModel> { FilterViewModel(it) }
    val ui by search.ui.collectAsState()
    var tab by remember { mutableIntStateOf(0) }
    var showLink by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { search.loadHot() }

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        OutlinedTextField(
            value = ui.query, onValueChange = search::onQueryChange,
            placeholder = { Text(ui.cue ?: "搜索短剧") },
            leadingIcon = { Icon(Icons.Default.Search, null) },
            trailingIcon = {
                Row {
                    if (ui.query.isNotEmpty()) IconButton(onClick = search::clear) { Icon(Icons.Default.Clear, "清除") }
                    TextButton(onClick = { showLink = true }) { Text("链接") }
                }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { search.submit() }),
            modifier = Modifier.fillMaxWidth().padding(12.dp),
        )

        when {
            ui.suggestions.isNotEmpty() && ui.query != ui.submitted -> LazyColumn(Modifier.fillMaxSize()) {
                items(ui.suggestions) { s ->
                    Text(s.text, Modifier.fillMaxWidth().clickable { search.submit(s.keyword) }.padding(horizontal = 16.dp, vertical = 12.dp))
                    HorizontalDivider()
                }
            }
            ui.submitted != null -> PagedSeriesGrid(search.results, onOpen, emptyText = "没有找到“${ui.submitted}”相关的短剧")
            else -> {
                TabRow(selectedTabIndex = tab) {
                    Tab(tab == 0, { tab = 0 }, text = { Text("热搜") })
                    Tab(tab == 1, { tab = 1; filter.load() }, text = { Text("分类筛选") })
                }
                if (tab == 0) HotContent(ui, search, onOpen) else FilterContent(filter, onOpen)
            }
        }
    }

    if (showLink) {
        OpenLinkDialog(onDismiss = { showLink = false }, onOpenId = { showLink = false; onOpenId(it) })
    }
}

@Composable
private fun HotContent(ui: SearchUiState, search: SearchViewModel, onOpen: (SeriesItem) -> Unit) {
    LoadStateContent(ui.hotState, onRetry = { search.loadHot() }, emptyText = "暂无热搜") {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (ui.hot.guesses.isNotEmpty()) item { HotSection("猜你想搜", ui.hot.guesses, onOpen) }
            items(ui.hot.boards) { b ->
                Column {
                    Text(b.name, style = MaterialTheme.typography.titleSmall)
                    if (b.topics.isNotEmpty()) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(vertical = 8.dp)) {
                            items(b.topics) { t -> AssistChip(onClick = { search.submit(t.keyword) }, label = { Text(t.text) }) }
                        }
                    }
                    if (b.items.isNotEmpty()) HotRow(b.items, onOpen)
                }
            }
        }
    }
}

@Composable
private fun HotSection(title: String, items: List<SeriesItem>, onOpen: (SeriesItem) -> Unit) {
    Column {
        Text(title, style = MaterialTheme.typography.titleSmall)
        Spacer(Modifier.height(8.dp))
        HotRow(items, onOpen)
    }
}

@Composable
private fun HotRow(items: List<SeriesItem>, onOpen: (SeriesItem) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        items(items, key = { it.id }) { SeriesCard(it, { onOpen(it) }, Modifier.width(104.dp)) }
    }
}

@Composable
private fun FilterContent(vm: FilterViewModel, onOpen: (SeriesItem) -> Unit) {
    val ui by vm.ui.collectAsState()
    LoadStateContent(ui.panel, onRetry = vm::load, emptyText = "暂无筛选项") {
        PagedSeriesGrid(vm.results, onOpen, emptyText = "没有符合条件的短剧", header = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                ui.rows.forEach { row ->
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        item { FilterChip(ui.selections[row.key] == null, { vm.select(row, null) }, label = { Text("全部") }) }
                        items(row.choices) { c ->
                            FilterChip(ui.selections[row.key] == c.value, { vm.select(row, c) }, label = { Text(c.name) })
                        }
                    }
                }
            }
        })
    }
}

/** 用分享链接或纯数字 ID 打开详情。 */
@Composable
fun OpenLinkDialog(onDismiss: () -> Unit, onOpenId: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    var error by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("打开链接或 ID") },
        text = {
            Column {
                OutlinedTextField(text, { text = it; error = false }, placeholder = { Text("粘贴分享链接或短剧 ID") }, isError = error)
                if (error) Text(AppError(AppError.Code.INVALID_LINK).userMessage, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelSmall)
            }
        },
        confirmButton = {
            TextButton(onClick = { SeriesLinkParser.parse(text)?.let(onOpenId) ?: run { error = true } }) { Text("打开") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

// ───────────────────────── 榜单 ─────────────────────────

@Composable
fun RankTabScreen(onOpen: (SeriesItem) -> Unit) {
    var tab by remember { mutableIntStateOf(0) }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        TabRow(selectedTabIndex = tab) {
            Tab(tab == 0, { tab = 0 }, text = { Text("榜单") })
            Tab(tab == 1, { tab = 1 }, text = { Text("上新日历") })
        }
        if (tab == 0) RankContent(onOpen) else NewReleasesContent(onOpen)
    }
}

@Composable
private fun RankContent(onOpen: (SeriesItem) -> Unit) {
    val vm = envViewModel<RankViewModel> { RankViewModel(it) }
    val ui by vm.ui.collectAsState()
    LaunchedEffect(Unit) { vm.load() }
    Column(Modifier.fillMaxSize()) {
        if (ui.contents.isNotEmpty()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(ui.contents) { c -> FilterChip(c.id == ui.content, { vm.selectContent(c.id) }, label = { Text(c.name) }) }
            }
            if (ui.boards.isNotEmpty()) {
                LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(ui.boards) { b -> FilterChip(b.id == ui.board, { vm.selectBoard(b.id) }, label = { Text(b.name) }) }
                }
            }
        }
        PagedSeriesGrid(vm.results, onOpen, emptyText = "榜单暂无数据")
    }
}

@Composable
private fun NewReleasesContent(onOpen: (SeriesItem) -> Unit) {
    val vm = envViewModel<NewReleasesViewModel> { NewReleasesViewModel(it) }
    val ui by vm.ui.collectAsState()
    val s by vm.results.state.collectAsState()
    LaunchedEffect(Unit) { vm.load() }
    Column(Modifier.fillMaxSize()) {
        if (ui.dates.isNotEmpty()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(ui.dates) { d -> FilterChip(d == ui.selected, { vm.select(d) }, label = { Text(NewReleasesViewModel.label(d)) }) }
            }
        }
        LoadStateContent(s.load, onRetry = vm.results::refresh, emptyText = "这一天没有上新") {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                itemsIndexed(s.items, key = { _, it -> it.series.id }) { i, n ->
                    LaunchedEffect(i, s.items.size) { vm.results.onItemVisible(i) }
                    Row(Modifier.fillMaxWidth().clickable { onOpen(n.series) }, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        RemoteImage(n.series.coverUrl, Modifier.width(84.dp).aspectRatio(3f / 4f).clip(RoundedCornerShape(8.dp)))
                        Column(Modifier.weight(1f)) {
                            Text(n.series.title, style = MaterialTheme.typography.titleSmall, maxLines = 2)
                            if (n.categories.isNotEmpty()) Text(n.categories.joinToString(" · "), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                            if (n.series.summary.isNotEmpty()) Text(n.series.summary, style = MaterialTheme.typography.bodySmall, maxLines = 3, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(
                                listOfNotNull(if (n.online) "已上线" else "待上线", n.note.ifEmpty { null }, n.series.badge).joinToString(" · "),
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                item {
                    Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                        val err = s.moreError
                        when {
                            s.loadingMore -> CircularProgressIndicator(Modifier.size(24.dp))
                            err != null -> TextButton(onClick = vm.results::retryLoadMore) { Text("${err.userMessage}，点击重试") }
                        }
                    }
                }
            }
        }
    }
}
