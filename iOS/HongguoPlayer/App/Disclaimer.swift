import SwiftUI

/// 免责声明文案。改动文案时递增 version，已经同意过旧版本的用户会再弹一次。
enum Disclaimer {
    static let version = 1
    static let title = "免责声明"
    static let items: [String] = [
        "本 App 是个人学习项目，仅用于学习和技术研究，不得用于任何商业用途。",
        "本 App 不提供、不上传、不对外分发任何视频内容。内容均来自第三方服务，版权归原权利人所有；解密后的内容只缓存在你自己的设备上。",
        "本 App 与红果短剧及其运营方没有任何关联，不代表其立场；相关名称和商标归其所有者所有。",
        "请遵守所在地的法律法规和相关服务条款。因使用本 App 产生的一切后果由使用者自行承担，作者不承担任何责任。",
    ]
    static let removalReminder = "删除提醒：本项目仅供学习交流，请在使用后 24 小时内删除本 App 及缓存的全部内容。如权利人认为内容侵权，请联系删除。"
}

/// 免责声明。首次启动时 requireAccept 为 true，必须点“我已阅读”才能进入；在“我的”里查看时只有“关闭”。
struct DisclaimerView: View {
    var requireAccept: Bool
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(Disclaimer.items.enumerated()), id: \.offset) { i, text in
                        Text("\(i + 1). \(text)")
                    }
                    Text(Disclaimer.removalReminder)
                        .fontWeight(.semibold)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
                .font(.callout)
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button(requireAccept ? "我已阅读" : "关闭", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle(Disclaimer.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(requireAccept)
    }
}
