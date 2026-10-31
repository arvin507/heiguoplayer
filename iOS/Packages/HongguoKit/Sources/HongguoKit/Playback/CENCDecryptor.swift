import Foundation

/// 把 CENC 加密的 progressive MP4 就地解成 AVPlayer 能直接播的普通 MP4。
///
/// 两个步骤：
/// 1. 按 `senc` 里的 per-sample IV、用内容密钥做 AES-CTR 解密每个样本。解密等长，
///    所以 chunk 偏移、moov 大小都不用重算——这也是「音画不同步」最容易踩的坑，
///    我们干脆不碰任何偏移。
/// 2. 把 moov 里的加密信令改成等长的 `free`：
///    - `encv` / `enca` 的 sample entry 类型还原成 `sinf/frma` 记录的原始格式（hvc1 / avc1 / mp4a）
///    - `sinf`、`senc`、`saiz`、`saio`、`sgpd`、`sbgp` 的类型字符串改成 `free`
///
/// 这样输出文件与源文件逐字节对齐，只是样本变成明文、加密标记消失。
///
/// 已知限制：只支持 `cenc-aes-ctr`（Apple 的 `cbcs` / FairPlay 走不通这条路），
/// 只支持 moov 里的 senc（progressive MP4 的形态）；DASH 分片（moof/trun）不支持。
public enum CENCDecryptor {
    public struct Outcome: Sendable {
        public var data: Data
        public var sampleCount: Int
        public var trackCount: Int
    }

    public enum Failure: LocalizedError, Equatable {
        case notMP4
        case noEncryptedTrack
        case badKey(Int)
        case unsupportedScheme(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notMP4: "不是有效的 MP4 文件"
            case .noEncryptedTrack: "文件里没有找到 CENC 加密轨"
            case .badKey(let n): "内容密钥长度是 \(n) 字节，应为 16 字节"
            case .unsupportedScheme(let s): "不支持的加密方案：\(s)"
            case .malformed(let s): "MP4 结构异常：\(s)"
            }
        }
    }

    /// 服务端给的 encryption 字段是否是本解密器能处理的方案。
    public static func supports(_ encryption: String) -> Bool {
        let e = encryption.lowercased()
        if e.isEmpty { return true } // 没标方案但标了 protected，按 cenc-aes-ctr 试
        return e.contains("cenc") && e.contains("ctr") || e == "cenc"
    }

    public static func decrypt(_ input: Data, key: Data, progress: ((Double) -> Void)? = nil) throws -> Outcome {
        guard key.count == 16 else { throw Failure.badKey(key.count) }
        guard input.count >= 16 else { throw Failure.notMP4 }

        var data = input
        let top = boxes(in: data, from: 0, to: data.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw Failure.notMP4 }

        var tracks: [Track] = []
        for trak in boxes(in: data, from: moov.body, to: moov.end) where trak.type == "trak" {
            guard let mdia = child("mdia", of: trak, in: data),
                  let minf = child("minf", of: mdia, in: data),
                  let stbl = child("stbl", of: minf, in: data) else { continue }
            if let track = try parseTrack(stbl, in: data) { tracks.append(track) }
        }
        guard !tracks.isEmpty else { throw Failure.noEncryptedTrack }

        let total = tracks.reduce(0) { $0 + $1.samples.count }
        guard total > 0 else { throw Failure.noEncryptedTrack }

        var processed = 0
        for track in tracks {
            for sample in track.samples {
                if sample.size > 0 {
                    try AESCTR.xor(&data, range: sample.offset..<(sample.offset + sample.size), key: key, iv: sample.iv)
                }
                processed += 1
                if processed % 128 == 0 || processed == total {
                    progress?(Double(processed) / Double(total))
                }
            }
        }

        // 解密完再改信令，避免解析阶段读到被改写的 box。
        for patch in tracks.flatMap(\.patches) {
            writeType(&data, at: patch.offset, type: patch.type)
        }

        return Outcome(data: data, sampleCount: total, trackCount: tracks.count)
    }

    // MARK: - 单条轨

    private struct Sample {
        var offset: Int
        var size: Int
        /// 已经补齐成 16 字节的计数器初值。
        var iv: Data
    }

    private struct Patch {
        var offset: Int
        var type: String
    }

    private struct Track {
        var samples: [Sample]
        var patches: [Patch]
    }

    private static func parseTrack(_ stbl: BoxRef, in data: Data) throws -> Track? {
        let children = boxes(in: data, from: stbl.body, to: stbl.end)
        guard let stsd = children.first(where: { $0.type == "stsd" }) else { return nil }

        var patches: [Patch] = []
        var ivSize = 0
        var constantIV: Data?
        var encrypted = false

        // stsd: version/flags(4) + entry_count(4) + 每个 entry（size(4) + format(4) + ...）
        let entryCount = Int(be32(data, stsd.body + 4))
        var p = stsd.body + 8
        for _ in 0..<entryCount {
            guard p + 8 <= stsd.end else { break }
            let size = Int(be32(data, p))
            guard size >= 8, p + size <= stsd.end else { break }
            let format = typeString(data, at: p + 4)

            if format == "encv" || format == "enca" || format == "enct" || format == "encs" {
                encrypted = true
                let subStart = p + sampleEntryHeaderLength(format)
                let subs = subStart + 8 <= p + size ? boxes(in: data, from: subStart, to: p + size) : []
                // 不同封装写出来的 sample entry 头部长度不完全一致（ISO 的 VisualSampleEntry 是 86，
                // 有些封装会多写几个字节），所以定位不到就退回到在 entry 内按类型名搜索。
                if let sinf = subs.first(where: { $0.type == "sinf" }) ?? locateSinf(data, in: (p + 8)..<(p + size)) {
                    let sinfChildren = boxes(in: data, from: sinf.body, to: sinf.end)
                    // frma 记着加密前的真实格式，用它还原 sample entry。
                    if let frma = sinfChildren.first(where: { $0.type == "frma" }),
                       let original = originalFormat(data, frma) {
                        patches.append(Patch(offset: p + 4, type: original))
                    }
                    patches.append(Patch(offset: sinf.start + 4, type: "free"))
                    if let schi = sinfChildren.first(where: { $0.type == "schi" }),
                       let tenc = boxes(in: data, from: schi.body, to: schi.end).first(where: { $0.type == "tenc" }) {
                        let info = parseTenc(data, tenc)
                        if info.ivSize > 0 { ivSize = info.ivSize }
                        if let iv = info.constantIV { constantIV = iv }
                    }
                }
            }
            p += size
        }
        guard encrypted else { return nil }

        // 加密辅助 box 全部改名 free（等长，不影响偏移）。
        for name in ["senc", "saiz", "saio", "sgpd", "sbgp"] {
            for box in children where box.type == name {
                patches.append(Patch(offset: box.start + 4, type: "free"))
            }
        }

        // IV 长度优先取 saiz 的 default_sample_info_size。
        if let saiz = children.first(where: { $0.type == "saiz" }) {
            let sizes = try parseSaiz(data, saiz)
            if let first = sizes.first, first > 0 { ivSize = first }
        }
        var ivs: [Data] = []
        if let senc = children.first(where: { $0.type == "senc" }) {
            ivs = try parseSenc(data, senc, ivSize: ivSize)
        }

        guard let stsz = children.first(where: { $0.type == "stsz" }) else { return nil }
        let sizes = parseStsz(data, stsz)
        guard let chunkBox = children.first(where: { $0.type == "stco" || $0.type == "co64" }) else { return nil }
        let chunkOffsets = parseChunkOffsets(data, chunkBox)
        guard let stscBox = children.first(where: { $0.type == "stsc" }) else { return nil }
        let runs = parseStsc(data, stscBox)
        guard !sizes.isEmpty, !chunkOffsets.isEmpty, !runs.isEmpty else { return nil }

        var samples: [Sample] = []
        samples.reserveCapacity(sizes.count)
        var index = 0
        for (chunkIndex, chunkOffset) in chunkOffsets.enumerated() {
            let perChunk = samplesPerChunk(chunk: chunkIndex + 1, runs: runs)
            var offset = chunkOffset
            for _ in 0..<perChunk {
                guard index < sizes.count else { break }
                let size = sizes[index]
                guard offset >= 0, size >= 0, offset + size <= data.count else { break }
                samples.append(Sample(offset: offset, size: size,
                                      iv: counter(index: index, ivs: ivs, ivSize: ivSize, constantIV: constantIV)))
                offset += size
                index += 1
            }
            if index >= sizes.count { break }
        }
        guard !samples.isEmpty else { return nil }
        return Track(samples: samples, patches: patches)
    }

    private static func counter(index: Int, ivs: [Data], ivSize: Int, constantIV: Data?) -> Data {
        var raw = Data()
        if ivSize > 0, ivs.indices.contains(index) { raw = ivs[index] }
        else if let constantIV { raw = constantIV }
        if raw.count >= 16 { return Data(raw.prefix(16)) }
        // CENC：8 字节 per-sample IV + 8 字节块计数器（从 0 开始）。
        var out = raw
        out.append(contentsOf: [UInt8](repeating: 0, count: 16 - raw.count))
        return out
    }

    // MARK: - box 解析

    private struct BoxRef {
        let type: String
        let start: Int
        let body: Int
        let end: Int
    }

    private static func boxes(in data: Data, from: Int, to: Int) -> [BoxRef] {
        var out: [BoxRef] = []
        var p = from
        while p + 8 <= to {
            let size32 = Int(be32(data, p))
            var header = 8
            var size = size32
            if size32 == 1 {
                guard p + 16 <= to else { break }
                size = Int(be64(data, p + 8))
                header = 16
            } else if size32 == 0 {
                size = to - p
            }
            guard size >= header, p + size <= to else { break }
            out.append(BoxRef(type: typeString(data, at: p + 4), start: p, body: p + header, end: p + size))
            p += size
        }
        return out
    }

    private static func child(_ type: String, of box: BoxRef, in data: Data) -> BoxRef? {
        boxes(in: data, from: box.body, to: box.end).first { $0.type == type }
    }

    private static func typeString(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func writeType(_ data: inout Data, at offset: Int, type: String) {
        let bytes = Array(type.utf8)
        guard bytes.count == 4, offset >= 0, offset + 4 <= data.count else { return }
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
    }

    private static func originalFormat(_ data: Data, _ box: BoxRef) -> String? {
        guard box.body + 4 <= box.end else { return nil }
        let format = typeString(data, at: box.body)
        return format.isEmpty ? nil : format
    }

    /// sample entry 里子 box 的起点（含 8 字节 box 头的总长度）。
    /// ISO 14496-12 的 VisualSampleEntry 是 86 字节，AudioSampleEntry v0 是 32 字节。
    private static func sampleEntryHeaderLength(_ format: String) -> Int {
        switch format {
        case "encv", "avc1", "avc3", "hvc1", "hev1", "mp4v", "vp09", "av01":
            86
        case "enca", "mp4a", "ac-3", "ec-3", "alac", "Opus":
            32
        default:
            8
        }
    }

    /// 在 sample entry 范围内按类型名找 sinf，并校验 box 头自洽。
    /// 用于 header 长度与预期不一致时兜底。
    private static func locateSinf(_ data: Data, in range: Range<Int>) -> BoxRef? {
        let marker = Data("sinf".utf8)
        var searchStart = range.lowerBound
        while searchStart + 8 <= range.upperBound {
            guard let found = data.range(of: marker, in: searchStart..<range.upperBound) else { return nil }
            let boxStart = found.lowerBound - 4
            if boxStart >= range.lowerBound {
                let size = Int(be32(data, boxStart))
                if size >= 8, boxStart + size <= range.upperBound {
                    return BoxRef(type: "sinf", start: boxStart, body: found.upperBound, end: boxStart + size)
                }
            }
            searchStart = found.upperBound
        }
        return nil
    }

    private static func parseTenc(_ data: Data, _ box: BoxRef) -> (ivSize: Int, constantIV: Data?) {
        let p = box.body
        // version/flags(4) + reserved(1) + crypt/skip(1) + isProtected(1) + ivSize(1) + KID(16)
        guard p + 24 <= box.end else { return (0, nil) }
        let ivSize = Int(data[p + 7])
        guard ivSize == 0 else { return (ivSize, nil) }
        guard p + 25 <= box.end else { return (0, nil) }
        let length = Int(data[p + 24])
        guard length > 0, p + 25 + length <= box.end else { return (0, nil) }
        return (0, data.subdata(in: (p + 25)..<(p + 25 + length)))
    }

    private static func parseSaiz(_ data: Data, _ box: BoxRef) throws -> [Int] {
        let p = box.body
        guard p + 5 <= box.end else { throw Failure.malformed("saiz 过短") }
        let flags = Int(data[p + 1]) << 16 | Int(data[p + 2]) << 8 | Int(data[p + 3])
        var q = p + 4
        if flags & 1 != 0 { q += 8 } // aux_info_type + aux_info_type_parameter
        guard q + 5 <= box.end else { throw Failure.malformed("saiz 缺少字段") }
        let defaultSize = Int(data[q])
        let count = Int(be32(data, q + 1))
        if defaultSize != 0 { return [Int](repeating: defaultSize, count: count) }

        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        var r = q + 5
        for _ in 0..<count {
            guard r < box.end else { break }
            sizes.append(Int(data[r]))
            r += 1
        }
        return sizes
    }

    private static func parseSenc(_ data: Data, _ box: BoxRef, ivSize: Int) throws -> [Data] {
        let p = box.body
        guard p + 8 <= box.end else { throw Failure.malformed("senc 过短") }
        let flags = Int(data[p + 1]) << 16 | Int(data[p + 2]) << 8 | Int(data[p + 3])
        let count = Int(be32(data, p + 4))
        let hasSubsamples = (flags & 0x2) != 0

        var ivs: [Data] = []
        ivs.reserveCapacity(count)
        var q = p + 8
        for _ in 0..<count {
            if ivSize > 0 {
                guard q + ivSize <= box.end else { break }
                ivs.append(data.subdata(in: q..<(q + ivSize)))
                q += ivSize
            }
            if hasSubsamples {
                guard q + 2 <= box.end else { break }
                let n = Int(be16(data, q))
                q += 2 + n * 6
            }
        }
        return ivs
    }

    private static func parseStsz(_ data: Data, _ box: BoxRef) -> [Int] {
        let p = box.body
        guard p + 12 <= box.end else { return [] }
        let fixed = Int(be32(data, p + 4))
        let count = Int(be32(data, p + 8))
        if fixed != 0 { return [Int](repeating: fixed, count: count) }

        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        var q = p + 12
        for _ in 0..<count {
            guard q + 4 <= box.end else { break }
            sizes.append(Int(be32(data, q)))
            q += 4
        }
        return sizes
    }

    private static func parseChunkOffsets(_ data: Data, _ box: BoxRef) -> [Int] {
        let p = box.body
        guard p + 8 <= box.end else { return [] }
        let count = Int(be32(data, p + 4))
        let wide = box.type == "co64"
        var out: [Int] = []
        out.reserveCapacity(count)
        var q = p + 8
        for _ in 0..<count {
            if wide {
                guard q + 8 <= box.end else { break }
                out.append(Int(be64(data, q)))
                q += 8
            } else {
                guard q + 4 <= box.end else { break }
                out.append(Int(be32(data, q)))
                q += 4
            }
        }
        return out
    }

    private static func parseStsc(_ data: Data, _ box: BoxRef) -> [(first: Int, count: Int)] {
        let p = box.body
        guard p + 8 <= box.end else { return [] }
        let n = Int(be32(data, p + 4))
        var runs: [(first: Int, count: Int)] = []
        runs.reserveCapacity(n)
        var q = p + 8
        for _ in 0..<n {
            guard q + 12 <= box.end else { break }
            runs.append((Int(be32(data, q)), Int(be32(data, q + 4))))
            q += 12
        }
        return runs
    }

    /// chunk 是 1-based；stsc 的条目对后续所有 chunk 生效，直到下一条目的 first_chunk。
    private static func samplesPerChunk(chunk: Int, runs: [(first: Int, count: Int)]) -> Int {
        var result = 0
        for run in runs {
            if chunk < run.first { break }
            result = run.count
        }
        return result
    }

    // MARK: - 读取整数

    private static func be16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(data[offset + i]) }
        return value
    }
}
