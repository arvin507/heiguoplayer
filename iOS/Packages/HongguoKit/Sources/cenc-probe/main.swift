import Foundation
import HongguoKit

// 诊断工具：把一个 CENC 加密的 mp4 解成明文，用来核对解密器。
//   cenc-probe <加密 mp4> <32 位 hex 内容密钥> [输出文件]
// 只读本地文件，不走网络，不需要 Xcode。

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("用法：cenc-probe <加密 mp4> <32 位 hex 内容密钥> [输出文件]")
    exit(1)
}

let input = URL(fileURLWithPath: args[0])
guard let key = ContentKey(hex: args[1]).keyData else {
    print("密钥格式不对：需要 32 个十六进制字符（16 字节）")
    exit(1)
}

do {
    let data = try Data(contentsOf: input)
    let started = Date()
    var lastReported = 0
    let outcome = try CENCDecryptor.decrypt(data, key: key) { fraction in
        let percent = Int(fraction * 100)
        if percent >= lastReported + 25 || percent == 100 {
            lastReported = percent
            print("  解密 \(percent)%")
        }
    }
    let output = URL(fileURLWithPath: args.count > 2 ? args[2] : input.path + ".dec.mp4")
    try outcome.data.write(to: output)
    let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
    print("轨数=\(outcome.trackCount) 样本=\(outcome.sampleCount) 输出=\(outcome.data.count) 字节 用时=\(seconds)s")
    print("已写入：\(output.path)")
} catch {
    print("失败：\(error.localizedDescription)")
    exit(2)
}
