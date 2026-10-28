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
    var channel: String { kind == .phone ? "mic" : "external_audio" }
    var inputRef: String { kind == .phone ? "iphone" : "cb08" }
    static let phone = InputBinding(kind: .phone, capturePort: .nativeMicrophone, sourceTag: .face2face)
}

struct ReadinessSnapshot {
    let configuration: ConfigSnapshot
    let input: InputBinding
    let inputAvailable: Bool
    let configurationLocked: Bool
    var serverReady = false
    var problems: [String] {
        configuration.problems + (serverReady ? [] : ["服务器未就绪，采集暂不可用"]) + (inputAvailable ? [] : ["当前输入尚未接入"])
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

/// Commands are injected independently of the state owners. Production dispatches
/// through MeetingAssistant; tests can substitute IO without opening a network.
@MainActor struct MeetingCommands {
    let start: () -> CaptureActionResult
    let end: () -> CaptureActionResult
    var pause: (() -> CaptureActionResult)? = nil
    var resume: (() -> CaptureActionResult)? = nil
}
