package personal.heiguo.domain

data class QualityOption(val height: Int, val label: String)

/** 清晰度的选项与选择规则（纯函数，方便测试）。 */
object Quality {
    fun label(s: StreamInfo): String =
        s.definition.ifEmpty { if (s.height > 0) "${s.height}p" else "默认" }

    /** 可选的清晰度：按高度去重（同一高度取排在前面的，也就是码率更高的那条），从高到低。 */
    fun options(streams: List<StreamInfo>): List<QualityOption> =
        streams.filter { it.height > 0 }.distinctBy { it.height }.sortedByDescending { it.height }
            .map { QualityOption(it.height, label(it)) }

    /**
     * 选一条流。preferredHeight 为 0（没选过）时用默认规则；
     * 否则优先同高度，其次不超过它的最高一档，再不行就取最低的一档。
     */
    fun pick(info: PlaybackInfo, preferredHeight: Int): StreamInfo? {
        val list = info.streams
        if (list.isEmpty()) return null
        if (preferredHeight <= 0) return info.preferredStream
        return list.firstOrNull { it.height == preferredHeight }
            ?: list.filter { it.height in 1..preferredHeight }.maxByOrNull { it.height }
            ?: list.filter { it.height > 0 }.minByOrNull { it.height }
            ?: list.first()
    }
}
