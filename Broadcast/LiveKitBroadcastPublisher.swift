import AVFoundation
import CoreMedia
import Foundation
import LiveKit

/// Broadcast Upload Extension's independent LiveKit participant for ReplayKit audioApp.
/// 必须是 NSObject + RoomDelegate:连接死了要有人知道 —— 以前没有任何 delegate,
/// 断线后扩展照样往死连接里塞音频,主 App 的圆点仍显示"正在接收并发送",整场系统声静默丢失。
final class LiveKitBroadcastPublisher: NSObject, RoomDelegate {
    private struct Configuration: Decodable {
        let url: String
        let identity: String
        let token: String
    }

    private static let groupCandidates = [
        "group.com.luanshijia.voicememo",
        "group.com.luanshijia.voicememo.458RP2552K",
    ]

    private let log: (String) -> Void
    private let workQueue = DispatchQueue(label: "voicememo.broadcast.audio")
    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private var room: Room?
    private var connectionTask: Task<Void, Never>?
    private var stopped = false
    private var ready = false                         // workQueue only
    private var pending: [CMSampleBuffer] = []         // bounded startup buffer; workQueue only
    private var converter: AVAudioConverter?           // workQueue only
    private var converterFormat = ""                   // workQueue only
    private var formatLogged = false                  // workQueue only
    private var chunks = 0                             // workQueue only
    private var overflowLogged = false                 // workQueue only

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
    }

    // MARK: - RoomDelegate
    // 这两个回调是扩展侧唯一的"连接已死"信号:BroadcastProbe 的失败清单认 "LiveKit 连接断开",
    // 主 App 据此把 phase 判成 error → 圆点变橙、按钮变"未开播",并立刻补写下一个 token。

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        log("LiveKit 连接断开: \(error?.description ?? "对端关闭")")
        workQueue.async {
            self.ready = false                     // 别再往死连接里送 PCM
            self.pending.removeAll(keepingCapacity: false)
        }
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        log("LiveKit 连接断开: 连接失败 \(error?.description ?? "未知")")
        workQueue.async { self.ready = false }
    }

    func start() {
        // 主 App 的卡是 12 分钟一张,扩展读到即删(consume once);扩展可能在 App 还没写之前就起来了,
        // 或者刚好处在两张卡之间。原来一次读不到就 log + return,用户只能停掉重开 —— 改成最多等 10 秒。
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var configuration = Self.readConfiguration()
            var waited = 0
            while configuration == nil && waited < 25 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                waited += 1
                configuration = Self.readConfiguration()
            }
            guard let configuration else {
                self.log("LiveKit 配置缺失或无效；请从主 App 重新启动广播")
                return
            }
            guard configuration.identity.hasSuffix("-replaykit") else {
                self.log("LiveKit 配置身份不符合 -replaykit 约定")
                return
            }
            self.log("LiveKit 正在连接 identity=\(configuration.identity)")
            await self.connect(configuration)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.ready {
                self.publish(sampleBuffer)
            } else if self.pending.count < 120 {
                self.pending.append(sampleBuffer)
            } else {
                self.pending.removeFirst()
                self.pending.append(sampleBuffer)
                if !self.overflowLogged {
                    self.overflowLogged = true
                    self.log("LiveKit 尚未就绪；启动缓存达到 2.4 秒，丢弃最早样本")
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let currentRoom = room
        room = nil
        let task = connectionTask
        connectionTask = nil
        lock.unlock()

        task?.cancel()
        workQueue.async {
            self.ready = false
            self.pending.removeAll(keepingCapacity: false)
        }
        Task { await currentRoom?.disconnect() }
    }

    private func connect(_ configuration: Configuration) async {
        let newRoom = Room()
        newRoom.add(delegate: self)
        do {
            try await newRoom.connect(url: configuration.url, token: configuration.token)
            try AudioManager.shared.setManualRenderingMode(true)
            // Keep the published track as the ReplayKit appAudio path only. LiveKit's mixer
            // otherwise combines its device microphone with the injected appAudio buffers.
            AudioManager.shared.mixer.micVolume = 0
            try await newRoom.localParticipant.setMicrophone(enabled: true)
            AudioManager.shared.mixer.micVolume = 0

            lock.lock()
            let shouldStop = stopped || Task.isCancelled
            if !shouldStop { room = newRoom }
            lock.unlock()

            guard !shouldStop else {
                await newRoom.disconnect()
                return
            }

            log("LiveKit 已连接并发布音频轨 identity=\(configuration.identity)")
            workQueue.async {
                self.ready = true
                self.overflowLogged = false
                let buffered = self.pending
                self.pending.removeAll(keepingCapacity: true)
                buffered.forEach(self.publish)
            }
        } catch {
            log("LiveKit 连接或发布失败: \(error.localizedDescription)")
            await newRoom.disconnect()
        }
    }

    private static func readConfiguration() -> Configuration? {
        for group in groupCandidates {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                continue
            }
            let url = container.appendingPathComponent("broadcast-livekit.json")
            guard let data = try? Data(contentsOf: url),
                  let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
                  !configuration.url.isEmpty, !configuration.token.isEmpty,
                  !configuration.identity.isEmpty else { continue }
            // The short-lived, identity-scoped JWT is consumed once; the API secret never enters the extension.
            try? FileManager.default.removeItem(at: url)
            return configuration
        }
        return nil
    }

    private func publish(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let source = asbd.pointee
        guard source.mSampleRate > 0, source.mChannelsPerFrame > 0 else { return }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int(Int32.max) else { return }

        let signature = "\(source.mSampleRate):\(source.mChannelsPerFrame):\(source.mBitsPerChannel):\(source.mFormatFlags)"
        guard let inputFormat = AVAudioFormat(streamDescription: asbd),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else {
            log("无法建立 ReplayKit PCM 输入缓冲")
            return
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: input.mutableAudioBufferList)
        guard copyStatus == noErr else {
            log("复制 ReplayKit PCM 失败: OSStatus=\(copyStatus)")
            return
        }

        if converter == nil || converterFormat != signature {
            guard let next = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                log("不支持 ReplayKit 格式转换: \(signature)")
                converter = nil
                return
            }
            next.downmix = true
            next.sampleRateConverterQuality = .max
            converter = next
            converterFormat = signature
            let bigEndian = (source.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
            log("audioApp 格式 \(Int(source.mSampleRate))Hz/\(source.mChannelsPerFrame)ch/\(source.mBitsPerChannel)bit/\(bigEndian ? "be" : "le") → 48kHz/mono/float32")
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * outputFormat.sampleRate / source.mSampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, conversionError == nil else {
            log("ReplayKit PCM 转换失败: \(conversionError?.localizedDescription ?? String(describing: result))")
            return
        }
        guard output.frameLength > 0 else { return }

        AudioManager.shared.mixer.capture(appAudio: output)
        chunks += 1
        if chunks == 1 || chunks % 250 == 0 { log("LiveKit 已送入系统声音 \(chunks) 块") }
    }
}
