import SwiftUI

@main
struct VoiceMemoApp: App {
    /// 关掉 LiveKit SDK 的「自动停用音频会话」(治点「停止」时那声「嘟」)。
    /// SDK 默认在断开时把 AVAudioSession 置为 inactive,iOS 会为这次会话关闭播一声「嘟」——
    /// 用户开着静音开关也听得到(说明走的是音频会话/媒体通路,不是 App 播的提示音;
    /// 实测我们代码里没有任何发声 API),且飞行模式下没连上过 → 没有会话可关 → 不响。
    /// 官方文档 Docs/audio.md 提供这个开关,并建议在启动时设一次。
    /// 代价:停止后音频会话仍然 active → 别的 App 的音乐不会自动恢复(可接受)。
    init() {
        AudioPublisher.configureAudioSession()
        CrashLog.readPreviousRun()   // 先读上一轮留下的崩溃痕迹(必须在 install() 清空文件之前)
        CrashLog.install()           // 再装崩溃处理器
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
