import SwiftUI

@main
struct VoiceMemoApp: App {
    init() {
        CrashLog.readPreviousRun()   // 先读上一轮留下的崩溃痕迹(必须在 install() 清空文件之前)
        CrashLog.install()           // 再装崩溃处理器
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
