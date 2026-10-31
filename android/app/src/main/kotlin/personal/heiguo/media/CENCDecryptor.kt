package personal.heiguo.media

import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 把 CENC 加密的 progressive MP4 就地解成 ExoPlayer 能直接播的普通 MP4。
 *
 * 两个步骤：
 * 1. 按 `senc` 里的 per-sample IV、用内容密钥做 AES-128-CTR 解密每个样本。解密等长，
 *    所以 chunk 偏移、moov 大小都不用重算——「音画不同步」最容易踩的坑就在这里，我们干脆不碰任何偏移。
 * 2. 把 moov 里的加密信令改成等长的 `free`：
 *    - `encv` / `enca` 的 sample entry 类型还原成 `sinf/frma` 记录的原始格式（hvc1 / avc1 / mp4a）
 *    - `sinf`、`senc`、`saiz`、`saio`、`sgpd`、`sbgp` 的类型字符串改成 `free`
 *
 * 这样输出与源文件逐字节对齐，只是样本变成明文、加密标记消失。
 *
 * 已知限制：只支持 `cenc-aes-ctr`（`cbcs` / Widevine 的 pattern 加密走不通这条路），
 * 只支持 moov 里的 senc（progressive MP4 的形态）；DASH 分片（moof/trun）不支持。
 *
 * 注意：`decrypt` 会**原地改写**传入的数组（省一次几十 MB 的拷贝），调用方传进来的
 * 必须是自己独占的临时数据。
 */
object CENCDecryptor {

    class Outcome(val data: ByteArray, val sampleCount: Int, val trackCount: Int)

    class Failure(message: String) : Exception(message)

    /** 服务端给的 encryption 字段是否是本解密器能处理的方案。 */
    fun supports(encryption: String): Boolean {
        val e = encryption.trim().lowercase()
        if (e.isEmpty()) return true // 没标方案但标了 protected，按 cenc-aes-ctr 试
        return (e.contains("cenc") && e.contains("ctr")) || e == "cenc"
    }

    fun decrypt(input: ByteArray, key: ByteArray, progress: ((Float) -> Unit)? = null): Outcome {
        if (key.size != 16) throw Failure("内容密钥长度是 ${key.size} 字节，应为 16 字节")
        if (input.size < 16) throw Failure("不是有效的 MP4 文件")

        val data = input
        val moov = boxes(data, 0, data.size).firstOrNull { it.type == "moov" }
            ?: throw Failure("不是有效的 MP4 文件")

        val tracks = ArrayList<Track>(2)
        for (trak in boxes(data, moov.body, moov.end)) {
            if (trak.type != "trak") continue
            val mdia = child("mdia", trak, data) ?: continue
            val minf = child("minf", mdia, data) ?: continue
            val stbl = child("stbl", minf, data) ?: continue
            parseTrack(stbl, data)?.let { tracks.add(it) }
        }
        if (tracks.isEmpty()) throw Failure("文件里没有找到 CENC 加密轨")

        var total = 0
        var maxSample = 1
        for (track in tracks) {
            total += track.samples.size
            for (sample in track.samples) if (sample.size > maxSample) maxSample = sample.size
        }
        if (total == 0) throw Failure("文件里没有找到 CENC 加密轨")

        val cipher = try {
            Cipher.getInstance("AES/CTR/NoPadding")
        } catch (e: GeneralSecurityException) {
            throw Failure("设备不支持 AES-CTR：${e.message}")
        }
        val keySpec = SecretKeySpec(key, "AES")
        // 每个样本都重新 init（IV 不同），复用一个足够大的输出缓冲避免逐样本分配。
        val scratch = ByteArray(maxSample)

        var processed = 0
        for (track in tracks) {
            for (sample in track.samples) {
                if (sample.size > 0) {
                    try {
                        cipher.init(Cipher.DECRYPT_MODE, keySpec, IvParameterSpec(sample.iv))
                        val n = cipher.doFinal(data, sample.offset, sample.size, scratch, 0)
                        System.arraycopy(scratch, 0, data, sample.offset, n)
                    } catch (e: GeneralSecurityException) {
                        throw Failure("解密样本失败（偏移 ${sample.offset}）：${e.message}")
                    }
                }
                processed++
                if (processed % 128 == 0 || processed == total) {
                    progress?.invoke(processed.toFloat() / total)
                }
            }
        }

        // 解密完再改信令，避免解析阶段读到被改写的 box。
        for (track in tracks) for (patch in track.patches) writeType(data, patch.offset, patch.type)

        return Outcome(data, total, tracks.size)
    }

    // ───────────────────────── 单条轨 ─────────────────────────

    private class Sample(val offset: Int, val size: Int, val iv: ByteArray)

    private class Patch(val offset: Int, val type: String)

    private class Track(val samples: List<Sample>, val patches: List<Patch>)

    private fun parseTrack(stbl: BoxRef, data: ByteArray): Track? {
        val children = boxes(data, stbl.body, stbl.end)
        val stsd = children.firstOrNull { it.type == "stsd" } ?: return null

        val patches = ArrayList<Patch>(8)
        var ivSize = 0
        var constantIv: ByteArray? = null
        var encrypted = false

        // stsd: version/flags(4) + entry_count(4) + 每个 entry（size(4) + format(4) + ...）
        val entryCount = be32(data, stsd.body + 4)
        var p = stsd.body + 8
        for (i in 0 until entryCount) {
            if (p + 8 > stsd.end) break
            val size = be32(data, p)
            if (size < 8 || p + size > stsd.end) break
            val format = typeString(data, p + 4)

            if (format == "encv" || format == "enca" || format == "enct" || format == "encs") {
                encrypted = true
                val subStart = p + sampleEntryHeaderLength(format)
                val subs = if (subStart + 8 <= p + size) boxes(data, subStart, p + size) else emptyList()
                // 不同封装写出来的 sample entry 头部长度不完全一致（ISO 的 VisualSampleEntry 是 86 字节），
                // 所以按标准长度定位不到时，退回到在 entry 范围内按类型名搜索。
                val sinf = subs.firstOrNull { it.type == "sinf" } ?: locateSinf(data, p + 8, p + size)
                if (sinf != null) {
                    val sinfChildren = boxes(data, sinf.body, sinf.end)
                    // frma 记着加密前的真实格式，用它还原 sample entry。
                    val frma = sinfChildren.firstOrNull { it.type == "frma" }
                    val original = frma?.let { originalFormat(data, it) }
                    if (original != null) patches.add(Patch(p + 4, original))
                    patches.add(Patch(sinf.start + 4, "free"))
                    val tenc = sinfChildren.firstOrNull { it.type == "schi" }
                        ?.let { schi -> boxes(data, schi.body, schi.end).firstOrNull { it.type == "tenc" } }
                    if (tenc != null) {
                        val info = parseTenc(data, tenc)
                        if (info.ivSize > 0) ivSize = info.ivSize
                        info.constantIv?.let { constantIv = it }
                    }
                }
            }
            p += size
        }
        if (!encrypted) return null

        // 加密辅助 box 全部改名 free（等长，不影响偏移）。
        for (name in listOf("senc", "saiz", "saio", "sgpd", "sbgp")) {
            for (box in children) if (box.type == name) patches.add(Patch(box.start + 4, "free"))
        }

        // IV 长度优先取 saiz 的 default_sample_info_size。
        val saiz = children.firstOrNull { it.type == "saiz" }
        if (saiz != null) {
            val sizes = parseSaiz(data, saiz)
            val first = sizes.firstOrNull() ?: 0
            if (first > 0) ivSize = first
        }
        val senc = children.firstOrNull { it.type == "senc" }
        val ivs = if (senc != null) parseSenc(data, senc, ivSize) else emptyList()

        val stsz = children.firstOrNull { it.type == "stsz" } ?: return null
        val sizes = parseStsz(data, stsz)
        val chunkBox = children.firstOrNull { it.type == "stco" || it.type == "co64" } ?: return null
        val chunkOffsets = parseChunkOffsets(data, chunkBox)
        val stscBox = children.firstOrNull { it.type == "stsc" } ?: return null
        val runs = parseStsc(data, stscBox)
        if (sizes.isEmpty() || chunkOffsets.isEmpty() || runs.isEmpty()) return null

        val samples = ArrayList<Sample>(sizes.size)
        var index = 0
        for (c in chunkOffsets.indices) {
            val perChunk = samplesPerChunk(c + 1, runs)
            var offset = chunkOffsets[c]
            for (k in 0 until perChunk) {
                if (index >= sizes.size) break
                val size = sizes[index]
                if (offset < 0 || size < 0 || offset.toLong() + size > data.size) break
                samples.add(Sample(offset, size, counter(index, ivs, ivSize, constantIv)))
                offset += size
                index++
            }
            if (index >= sizes.size) break
        }
        if (samples.isEmpty()) return null
        return Track(samples, patches)
    }

    /** 补齐成 16 字节的计数器初值。 */
    private fun counter(index: Int, ivs: List<ByteArray>, ivSize: Int, constantIv: ByteArray?): ByteArray {
        val raw = if (ivSize > 0 && index < ivs.size) ivs[index] else constantIv ?: ByteArray(0)
        if (raw.size >= 16) return raw.copyOf(16)
        // CENC：8 字节 per-sample IV + 8 字节块计数器（从 0 开始），拼起来正好是 CTR 的 16 字节初值。
        return raw.copyOf(16)
    }

    // ───────────────────────── box 解析 ─────────────────────────

    private class BoxRef(val type: String, val start: Int, val body: Int, val end: Int)

    private fun boxes(data: ByteArray, from: Int, to: Int): List<BoxRef> {
        val out = ArrayList<BoxRef>(8)
        var p = from
        while (p + 8 <= to) {
            val size32 = be32(data, p)
            var header = 8
            var size = size32
            if (size32 == 1) {
                if (p + 16 > to) break
                val wide = be64(data, p + 8)
                if (wide < 16 || wide > Int.MAX_VALUE || p + wide > to) break
                size = wide.toInt()
                header = 16
            } else if (size32 == 0) {
                size = to - p
            }
            if (size < header || p + size > to) break
            out.add(BoxRef(typeString(data, p + 4), p, p + header, p + size))
            p += size
        }
        return out
    }

    private fun child(type: String, of: BoxRef, data: ByteArray): BoxRef? =
        boxes(data, of.body, of.end).firstOrNull { it.type == type }

    private fun typeString(data: ByteArray, offset: Int): String {
        if (offset < 0 || offset + 4 > data.size) return ""
        return String(data, offset, 4, Charsets.ISO_8859_1)
    }

    private fun writeType(data: ByteArray, offset: Int, type: String) {
        if (type.length != 4 || offset < 0 || offset + 4 > data.size) return
        for (i in 0 until 4) data[offset + i] = type[i].code.toByte()
    }

    private fun originalFormat(data: ByteArray, box: BoxRef): String? {
        if (box.body + 4 > box.end) return null
        val format = typeString(data, box.body)
        return format.ifEmpty { null }
    }

    /**
     * sample entry 里子 box 的起点（含 8 字节 box 头的总长度）。
     * ISO 14496-12 的 VisualSampleEntry 是 86 字节，AudioSampleEntry v0 是 32 字节。
     */
    private fun sampleEntryHeaderLength(format: String): Int = when (format) {
        "encv", "avc1", "avc3", "hvc1", "hev1", "mp4v", "vp09", "av01" -> 86
        "enca", "mp4a", "ac-3", "ec-3", "alac", "Opus" -> 32
        else -> 8
    }

    /** 在 sample entry 范围内按类型名找 sinf，并校验 box 头自洽。用于 header 长度与预期不一致时兜底。 */
    private fun locateSinf(data: ByteArray, from: Int, to: Int): BoxRef? {
        var i = from
        while (i + 4 <= to) {
            if (data[i] == 's'.code.toByte() && data[i + 1] == 'i'.code.toByte() &&
                data[i + 2] == 'n'.code.toByte() && data[i + 3] == 'f'.code.toByte()
            ) {
                val boxStart = i - 4
                if (boxStart >= from) {
                    val size = be32(data, boxStart)
                    if (size >= 8 && boxStart + size <= to) {
                        return BoxRef("sinf", boxStart, i + 4, boxStart + size)
                    }
                }
            }
            i++
        }
        return null
    }

    private class TencInfo(val ivSize: Int, val constantIv: ByteArray?)

    private fun parseTenc(data: ByteArray, box: BoxRef): TencInfo {
        val p = box.body
        // version/flags(4) + reserved(1) + crypt/skip(1) + isProtected(1) + ivSize(1) + KID(16)
        if (p + 24 > box.end) return TencInfo(0, null)
        val ivSize = data[p + 7].toInt() and 0xFF
        if (ivSize != 0) return TencInfo(ivSize, null)
        if (p + 25 > box.end) return TencInfo(0, null)
        val length = data[p + 24].toInt() and 0xFF
        if (length <= 0 || p + 25 + length > box.end) return TencInfo(0, null)
        return TencInfo(0, data.copyOfRange(p + 25, p + 25 + length))
    }

    private fun parseSaiz(data: ByteArray, box: BoxRef): List<Int> {
        val p = box.body
        if (p + 5 > box.end) return emptyList()
        val flags = ((data[p + 1].toInt() and 0xFF) shl 16) or
            ((data[p + 2].toInt() and 0xFF) shl 8) or (data[p + 3].toInt() and 0xFF)
        var q = p + 4
        if (flags and 1 != 0) q += 8 // aux_info_type + aux_info_type_parameter
        if (q + 5 > box.end) return emptyList()
        val defaultSize = data[q].toInt() and 0xFF
        val count = be32(data, q + 1).coerceAtLeast(0)
        if (defaultSize != 0) return List(count) { defaultSize }

        val sizes = ArrayList<Int>(count.coerceAtLeast(0))
        var r = q + 5
        for (i in 0 until count) {
            if (r >= box.end) break
            sizes.add(data[r].toInt() and 0xFF)
            r++
        }
        return sizes
    }

    private fun parseSenc(data: ByteArray, box: BoxRef, ivSize: Int): List<ByteArray> {
        val p = box.body
        if (p + 8 > box.end) return emptyList()
        val flags = ((data[p + 1].toInt() and 0xFF) shl 16) or
            ((data[p + 2].toInt() and 0xFF) shl 8) or (data[p + 3].toInt() and 0xFF)
        val count = be32(data, p + 4)
        val hasSubsamples = flags and 0x2 != 0

        val ivs = ArrayList<ByteArray>(count.coerceAtLeast(0))
        var q = p + 8
        for (i in 0 until count) {
            if (ivSize > 0) {
                if (q + ivSize > box.end) break
                ivs.add(data.copyOfRange(q, q + ivSize))
                q += ivSize
            }
            if (hasSubsamples) {
                if (q + 2 > box.end) break
                val n = be16(data, q)
                q += 2 + n * 6
            }
        }
        return ivs
    }

    private fun parseStsz(data: ByteArray, box: BoxRef): List<Int> {
        val p = box.body
        if (p + 12 > box.end) return emptyList()
        val fixed = be32(data, p + 4)
        val count = be32(data, p + 8)
        if (fixed != 0) return IntArray(count.coerceAtLeast(0)) { fixed }.toList()

        val sizes = ArrayList<Int>(count.coerceAtLeast(0))
        var q = p + 12
        for (i in 0 until count) {
            if (q + 4 > box.end) break
            sizes.add(be32(data, q))
            q += 4
        }
        return sizes
    }

    private fun parseChunkOffsets(data: ByteArray, box: BoxRef): IntArray {
        val p = box.body
        if (p + 8 > box.end) return IntArray(0)
        val count = be32(data, p + 4)
        val wide = box.type == "co64"
        val out = ArrayList<Int>(count.coerceAtLeast(0))
        var q = p + 8
        for (i in 0 until count) {
            if (wide) {
                if (q + 8 > box.end) break
                val v = be64(data, q)
                if (v > Int.MAX_VALUE) break
                out.add(v.toInt())
                q += 8
            } else {
                if (q + 4 > box.end) break
                out.add(be32(data, q))
                q += 4
            }
        }
        return out.toIntArray()
    }

    private class StscRun(val first: Int, val count: Int)

    private fun parseStsc(data: ByteArray, box: BoxRef): List<StscRun> {
        val p = box.body
        if (p + 8 > box.end) return emptyList()
        val n = be32(data, p + 4)
        val runs = ArrayList<StscRun>(n.coerceAtLeast(0))
        var q = p + 8
        for (i in 0 until n) {
            if (q + 12 > box.end) break
            runs.add(StscRun(be32(data, q), be32(data, q + 4)))
            q += 12
        }
        return runs
    }

    /** chunk 是 1-based；stsc 的条目对后续所有 chunk 生效，直到下一条目的 first_chunk。 */
    private fun samplesPerChunk(chunk: Int, runs: List<StscRun>): Int {
        var result = 0
        for (run in runs) {
            if (chunk < run.first) break
            result = run.count
        }
        return result
    }

    // ───────────────────────── 读整数（大端） ─────────────────────────

    private fun be16(data: ByteArray, offset: Int): Int {
        if (offset < 0 || offset + 2 > data.size) return 0
        return ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
    }

    private fun be32(data: ByteArray, offset: Int): Int {
        if (offset < 0 || offset + 4 > data.size) return 0
        return ((data[offset].toInt() and 0xFF) shl 24) or
            ((data[offset + 1].toInt() and 0xFF) shl 16) or
            ((data[offset + 2].toInt() and 0xFF) shl 8) or
            (data[offset + 3].toInt() and 0xFF)
    }

    private fun be64(data: ByteArray, offset: Int): Long {
        if (offset < 0 || offset + 8 > data.size) return 0
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (data[offset + i].toLong() and 0xFF)
        return v
    }
}
