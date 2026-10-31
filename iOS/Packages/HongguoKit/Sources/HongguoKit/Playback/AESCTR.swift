import CommonCrypto
import Foundation

/// AES-CTR。CENC 的 "cenc-aes-ctr" 就是 AES-128 的 CTR 模式。
///
/// CommonCrypto 的 CTR 把整个 16 字节 IV 当成大端计数器递增；CENC 的定义是
/// 「8 字节 per-sample IV + 8 字节块计数器从 0 开始」。两者等价：一个样本最多几十 KB，
/// 低 8 字节不可能进位到高 8 字节。
enum AESCTR {
    enum Failure: LocalizedError {
        case invalidKey(Int)
        case invalidIV(Int)
        case cryptor(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let n): "AES 密钥长度 \(n) 不受支持（应为 16/24/32 字节）"
            case .invalidIV(let n): "AES-CTR 的 IV 长度为 \(n)，应为 16 字节"
            case .cryptor(let status): "AES-CTR 失败（CCCryptorStatus \(status)）"
            }
        }
    }

    /// 原地 XOR `range` 这一段字节。CTR 是流模式，加解密是同一个操作。
    static func xor(_ data: inout Data, range: Range<Int>, key: Data, iv: Data) throws {
        guard [16, 24, 32].contains(key.count) else { throw Failure.invalidKey(key.count) }
        guard iv.count == 16 else { throw Failure.invalidIV(iv.count) }
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= data.count else { return }

        var cryptor: CCCryptorRef?
        let created: CCCryptorStatus = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw Failure.cryptor(created) }
        defer { CCCryptorRelease(cryptor) }

        let length = range.count
        // no-padding 时输出长度等于输入长度；多留一个块以防实现差异。
        var output = [UInt8](repeating: 0, count: length + 16)
        var moved = 0
        let status: CCCryptorStatus = data.withUnsafeMutableBytes { raw -> CCCryptorStatus in
            guard let base = raw.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return output.withUnsafeMutableBytes { out -> CCCryptorStatus in
                CCCryptorUpdate(cryptor, base.advanced(by: range.lowerBound), length,
                                out.baseAddress, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw Failure.cryptor(status) }
        guard moved > 0 else { return }

        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            output.withUnsafeBytes { src in
                guard let from = src.baseAddress else { return }
                memcpy(base.advanced(by: range.lowerBound), from, moved)
            }
        }
    }
}
