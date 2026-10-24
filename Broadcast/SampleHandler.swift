import CoreMedia
import Foundation
import ReplayKit

/// Replacement broadcast extension: system app audio enters LiveKit as its own participant.
final class SampleHandler: RPBroadcastSampleHandler {
    private let fileName = "broadcast-probe.log"
    private let logQueue = DispatchQueue(label: "voicememo.broadcast.probe-log")
    private var publisher: LiveKitBroadcastPublisher?
    private var appFrames = 0
    private var callbacks = 0
    private var micCallbacks = 0
    private var videoCallbacks = 0
    private var sampleRate = 0.0
    private var lastStatus = Date.distantPast

    private static let groupCandidates = MeetingClient.appGroupCandidates

    private func log(_ line: String) {
        logQueue.sync {
            guard let url = Self.groupCandidates
                .compactMap({ FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) })
                .first?.appendingPathComponent(fileName) else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 结构化观测:`obs v=1 [gen=N] [meeting=UUID] state=... [reason=码] [audio_app=样本数]`。
    /// 状态词只用 AppSharedContract.ChannelState 的五个,不许自造;原因只发码,句子留给显示层。
    /// 授权到手前没有代次,此时不写 gen(契约里 gen 允许缺省)。
    private func observe(_ state: AppSharedContract.ChannelState,
                         generation: Int? = nil, meeting: String? = nil,
                         reason: String? = nil, audioApp: Int? = nil) {
        var parts = ["obs", "v=\(AppSharedContract.observationVersion)",
                     "state=\(state.rawValue)"]
        if let generation { parts.append("gen=\(generation)") }
        if let meeting { parts.append("meeting=\(meeting)") }
        if let reason { parts.append("reason=\(reason)") }
        if let audioApp { parts.append("audio_app=\(audioApp)") }
        log(parts.joined(separator: " "))
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        appFrames = 0
        callbacks = 0
        micCallbacks = 0
        videoCallbacks = 0
        sampleRate = 0
        lastStatus = .distantPast
        log("=== 扩展启动 ===")
        observe(.starting)
        publisher = LiveKitBroadcastPublisher { [weak self] in self?.log($0) }
        publisher?.start()
    }

    override func broadcastPaused() {
        log("扩展暂停")
        publisher?.captureDidPause()
    }

    override func broadcastResumed() {
        log("扩展恢复")
        publisher?.captureDidResume()
    }

    override func broadcastFinished() {
        publisher?.stop()
        publisher = nil
        log("=== 扩展结束; audioApp 回调=\(callbacks) audioMic 回调=\(micCallbacks) 样本=\(appFrames) 时长≈\(seconds())秒 ===")
        observe(.stopped, audioApp: appFrames)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        if type == .audioMic {
            // 仅计数用于核对系统麦克风开关是否生效；绝不复制或发布，主 App 是唯一麦克风轨。
            micCallbacks += 1
            return
        }
        if type == .video {
            // Screen frames are not retained or forwarded; they only provide a broadcast-process heartbeat.
            videoCallbacks += 1
        } else if type == .audioApp {
            callbacks += 1
            appFrames += CMSampleBufferGetNumSamples(sampleBuffer)
            if sampleRate == 0,
               let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                sampleRate = asbd.pointee.mSampleRate
            }
            publisher?.append(sampleBuffer)
        } else {
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastStatus) >= 5 {
            lastStatus = now
            log("计数 回调 video=\(videoCallbacks) audioApp=\(callbacks) audioMic=\(micCallbacks) 样本=\(appFrames) 时长≈\(seconds())秒")
            // 心跳本身也是观测:主 App 用它判"扩展进程还活着、系统声还在进"。
            publisher?.sampleHeartbeat()
        }
    }

    private func seconds() -> String {
        guard sampleRate > 0 else { return "?" }
        return String(format: "%.1f", Double(appFrames) / sampleRate)
    }
}
