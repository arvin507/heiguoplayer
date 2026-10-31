package personal.heiguo

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.combine
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import kotlinx.coroutines.launch
import personal.heiguo.ui.*

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            HeiguoTheme { AppRoot() }
        }
        // 有视频在播（或视频宽高比变化）时更新小窗参数；Android 12+ 回到桌面会自动进入小窗。
        lifecycleScope.launch {
            combine(PipState.enabled, PipState.aspect) { _, _ -> }.collect {
                runCatching { setPictureInPictureParams(pipParams()) }
            }
        }
    }

    private fun pipParams(): PictureInPictureParams =
        PictureInPictureParams.Builder().apply {
            setAspectRatio(PipState.aspect.value)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setAutoEnterEnabled(PipState.enabled.value)
                setSeamlessResizeEnabled(false)
            }
        }.build()

    /** Android 12 以下没有自动进入，按 Home 键时手动进入小窗。 */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && PipState.enabled.value) {
            runCatching { enterPictureInPictureMode(pipParams()) }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        PipState.inPip.value = isInPictureInPictureMode
    }
}

private enum class Tab(val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Feed("推荐", Icons.Default.PlayArrow), Find("找剧", Icons.Default.Search),
    Rank("榜单", Icons.Default.Star), Mine("我的", Icons.Default.Person),
}

@Composable
private fun AppRoot() {
    val nav = rememberNavController()
    val env = rememberEnv()
    val checker = remember { FollowUpdateChecker(env) }

    // 打开 App、回到前台时检查追更剧是否有新集（最多每 10 分钟一次）
    val owner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_START) scope.launch { runCatching { checker.checkIfNeeded() } }
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    // 首次启动（或声明更新后）必须先阅读免责声明
    var needsDisclaimer by remember { mutableStateOf(env.acceptedDisclaimerVersion < Disclaimer.VERSION) }
    if (needsDisclaimer) {
        DisclaimerDialog(requireAccept = true) {
            env.acceptedDisclaimerVersion = Disclaimer.VERSION
            needsDisclaimer = false
        }
    }

    NavHost(nav, startDestination = "main") {
        composable("main") {
            MainTabs(
                onOpen = { nav.navigate("detail/${it.id}") },
                onOpenId = { nav.navigate("detail/$it") },
                onPlay = { id, n, at -> nav.navigate("player/$id?ep=$n&at=$at") },
            )
        }
        composable("detail/{id}", arguments = listOf(navArgument("id") { type = NavType.StringType })) { e ->
            val id = e.arguments!!.getString("id")!!
            SeriesDetailScreen(id, onBack = { nav.popBackStack() }, onPlay = { n, at -> nav.navigate("player/$id?ep=$n&at=$at") })
        }
        composable(
            "player/{id}?ep={ep}&at={at}",
            arguments = listOf(
                navArgument("id") { type = NavType.StringType },
                navArgument("ep") { type = NavType.IntType; defaultValue = 1 },
                navArgument("at") { type = NavType.FloatType; defaultValue = -1f },
            ),
        ) { e ->
            val a = e.arguments!!
            PlayerScreen(a.getString("id")!!, a.getInt("ep"), a.getFloat("at").toDouble(), onBack = { nav.popBackStack() })
        }
    }
}

@Composable
private fun MainTabs(onOpen: (personal.heiguo.domain.SeriesItem) -> Unit, onOpenId: (String) -> Unit, onPlay: (String, Int, Double) -> Unit) {
    var tab by rememberSaveable { mutableStateOf(Tab.Feed) }
    val inPip by PipState.inPip.collectAsState()
    Scaffold(
        bottomBar = {
            if (!inPip) NavigationBar {
                Tab.entries.forEach { t ->
                    NavigationBarItem(selected = tab == t, onClick = { tab = t }, icon = { Icon(t.icon, t.label) }, label = { Text(t.label) })
                }
            }
        },
        contentWindowInsets = WindowInsets(0),
    ) { pad ->
        Box(Modifier.padding(bottom = pad.calculateBottomPadding())) {
            when (tab) {
                Tab.Feed -> FeedScreen(onOpenDetail = onOpen)
                Tab.Find -> FindScreen(onOpen, onOpenId)
                Tab.Rank -> RankTabScreen(onOpen)
                Tab.Mine -> LibraryScreen(onOpenId, onPlay)
            }
        }
    }
}
