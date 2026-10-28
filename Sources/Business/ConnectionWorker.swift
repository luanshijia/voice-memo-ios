import Combine
import Foundation
import LiveKit

/// Injectable control IO; MeetingAssistant owns the cross-worker execution order.
@MainActor struct CaptureControlOperations {
    var queueStart: @MainActor (LiveKitConfig, Int, InputBinding, String?) throws -> Void
    var queueAction: @MainActor (LiveKitConfig, CaptureView?, String, InputBinding?) throws -> Void
    var flush: @MainActor () async throws -> CaptureView?
    var view: @MainActor (LiveKitConfig) async throws -> CaptureDeviceView
    var observe: @MainActor (LiveKitConfig, CaptureView, String) async throws -> Void
    var hasPending: @MainActor () -> Bool

    static var live: Self {
        Self(queueStart: { try MeetingClient.queueCaptureStart(config: $0, revision: $1, input: $2, meetingID: $3) },
             queueAction: { try MeetingClient.queueCaptureAction(config: $0, view: $1, action: $2, input: $3) },
             flush: { try await MeetingClient.flushPendingCapture() },
             view: { try await MeetingClient.captureDeviceView(config: $0) },
             observe: { try await MeetingClient.observeCapture(config: $0, view: $1, observed: $2) },
             hasPending: { MeetingClient.hasPendingCapture() })
    }
}

/// Owns transport instances, async generations and disconnection serialization.
@MainActor final class ConnectionWorker: ObservableObject {
    private let room: VoiceRoom
    @Published private(set) var generation = 0
    @Published private(set) var live: Room?
    @Published private(set) var connecting: Task<Void, Never>?
    @Published private(set) var pendingDisconnect: Task<Void, Never>?
    @Published private(set) var endReason: LinkReason?
    private(set) var probe = Status<LinkDesired, LinkObserved, LinkReason>(
        desired: .wanted, observed: .notStarted)
    private let settings: SettingsWorker
    private let probeHost: (String, UInt16) async -> Bool
    private let captureControl: CaptureControlOperations
    private let connectRoom: (@MainActor (String, String, String) async throws -> Room)?
    private let disconnectRoom: (@MainActor (Room) async -> Void)?
    private let sendData: (@MainActor ([String: Any]) async -> Void)?
    private var connectionAttemptID: UUID?
    private var disconnectID: UUID?
    private var pendingInputCleanup: Task<Void, Never>?
    private var inputCleanupID: UUID?
    var onNote: ((String) -> Void)?
    var onProtocolIssue: ((String) -> Void)?
    var onEnded: ((String) -> Void)?
    var onTranscript: ((String, String, Double, String, Double?, Double, [String: Any]) -> Void)?
    var controlObservation: () -> MeetingContext = { .empty }
    var recognitionProgress: () -> Double = { 0 }

    init(settings: SettingsWorker, room: VoiceRoom? = nil,
         captureControl: CaptureControlOperations? = nil,
         connectRoom: (@MainActor (String, String, String) async throws -> Room)? = nil,
         disconnectRoom: (@MainActor (Room) async -> Void)? = nil,
         sendData: (@MainActor ([String: Any]) async -> Void)? = nil,
         probeHost: @escaping (String, UInt16) async -> Bool = { await NetProbe.check(host: $0, port: $1) }) {
        self.settings = settings
        self.room = room ?? VoiceRoom()
        self.probeHost = probeHost
        self.captureControl = captureControl ?? .live
        self.connectRoom = connectRoom
        self.disconnectRoom = disconnectRoom
        self.sendData = sendData
        self.room.onState = { [weak self] _ in self?.objectWillChange.send() }
        self.room.onEndReason = { [weak self] reason in self?.endReason = reason }
        self.room.onNote = { [weak self] note in self?.onNote?(note) }
        self.room.onProtocolIssue = { [weak self] issue in self?.onProtocolIssue?(issue) }
        self.room.onEnded = { [weak self] reason in self?.onEnded?(reason) }
        self.room.onTranscript = { [weak self] type, who, seconds, text, gap, ts, raw in
            self?.onTranscript?(type, who, seconds, text, gap, ts, raw)
        }
    }
    func queueCaptureStart(config: LiveKitConfig, input: InputBinding, meetingID: String?) throws {
        try captureControl.queueStart(config, settings.snapshot.revision, input, meetingID)
    }
    func queueCaptureAction(config: LiveKitConfig, view: CaptureView?, action: String,
                            input: InputBinding? = nil) throws {
        try captureControl.queueAction(config, view, action, input)
    }
    var hasPendingCapture: Bool { captureControl.hasPending() }
    func flushCapture() async throws -> CaptureView? { try await captureControl.flush() }
    func captureView(config: LiveKitConfig) async throws -> CaptureDeviceView {
        try await captureControl.view(config)
    }
    func observeCapture(config: LiveKitConfig, view: CaptureView, observed: String) async throws {
        try await captureControl.observe(config, view, observed)
    }
    func connect(url: String, token: String, identity: String) async throws -> Room {
        if let connectRoom { return try await connectRoom(url, token, identity) }
        return try await room.connect(url: url, token: token, identity: identity)
    }
    func disconnect(_ target: Room) async {
        if let disconnectRoom { await disconnectRoom(target) } else { await room.disconnect(target) }
    }
    func send(_ payload: [String: Any]) async {
        if let sendData { await sendData(payload) } else { await room.send(payload) }
    }
    @discardableResult func invalidate() -> Int { generation += 1; return generation }
    /// Capture the previous wait synchronously before scheduling a new attempt.
    /// A stop in the same event-loop turn must never become its own predecessor.
    func beginConnection(_ attempt: @escaping () async -> Void) {
        let previous = pendingDisconnect
        pendingDisconnect = nil
        disconnectID = nil
        let id = UUID()
        connectionAttemptID = id
        connecting = Task {
            defer { if connectionAttemptID == id { connecting = nil; connectionAttemptID = nil } }
            await previous?.value
            await attempt()
        }
    }
    func resetEndReason() { endReason = nil }
    func connected(_ target: Room) { live = target }
    func interrupted() { live = nil }
    func enqueueDisconnect(beforeDisconnect: @escaping () async -> Void,
                           completion: @escaping () async -> Void) {
        let previous = pendingDisconnect
        let inflight = connecting
        let target = live
        connecting = nil
        connectionAttemptID = nil
        live = nil
        let id = UUID()
        disconnectID = id
        // Stop input independently of a start task awaiting a control response.
        // Input cleanups stay serialized, without waiting for network teardown.
        let priorInputCleanup = pendingInputCleanup
        let cleanupID = UUID()
        inputCleanupID = cleanupID
        let cleanup = Task {
            defer { if inputCleanupID == cleanupID { pendingInputCleanup = nil; inputCleanupID = nil } }
            await priorInputCleanup?.value
            await beforeDisconnect()
        }
        pendingInputCleanup = cleanup
        pendingDisconnect = Task {
            defer { if disconnectID == id { pendingDisconnect = nil; disconnectID = nil } }
            await previous?.value
            await cleanup.value
            await inflight?.value
            if let target { await self.disconnect(target) }
            await completion()
        }
    }
    var network: LinkObserved {
        Date().timeIntervalSince(probe.lastSeen) <= StatusBoard.probeStaleAfter ? probe.observed : .unknown
    }
    var media: LinkObserved { status(desired: .wanted).observed }
    var controlIsFresh: Bool { controlObservation().isFresh() }
    var recognitionSeconds: Double { recognitionProgress() }
    private var receipt: CaptureAudioReceipt?
    private var receiptCheckedAt: Date?
    private var probeExpiry: Task<Void, Never>?
    private var receiptExpiry: Task<Void, Never>?
    deinit { probeExpiry?.cancel(); receiptExpiry?.cancel() }
    var currentCapture: () -> CaptureView? = { nil }
    func updateAudioReceipt(_ state: CaptureDeviceView) {
        let evidence = state.meeting.flatMap { view in state.audioReceipt.flatMap { $0.matches(view) ? $0 : nil } }
        let wasStale = receiptCheckedAt.map { Date().timeIntervalSince($0) > 15 } ?? false
        if receipt != evidence || wasStale { objectWillChange.send() }
        receipt = evidence
        receiptCheckedAt = evidence == nil ? nil : Date()
        receiptExpiry?.cancel()
        if evidence != nil {
            receiptExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.objectWillChange.send()
            }
        }
    }
    var desktopAudioEvidence: String {
        guard let view = currentCapture(), let receipt, receipt.matches(view), let receiptCheckedAt else {
            return "尚无当前分段的实收证据"
        }
        let seconds = Double(receipt.receivedSamples) / Double(receipt.sampleRate)
        let stale = Date().timeIntervalSince(receiptCheckedAt) > 15
        return String(format: "%.2f 秒 · %ld 样本%@", seconds, receipt.receivedSamples,
                      stale ? "（上次查询，已过期）" : "（电脑实收）")
    }
    func status(desired: LinkDesired) -> Status<LinkDesired, LinkObserved, LinkReason> {
        let observed: LinkObserved
        switch room.connectionState {
        case .connected?: observed = .connected
        case .connecting?: observed = .connecting
        case .reconnecting?: observed = .reconnecting
        case .disconnected?: observed = .disconnected
        case nil: observed = desired == .wanted && connecting != nil ? .connecting : .notStarted
        default: observed = .unknown
        }
        return Status(desired: desired, observed: observed,
                      reason: observed == .disconnected ? (endReason ?? .disconnected) : nil,
                      lastSeen: Date(), generation: generation)
    }
    func preflightControl() async {
        let revision = settings.snapshot.revision
        let config = settings.config
        let requestGeneration = generation
        let ok: Bool
        if let hp = NetProbe.hostPort(from: config.url) { ok = await probeHost(hp.host, hp.port) }
        else { ok = false }
        guard revision == settings.snapshot.revision, requestGeneration == generation else { return }
        let next = Status<LinkDesired, LinkObserved, LinkReason>(desired: .wanted,
            observed: ok ? .connected : .disconnected, reason: ok ? nil : .probeTimeout,
            lastSeen: Date(), generation: generation)
        if probe.observed != next.observed || probe.reason?.code != next.reason?.code ||
           probe.generation != next.generation || network == .unknown { objectWillChange.send() }
        probe = next
        probeExpiry?.cancel()
        probeExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(StatusBoard.probeStaleAfter)) } catch { return }
            self?.objectWillChange.send()
        }
    }
}
