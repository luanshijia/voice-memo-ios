import Combine
import Foundation
import LiveKit

/// CB08 owns capture; this provider only publishes authorized PCM in the current segment.
@MainActor final class CB08InputProvider: ObservableObject {
    @Published private(set) var decodedFrames = 0
    @Published private(set) var expectedSamples = 0
    @Published private(set) var decodedPackets = 0
    @Published private(set) var decodeFailures = 0
    @Published private(set) var submittedSamples = 0
    @Published private(set) var failure: String?
    @Published private(set) var flowing = false
    @Published private(set) var stage = "尚未开始"
    @Published private(set) var lastPCMAt: Date?
    private let device: CB08DeviceControlling
    private let publisher: PCMAudioPublishing
    private let makeDecoder: () throws -> OpusDecoding
    private var decoder: OpusDecoding?
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
        self.decoder = decoder; self.context = context
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
    func closeGate() { accepting = false; flowing = false; epoch += 1; device.discardQueuedPackets() }
    func requestHalt(_ action: CB08RecordAction) {
        closeGate()
        if failure == nil { stage = action == .pause ? "已暂停音频接收" : "已停止音频接收" }
        guard ownsRecording else { recordingOwner = nil; paused = false; return }
        paused = action == .pause
        if pendingHalt != action {
            device.command(action); pendingHalt = action
        }
        if action == .stop { recordingOwner = nil }
    }
    func pause() async {
        requestHalt(.pause)
        if let room { await publisher.stopPCM(in: room) }
        room = nil; decoder = nil; context = nil
    }
    func stop() async {
        requestHalt(.stop)
        if let room { await publisher.stopPCM(in: room) }
        room = nil; decoder = nil; context = nil
    }
    func interrupted() { closeGate() }
    private func fault(_ reason: String) {
        let active = accepting
        closeGate(); failure = reason
        stage = reason
        if active && !starting { onFault?() }
    }
    private func receive(_ data: Data) {
        guard accepting, context != nil, let decoder else { return }
        do {
            let result = try decoder.decode(packet: data)
            guard accepting else { return }
            try publisher.submitPCM(result.pcm)
            lastPCMAt = Date()
            decodedFrames += result.metrics.frameCount
            expectedSamples += result.metrics.frameCount * CB08OpusFraming.samplesPerFrame
            decodedPackets += 1; submittedSamples += result.metrics.decodedSamples
            if !flowing { flowing = true; stage = "正在接收实时音频"; onFlow?() }
        } catch {
            decodeFailures += 1; fault("音频解码或提交失败，已请求暂停：\(error.localizedDescription)")
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
