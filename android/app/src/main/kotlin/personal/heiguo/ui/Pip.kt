package personal.heiguo.ui

import android.util.Rational
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 小窗（画中画）状态，Activity 和界面之间共享。
 * - enabled：当前有视频在播，按 Home 键时允许进入小窗；
 * - inPip：已经在小窗里，界面只显示视频；
 * - aspect：小窗的宽高比，跟随视频。
 */
object PipState {
    val enabled = MutableStateFlow(false)
    val inPip = MutableStateFlow(false)
    val aspect = MutableStateFlow(Rational(9, 16))

    /** 系统只接受 1:2.39 到 2.39:1 之间的宽高比。 */
    fun clamp(w: Int, h: Int): Rational {
        if (w <= 0 || h <= 0) return Rational(9, 16)
        val r = w.toDouble() / h
        return when {
            r > 2.39 -> Rational(239, 100)
            r < 1 / 2.39 -> Rational(100, 239)
            else -> Rational(w, h)
        }
    }
}

/** 有视频在播时允许进入小窗，并让小窗宽高比跟随视频。 */
@Composable
fun PipEffect(player: ExoPlayer, active: Boolean) {
    DisposableEffect(player, active) {
        if (!active) return@DisposableEffect onDispose { }
        PipState.enabled.value = true
        val size = player.videoSize
        if (size.width > 0) PipState.aspect.value = PipState.clamp(size.width, size.height)
        val l = object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                PipState.aspect.value = PipState.clamp(videoSize.width, videoSize.height)
            }
        }
        player.addListener(l)
        onDispose {
            player.removeListener(l)
            PipState.enabled.value = false
        }
    }
}
