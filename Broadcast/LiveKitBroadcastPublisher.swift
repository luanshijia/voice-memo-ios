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
        let session: String?
        let generation: Int
        let requestID: String?
    }

    private let log: (String) -> Void
    private let workQueue = DispatchQueue(label: "voicememo.broadcast.audio")
    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private var room: Room?
    private var meeting: (id: String, url: String, device: String, generation: Int)?
    private var connectionTask: Task<Void, Never>?
    private var stopped = false
    private var observedState: AppSharedContract.ChannelState = .starting
    private var observedReason: String?
    private var capturePaused = false
    private var publishedSamples = 0
    private var queuedAudioSeconds = 0.0               // lock-protected; includes queued closures
    private var droppedBuffers = 0                    // lock-protected
    private var pendingAudioSeconds = 0.0             // workQueue only
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

    /// 结构化观测行:主 App 只认这一种(见 contracts/app-shared-v1.json)。
    /// 有授权就有代次与会议号;没有授权时只写 state,读方不得把缺省代次当成有效代次。
    private func observe(_ state: AppSharedContract.ChannelState, reason: String? = nil) {
        lock.lock()
        if stopped && state != .stopped {
            lock.unlock()
            return
        }
        let current = meeting
        let effective = state == .active && capturePaused ? AppSharedContract.ChannelState.interruptedPending : state
        observedState = effective
        observedReason = reason
        var parts = ["obs", "v=\(AppSharedContract.observationVersion)",
                     "state=\(effective.rawValue)"]
        if let current {
            parts.append("gen=\(current.generation)")
            parts.append("meeting=\(current.id)")
        }
        if let reason { parts.append("reason=\(reason)") }
        log(parts.joined(separator: " "))
        lock.unlock()
    }

    /// SampleHandler reports counts, but cannot declare the LiveKit connection active.
    /// Keep the last publisher-owned state and its meeting/generation on every heartbeat.
    func sampleHeartbeat() {
        lock.lock()
        let current = meeting
        let state = observedState
        let reason = observedReason
        let audioApp = publishedSamples
        var parts = ["obs", "v=\(AppSharedContract.observationVersion)",
                     "state=\(state.rawValue)", "audio_app=\(audioApp)"]
        if let current {
            parts.append("gen=\(current.generation)")
            parts.append("meeting=\(current.id)")
        }
        if let reason { parts.append("reason=\(reason)") }
        log(parts.joined(separator: " "))
        lock.unlock()
    }

    func captureDidPause() {
        lock.lock()
        capturePaused = true
        let wasActive = observedState == .active
        lock.unlock()
        if wasActive { observe(.interruptedPending) }
    }

    func captureDidResume() {
        lock.lock()
        capturePaused = false
        let wasPaused = observedState == .interruptedPending
        lock.unlock()
        if wasPaused { observe(.active) }
    }

    // MARK: - RoomDelegate
    // 这两个回调是扩展侧唯一的"连接已死"信号:BroadcastProbe 的失败清单认 "LiveKit 连接断开",
    // 主 App 据此把 phase 判成 error → 圆点变橙、按钮变"未开播",并立刻补写下一个 token。

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        log("LiveKit 连接断开: \(error?.description ?? "对端关闭")")
        observe(.interrupted, reason: "disconnected")
        workQueue.async {
            self.ready = false                     // 别再往死连接里送 PCM
            self.pending.removeAll(keepingCapacity: false)
            self.pendingAudioSeconds = 0
        }
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        log("LiveKit 连接断开: 连接失败 \(error?.description ?? "未知")")
        observe(.interrupted, reason: "connect_failed")
        workQueue.async { self.ready = false }
    }

    func start() {
        // A grant creates a desktop channel, so only request it after ReplayKit starts.
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let configuration: Configuration
            do {
                let grant = try await MeetingClient.requestBroadcastGrant()
                configuration = Configuration(url: grant.url, identity: grant.identity,
                                               token: grant.token, session: grant.meetingID,
                                               generation: grant.generation, requestID: grant.requestID)
                self.lock.lock()
                let alreadyStopped = self.stopped
                self.meeting = (grant.meetingID, grant.url,
                                String(grant.identity.dropLast("-replaykit".count)),
                                grant.generation)
                self.lock.unlock()
                self.observe(.starting)
                if alreadyStopped {
                    self.queueAndFlushStop()
                    return
                }
            } catch {
                self.log("ReplayKit 独立申请会议授权失败: \(error.localizedDescription)")
                return
            }
            guard configuration.identity.hasSuffix("-replaykit") else {
                self.log("LiveKit 配置身份不符合 -replaykit 约定")
                self.queueAndFlushStop()
                return
            }
            self.log("LiveKit 正在连接 identity=\(configuration.identity)")
            // Retry this grant briefly; the coordinator channel is closed if all attempts fail.
            var attempt = 0
            while attempt < 3, !Task.isCancelled {
                attempt += 1
                if await self.connect(configuration) { return }
                if attempt < 3 {
                    self.log("LiveKit 连接失败,5 秒后重试(第 \(attempt + 1)/3 次)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            self.log("LiveKit 连接重试 3 次仍失败:本场系统声不会送到家里")
            self.observe(.interrupted, reason: "connect_failed")
            self.queueAndFlushStop()
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mSampleRate > 0 else { return }
        let seconds = Double(CMSampleBufferGetNumSamples(sampleBuffer)) / format.pointee.mSampleRate
        guard seconds > 0, seconds.isFinite else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard queuedAudioSeconds + seconds <= 2.4 else {
            droppedBuffers += 1
            let count = droppedBuffers
            lock.unlock()
            if count == 1 || count % 250 == 0 { log("系统声音处理积压，已丢弃 \(count) 块") }
            return
        }
        queuedAudioSeconds += seconds
        lock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.queuedAudioSeconds = max(0, self.queuedAudioSeconds - seconds)
                self.lock.unlock()
            }
            if self.ready {
                self.publish(sampleBuffer)
            } else if self.pendingAudioSeconds + seconds <= 2.4 {
                self.pending.append(sampleBuffer)
                self.pendingAudioSeconds += seconds
            } else {
                if !self.overflowLogged {
                    self.overflowLogged = true
                    self.log("LiveKit 尚未就绪；启动缓存达到 2.4 秒，丢弃新到样本")
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let currentRoom = room
        room = nil
        let currentMeeting = meeting
        meeting = nil
        let task = connectionTask
        connectionTask = nil
        lock.unlock()

        task?.cancel()
        workQueue.async {
            self.ready = false
            self.pending.removeAll(keepingCapacity: false)
            self.pendingAudioSeconds = 0
        }
        // 先持久化停止意图，扩展即使立即退出，主 App 仍可补发。
        let queued = currentMeeting.map(queueStop) ?? false
        Task {
            await currentRoom?.disconnect()
            // 媒体连接结束后再通知电脑端封住系统声音通道。
            if queued {
                do { try await MeetingClient.flushPendingBroadcastStop() }
                catch { self.log("系统声音停止状态同步失败: \(error.localizedDescription)") }
            }
        }
    }

    private func queueAndFlushStop(_ known: (id: String, url: String, device: String,
                                             generation: Int)? = nil) {
        lock.lock()
        let current = known ?? meeting
        lock.unlock()
        guard let current else { return }
        observe(.stopped, reason: "stopped_by_user")
        guard queueStop(current) else { return }
        Task {
            do { try await MeetingClient.flushPendingBroadcastStop() }
            catch { self.log("系统声音停止状态同步失败: \(error.localizedDescription)") }
        }
    }

    private func queueStop(_ current: (id: String, url: String, device: String,
                                        generation: Int)) -> Bool {
        do {
            try MeetingClient.queueBroadcastStop(serverURL: current.url,
                                                        meetingID: current.id,
                                                        deviceID: current.device,
                                                        generation: current.generation)
        } catch {
            log("系统声音停止请求保存失败: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private func connect(_ configuration: Configuration) async -> Bool {
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
            if !shouldStop {
                room = newRoom
                if let session = configuration.session,
                   configuration.identity.hasSuffix("-replaykit") {
                    let device = String(configuration.identity.dropLast("-replaykit".count))
                    meeting = (session, configuration.url, device, configuration.generation)
                }
            }
            lock.unlock()

            guard !shouldStop else {
                await newRoom.disconnect()
                return false
            }

            log("LiveKit 已连接并发布音频轨 identity=\(configuration.identity)")
            observe(.active)
            if let session = configuration.session {
                let device = String(configuration.identity.dropLast("-replaykit".count))
                do {
                    try await MeetingClient.reportObservation(
                        serverURL: configuration.url, meetingID: session,
                        deviceID: device, channel: SessionControlContract.systemAudio,
                        generation: configuration.generation, observed: "publishing", requestID: configuration.requestID)
                } catch {
                    log("系统声音采集状态待同步: \(error.localizedDescription)")
                }
            }
            lock.lock()
            let stillCurrent = !stopped && room === newRoom
            lock.unlock()
            guard stillCurrent, !Task.isCancelled else { return false }
            workQueue.async {
                self.lock.lock()
                let allowed = !self.stopped && self.room === newRoom
                self.lock.unlock()
                guard allowed else { return }
                self.ready = true
                self.overflowLogged = false
                let buffered = self.pending
                self.pending.removeAll(keepingCapacity: true)
                self.pendingAudioSeconds = 0
                buffered.forEach(self.publish)
            }
            return true
        } catch {
            log("LiveKit 连接或发布失败: \(error.localizedDescription)")
            observe(.interrupted, reason: "connect_failed")
            await newRoom.disconnect()
            return false
        }
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
        lock.lock()
        publishedSamples += Int(output.frameLength)
        lock.unlock()
        chunks += 1
        if chunks == 1 || chunks % 250 == 0 { log("LiveKit 已送入系统声音 \(chunks) 块") }
    }
}
