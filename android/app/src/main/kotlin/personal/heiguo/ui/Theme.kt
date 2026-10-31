package personal.heiguo.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Accent = Color(0xFFE5322D)

private val Dark = darkColorScheme(
    primary = Accent, onPrimary = Color.White,
    background = Color(0xFF0E0E0E), surface = Color(0xFF161616), surfaceVariant = Color(0xFF262626),
)
private val Light = lightColorScheme(primary = Accent, onPrimary = Color.White)

@Composable
fun HeiguoTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}
