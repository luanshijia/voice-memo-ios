import Foundation

enum WorkspacePage: String, CaseIterable { case settings, input, connection, meeting }
enum InputKind: String { case phone, external }
enum SourceTag: String { case face2face, call }

struct ConfigSnapshot: Equatable {
    let serverURL: String
    let deviceID: String
    let userID: String
    let revision: Int
    let hasCredential: Bool

    var problems: [String] {
        var result: [String] = []
        if let url = URLComponents(string: serverURL), url.scheme == "wss",
           let host = url.host, !host.isEmpty,
           (url.port == nil || (1...65535).contains(url.port!)),
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil {
            // Transport authentication is checked separately by the computer.
        } else { result.append("电脑服务地址须为有效的 wss:// 地址") }
        if deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("请填写控制手机") }
        if userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("请填写使用者") }
        if !hasCredential { result.append("请填写设备登记凭据") }
        return result
    }
}

struct InputBinding: Equatable {
    enum CapturePort: Equatable { case nativeMicrophone, pcmFeed }
    let kind: InputKind
    let capturePort: CapturePort
    let sourceTag: SourceTag
    static let phone = InputBinding(kind: .phone, capturePort: .nativeMicrophone, sourceTag: .face2face)
}

struct ReadinessSnapshot {
    let configuration: ConfigSnapshot
    let input: InputBinding
    let inputAvailable: Bool
    let configurationLocked: Bool
    var problems: [String] {
        configuration.problems + (inputAvailable ? [] : ["当前输入尚未接入"])
    }
}

/// Identifiers have separate owners; no UI view generates meeting/segment IDs.
struct ExecutionContext {
    let configurationRevision: Int
    let operationID: UUID
    let meetingID: String?
    let channel: String
    let generation: Int?
    let segmentID: String?
}

enum ConfigurationField { case serverURL, deviceID, userID, credential }

/// S2-only seam. Workers read the same legacy facts, never copies of mutable state.
@MainActor protocol LegacySessionPort: AnyObject {
    var configuration: ConfigSnapshot { get }
    var configurationLocked: Bool { get }
    var isRecording: Bool { get }
    var wantsCapture: Bool { get }
    var terminating: Bool { get }
    var meeting: MeetingContext { get }
    var board: StatusBoard { get }
    var presentation: SessionPresentation { get }
    func updateConfiguration(_ field: ConfigurationField, value: String)
    func resetConfiguration()
    func startCapture()
    func stopCapture()
    func endMeeting()
    func checkConnection() async
}
