package personal.heiguo.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties

/** 免责声明文案（与 iOS 一致）。改动文案时递增 VERSION，已经同意过旧版本的用户会再弹一次。 */
object Disclaimer {
    const val VERSION = 1
    const val TITLE = "免责声明"
    val items = listOf(
        "本 App 是个人学习项目，仅用于学习和技术研究，不得用于任何商业用途。",
        "本 App 不提供、不上传、不对外分发任何视频内容。内容均来自第三方服务，版权归原权利人所有；解密后的内容只缓存在你自己的设备上。",
        "本 App 与红果短剧及其运营方没有任何关联，不代表其立场；相关名称和商标归其所有者所有。",
        "请遵守所在地的法律法规和相关服务条款。因使用本 App 产生的一切后果由使用者自行承担，作者不承担任何责任。",
    )
    const val REMOVAL_REMINDER =
        "删除提醒：本项目仅供学习交流，请在使用后 24 小时内删除本 App 及缓存的全部内容。如权利人认为内容侵权，请联系删除。"
}

/**
 * 免责声明对话框。首次启动时 requireAccept 为 true：不能点外面或按返回键关闭，必须点“我已阅读”；
 * 在“我的”里查看时只有“关闭”。
 */
@Composable
fun DisclaimerDialog(requireAccept: Boolean, onClose: () -> Unit) {
    AlertDialog(
        onDismissRequest = { if (!requireAccept) onClose() },
        properties = DialogProperties(dismissOnBackPress = !requireAccept, dismissOnClickOutside = !requireAccept),
        title = { Text(Disclaimer.TITLE) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Disclaimer.items.forEachIndexed { i, t -> Text("${i + 1}. $t", style = MaterialTheme.typography.bodyMedium) }
                Text(
                    Disclaimer.REMOVAL_REMINDER,
                    fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.fillMaxWidth().background(Color(0x26FF9800), RoundedCornerShape(10.dp)).padding(12.dp),
                )
            }
        },
        confirmButton = { TextButton(onClick = onClose) { Text(if (requireAccept) "我已阅读" else "关闭") } },
    )
}
