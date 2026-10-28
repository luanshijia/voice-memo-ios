import Combine
import Foundation
import LiveKit

/// CB08 owns capture; this provider only publishes authorized PCM in the current segment.
@MainActor final class CB08InputProvider: ObservableObject {
    let telemetry = DeviceTelemetry()
    private(set) var decodedFrames = 0
    private(set) var expectedSamples = 0
    private(set) var decodedPackets = 0
    private(set) var decodeFailures = 0
    private(set) var submittedSamples = 0
    @Published private(set) var failure: String?
    @Published private(set) var flowing = false
    @Published private(set) var stage = "尚未开始"
    private(set) var lastPCMAt: Date?
    private let device: CB08DeviceControlling
    private let publisher: PCMAudioPublishing
    private let makeDecoder: () throws -> OpusDecoding
    private var pipeline: CB08DecodePipeline?
    private var pendingDecodes = 0
    private var nextStatisticsUpdate = Date.distantPast
    private var room: Room?
    private var context: ExecutionContext?
    private var accepting = false
    private var epoch = 0
    private var paused = false
    private var recordingOwner: (meetingID: String, connectionID: UUID)?
    private var ownsRecording: Bool {
        guard let owner = recordingOwner else { return false }
        return device.connected && owner.connectionID == device.connectionID
    }
    private var haltProblem: String?
    var cleanupProblem: String? { haltProblem ?? publisher.cleanupProblem }
    private var pendingHalt: CB08RecordAction?
    private var starting = false
    private let startupTimeout: Duration
    var onFault: (() -> Void)?
    var onFlow: (() -> Void)?
    var isAvailable: Bool { device.connected }

    init(device: CB08DeviceControlling, publisher: PCMAudioPublishing,
         startupTimeout: Duration = .seconds(8),
         makeDecoder: @escaping () throws -> OpusDecoding = { try OpusDecoder() }) {
        self.device = device; self.publisher = publisher; self.makeDecoder = makeDecoder
        self.startupTimeout = startupTimeout
        device.onPacket = { [weak self] data in self?.receive(data) }
        device.onLoss = { [weak self] in
            guard let self else { return }
            if self.accepting { self.fault("外设连接或回调中断") }
            else { self.stage = "蓝牙已断开" }
        }
    }
    func bind(_ room: Room?) { self.room = room }
    func audioStatus(at date: Date) -> String {
        guard flowing, let lastPCMAt else { return stage }
        return "实时音频 · \(max(0, Int(date.timeIntervalSince(lastPCMAt))))秒前收到"
    }
    func reportStartupFailure(_ message: String) {
        if failure == nil { failure = message; stage = "启动未完成" }
    }
    func start(context: ExecutionContext) async throws {
        guard device.connected, let connectionID = device.connectionID, let room else { throw CB08InputError.unavailable }
        guard context.channel == "external_audio", let meetingID = context.meetingID,
              context.segmentID != nil, context.generation != nil else { throw CB08InputError.invalidContext }
        guard cleanupProblem == nil else { throw AudioPublishError.cleanupFailed }
        epoch += 1; let attempt = epoch
        failure = nil; stage = "查询设备录音状态"
        let recordState = await device.refreshRecordState(timeout: .seconds(3))
        guard attempt == epoch, device.connected, device.connectionID == connectionID else {
            throw CB08InputError.unavailable
        }
        guard let recordState else { throw CB08InputError.recordStateUnknown }
        // Do not adopt a card's unrelated existing recording into a new meeting.
        let canResume = paused && ownsRecording && recordingOwner?.meetingID == meetingID
        guard recordState == .stopped || recordState == .inactive || (recordState == .paused && canResume) else {
            if recordState == .paused { throw CB08InputError.pausedRecordingNotOwned }
            throw CB08InputError.alreadyRecording(recordState)
        }
        let decoder = try makeDecoder()
        try await publisher.startPCM(in: room)
        guard attempt == epoch, device.connected, device.connectionID == connectionID else {
            await publisher.stopPCM(in: room); throw CB08InputError.unavailable
        }
        guard device.recordState == recordState else {
            await publisher.stopPCM(in: room); throw CB08InputError.recordStateChanged
        }
        self.pipeline = CB08DecodePipeline(decoder: decoder); self.context = context
        decodedFrames = 0; expectedSamples = 0
        decodedPackets = 0; decodeFailures = 0; submittedSamples = 0
        device.discardQueuedPackets()
        failure = nil; flowing = false; accepting = true; lastPCMAt = nil
        // An inactive query permits a NEW recording, never resumption of an unowned file.
        let resume = (recordState == .paused || recordState == .inactive) && canResume
        paused = false
        recordingOwner = (meetingID, connectionID); pendingHalt = nil
        starting = true
        defer { starting = false }
        stage = "等待设备动作回执"
        device.command(resume ? .resume : .start)
        guard await device.waitForRecordAction(timeout: startupTimeout) else {
            guard attempt == epoch else { throw CB08InputError.unavailable }
            stage = "未收到匹配的录音动作回执"
            failure = stage; throw CB08InputError.actionNotConfirmed
        }
        guard attempt == epoch, accepting else { throw CB08InputError.unavailable }
        if !flowing { stage = "设备已确认，等待实时音频" }
        let clock = ContinuousClock(); let deadline = clock.now + startupTimeout
        while !flowing, accepting, attempt == epoch, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard attempt == epoch, accepting, !Task.isCancelled else { throw CB08InputError.unavailable }
        guard flowing else {
            stage = "设备已录音，但未收到有效实时音频"
            failure = stage; throw CB08InputError.noRealtimeAudio
        }
    }
    /// Close the gate synchronously, before any asynchronous track disconnect.
    func closeGate() {
        accepting = false; flowing = false; epoch += 1
        pipeline?.cancel(); publisher.closePCMGate(); pendingDecodes = 0
        device.discardQueuedPackets(); objectWillChange.send()
    }
    func requestHalt(_ action: CB08RecordAction) {
        closeGate()
        if failure == nil { stage = action == .pause ? "已暂停音频接收" : "已停止音频接收" }
        guard ownsRecording else { recordingOwner = nil; paused = false; return }
        if pendingHalt != action {
            device.command(action); pendingHalt = action
        }
    }
    private func finishHalt(_ action: CB08RecordAction) async {
        requestHalt(action)
        let owner = recordingOwner
        let haltEpoch = epoch
        if let room { await publisher.stopPCM(in: room) }
        else { await publisher.retryCleanup() }
        room = nil; pipeline = nil; context = nil
        guard let owner, ownsRecording else {
            haltProblem = nil
            return
        }
        let confirmed = await device.waitForRecordAction(timeout: startupTimeout)
        guard epoch == haltEpoch else { return }
        guard recordingOwner?.connectionID == owner.connectionID,
              device.connectionID == owner.connectionID else {
            // A new connection cannot confirm or inherit the old card's recording.
            recordingOwner = nil; pendingHalt = nil; paused = false
            haltProblem = nil
            failure = "旧CB08连接已变化，无法确认原设备停止；本地音频已关闭"
            stage = failure!
            return
        }
        if confirmed {
            haltProblem = nil; pendingHalt = nil
            paused = action == .pause
            if action == .stop { recordingOwner = nil }
            if failure == nil { stage = action == .pause ? "设备已确认暂停" : "设备已确认停止" }
        } else {
            pendingHalt = nil // A later bounded reconciliation may resend to this same owned connection.
            haltProblem = "本地音频已关闭，CB08\(action.title)尚未确认"
            stage = haltProblem!
        }
    }
    func pause() async { await finishHalt(.pause) }
    func stop() async { await finishHalt(.stop) }
    func interrupted() { closeGate() }
    private func fault(_ reason: String) {
        let active = accepting
        closeGate(); failure = reason
        stage = reason
        if active && !starting { onFault?() }
    }
    func waitForPendingAudio() async {
        while pendingDecodes > 0, accepting, !Task.isCancelled { await Task.yield() }
    }
    private func receive(_ data: Data) {
        guard accepting, context != nil, let pipeline else { return }
        let attempt = epoch
        pendingDecodes += 1
        let accepted = pipeline.submit(data) { [weak self] result in
            guard let self, self.accepting, self.epoch == attempt else { return }
            self.pendingDecodes -= 1
            do {
                let output = try result.get()
                try self.publisher.submitPCM(output.pcm)
                RuntimeActivity.add(.pcmSamples, output.metrics.decodedSamples)
                self.lastPCMAt = Date()
                self.decodedFrames += output.metrics.frameCount
                self.expectedSamples += output.metrics.frameCount * CB08OpusFraming.samplesPerFrame
                self.decodedPackets += 1; self.submittedSamples += output.metrics.decodedSamples
                if !self.flowing { self.flowing = true; self.stage = "正在接收实时音频"; self.onFlow?() }
                if Date() >= self.nextStatisticsUpdate {
                    self.nextStatisticsUpdate = Date().addingTimeInterval(0.5)
                    self.telemetry.changed()
                }
            } catch {
                self.decodeFailures += 1
                self.fault("音频解码或提交失败，已请求暂停：\(error.localizedDescription)")
            }
        }
        if !accepted {
            pendingDecodes -= 1
            fault("音频处理队列已满，已请求暂停")
        }
    }
}

enum CB08InputError: LocalizedError {
    case unavailable, invalidContext, recordStateUnknown, recordStateChanged, pausedRecordingNotOwned
    case actionNotConfirmed, noRealtimeAudio
    case alreadyRecording(CB08RecordingState)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "CB08 未连接或连接已变化"
        case .invalidContext: return "CB08 采集上下文无效"
        case .recordStateUnknown: return "未收到 CB08 录音状态，请刷新设备状态后重试"
        case .recordStateChanged: return "CB08 录音状态在启动期间发生变化，请刷新设备状态后重试"
        case .pausedRecordingNotOwned: return "CB08 存在不属于当前会议的暂停录音，请先在设备端处理"
        case .alreadyRecording(let state): return "CB08 当前状态：\(state.rawValue)，请先处理设备独立录音后重试"
        case .actionNotConfirmed: return "未收到 CB08 录音动作回执（cmd=3），请查看外设控制台诊断"
        case .noRealtimeAudio: return "CB08 已确认录音，但未收到有效实时音频，请查看实体键和音频诊断"
        }
    }
}
