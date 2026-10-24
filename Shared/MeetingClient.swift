import Foundation
import CryptoKit

/// Shared control contract for the main App and ReplayKit extension.
/// The computer creates the meeting id and returns it with the media grant.
struct MeetingGrant: Decodable {
    let url: String
    let token: String
    let identity: String
    let ttl: Int
    let meetingID: String
    let generation: Int

    enum CodingKeys: String, CodingKey {
        case url, token, identity, ttl, generation
        case meetingID = "meeting_id"
    }
}

struct DeviceMeetingView: Decodable {
    struct PendingReport: Decodable {
        let meetingID: String
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case meetingID = "meeting_id", sha256
        }
    }
    struct Meeting: Decodable {
        struct Channel: Decodable {
            let status: String
            let generation: Int?
        }
        let meetingID: String
        let status: String
        let channels: [String: Channel]
        /// 电脑端给的接回截止时刻：通道中断起点 + 恢复宽限。
        /// nil 有两种来源，两种都等价于「此刻没有截止线」：
        ///   ① 还没开始计时（总管没标 interrupted_pending）；
        ///   ② 旧版电脑端根本不发这个字段。
        /// 格式坏的也落 nil —— 后果只可能是「多试一次带号」，被拒后由
        /// 409 回落拿新号，不会造成状态分叉。
        let recoveryDeadline: Date?
        enum CodingKeys: String, CodingKey {
            case meetingID = "meeting_id", status, channels
            case recoveryDeadline = "recovery_deadline"
        }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            meetingID = try box.decode(String.self, forKey: .meetingID)
            status = try box.decode(String.self, forKey: .status)
            channels = try box.decode([String: Channel].self, forKey: .channels)
            recoveryDeadline = DeviceMeetingView.instant(
                try box.decodeIfPresent(String.self, forKey: .recoveryDeadline))
        }
    }
    /// 契约里的时刻一律是 UTC ISO-8601（毫秒）。带小数的解析器单独建一个,
    /// 不带小数的旧格式也试一次:两处都失败才返回 nil。
    static func instant(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
    struct Receiver: Decodable {
        let url: String
        let token: String
        let identity: String
        let meetingID: String
        enum CodingKeys: String, CodingKey { case url, token, identity; case meetingID = "meeting_id" }
    }
    let stateRevision: Int
    let meeting: Meeting?
    let view: Receiver?
    let pendingReports: [PendingReport]
    enum CodingKeys: String, CodingKey {
        case stateRevision = "state_revision", meeting, view
        case pendingReports = "pending_reports"
    }
}

/// 已确认定稿的补取页:断线或回前台后按 seq 补齐,线上只发实时 final。
struct TranscriptPage: Decodable {
    struct Item: Decodable {
        let seq: Int
        let who: String
        let source: String
        let text: String
        let audioS: Double
        let gapS: Double?
        let ts: Double
        enum CodingKeys: String, CodingKey {
            case seq, who, source, text, ts
            case audioS = "audio_s", gapS = "gap_s"
        }
    }
    let items: [Item]
    let latest: Int
    let oldest: Int
    let truncated: Bool?
}

enum MeetingClient {
    private struct PendingStart: Codable {
        let serverURL: String
        let userID: String
        let deviceID: String
        let channel: String
        let requestID: String
        let meetingID: String?
    }
    private struct PendingStop: Codable {
        let serverURL: String
        let meetingID: String
        let deviceID: String
        let channel: String
        let requestID: String
        let generation: Int?
    }
    private static let pendingStopKey = "vm.pendingSystemAudioStop"
    private static let pendingMicStopKey = "vm.pendingMicStop"
    private static let pendingBroadcastStartKey = "vm.pendingSystemAudioStart"
    private static let pendingMicStartKey = "vm.pendingMicStart"
    static let appGroupID = "group.com.luanshijia.voicememo"
    static let appGroupCandidates = [appGroupID, "group.com.luanshijia.voicememo.458RP2552K"]
    static let defaultServerURL = "wss://100.64.0.2:7443"

    /// 设备名/使用者的真值只在打包时注入,源码留占位。
    /// 读不到 key(未注入 / 在扩展包里)时回落到中性占位,不会崩也不会显示空。
    private static func infoValue(_ key: String, fallback: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // build setting 未配置时 Info.plist 里会留下字面量 "$(VM_DEFAULT_DEVICE)"。
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return fallback }
        return trimmed
    }

    static var defaultDeviceID: String { infoValue("VMDefaultDevice", fallback: "iphone") }
    static var defaultUserID: String { infoValue("VMDefaultUser", fallback: "owner") }

    static func sharedDefaults() -> UserDefaults? {
        for group in appGroupCandidates where
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
            if let defaults = UserDefaults(suiteName: group) { return defaults }
        }
        return nil
    }

    static func credential() throws -> String {
        guard let token = sharedDefaults()?.string(forKey: "vm.deviceToken"),
              !token.isEmpty else {
            throw failure(10, "这台手机尚未登记设备凭据，请在设置中填写")
        }
        return token
    }

    static func requestGrant(serverURL: String, identity: String, userID: String,
                             deviceID: String, channel: String,
                             meetingID: String? = nil,
                             ttl: Int = 15 * 60) async throws -> MeetingGrant {
        guard var components = URLComponents(string: serverURL),
              let configuredHost = components.host else {
            throw failure(2, "连接地址不合法: \(serverURL)")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.startPath
        components.queryItems = [URLQueryItem(name: "identity", value: identity),
                                 URLQueryItem(name: "ttl", value: String(ttl))]
        guard let endpoint = components.url else {
            throw failure(2, "会议申请地址无效")
        }
        // Keep the same idempotency key across a lost HTTP response or process
        // death. It is cleared only after publication is reported or a stop is
        // durably queued; returning a grant is not proof that the caller saved it.
        let pending = try pendingStart(serverURL: serverURL, userID: userID,
                                       deviceID: deviceID, channel: channel,
                                       meetingID: meetingID)
        var payload: [String: Any] = ["request_id": pending.requestID,
                                      "user_id": userID, "device_id": deviceID,
                                      "channel": channel]
        if let meetingID = pending.meetingID { payload["meeting_id"] = meetingID }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw failure(3, "会议总管没有响应")
        }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw failure(http.statusCode, "电脑端拒绝会议申请(\(http.statusCode))\(body.isEmpty ? "" : ":" + body)")
        }
        let grant: MeetingGrant
        do {
            grant = try JSONDecoder().decode(MeetingGrant.self, from: data)
        } catch {
            throw failure(4, "会议授权回包解析失败: \(error.localizedDescription)")
        }
        guard grant.identity == identity,
              UUID(uuidString: grant.meetingID) != nil,
              !grant.token.isEmpty,
              let mediaURL = URL(string: grant.url),
              ["ws", "wss"].contains(mediaURL.scheme ?? ""),
              mediaURL.host?.caseInsensitiveCompare(configuredHost) == .orderedSame,
              grant.ttl > 0, grant.ttl <= 24 * 3600,
              grant.generation > 0 else {
            throw failure(5, "会议授权回包身份、会议号、地址或有效期无效")
        }
        return grant
    }

    static func reportObservation(serverURL: String, meetingID: String, deviceID: String,
                                  channel: String, generation: Int,
                                  observed: String) async throws {
        guard UUID(uuidString: meetingID) != nil,
              generation > 0, var components = URLComponents(string: serverURL) else {
            throw failure(14, "采集状态参数无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.observePathTemplate, meetingID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(14, "采集状态地址无效") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID, "channel": channel,
            "generation": generation, "observed": observed
        ])
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(14, "电脑端未确认采集状态")
        }
        if observed == "publishing" {
            clearPendingStart(channel: channel, deviceID: deviceID)
        }
    }

    static func sharedRegistration() throws -> (serverURL: String, deviceID: String, userID: String) {
        guard let defaults = sharedDefaults(),
              let serverURL = defaults.string(forKey: "lk.url"), !serverURL.isEmpty,
              let deviceID = defaults.string(forKey: "lk.device"), !deviceID.isEmpty,
              let userID = defaults.string(forKey: "lk.user"), !userID.isEmpty else {
            throw failure(6, "App Group 中没有电脑地址或设备登记信息；请先打开主 App 完成初始化")
        }
        return (serverURL, deviceID, userID)
    }

    static func deviceView(serverURL: String, deviceID: String) async throws -> DeviceMeetingView {
        guard var components = URLComponents(string: serverURL),
              deviceID.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            throw failure(9, "设备查询地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.devicePath(
            SessionControlContract.deviceViewPathTemplate, deviceID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(9, "设备查询地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(9, "电脑端会议查询失败")
        }
        return try JSONDecoder().decode(DeviceMeetingView.self, from: data)
    }

    static func fetchTranscript(serverURL: String, meetingID: String, deviceID: String,
                                after: Int) async throws -> TranscriptPage {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(12, "补取地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.transcriptPathTemplate, meetingID)
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID),
                                 URLQueryItem(name: "after", value: String(max(0, after)))]
        guard let endpoint = components.url else { throw failure(12, "补取地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端补取失败")
        }
        let page = try JSONDecoder().decode(TranscriptPage.self, from: data)
        // latest < oldest 只可能来自坏回包;宁可这一轮不补,也不把乱序的字塞进屏幕。
        guard page.latest >= page.oldest else { throw failure(12, "补取回包不自洽") }
        return page
    }

    static func fetchArtifact(serverURL: String, meetingID: String,
                              deviceID: String) async throws -> (sha256: String, data: Data) {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(11, "报告地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.artifactPathTemplate, meetingID)
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        guard let endpoint = components.url else { throw failure(11, "报告地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["meeting_id"] as? String == meetingID,
              let sha256 = object["sha256"] as? String, sha256.count == 64,
              let report = object["report"] as? [String: Any],
              let encoded = object["report_json_base64"] as? String,
              let reportBytes = Data(base64Encoded: encoded),
              let verifiedReport = try? JSONSerialization.jsonObject(with: reportBytes) as? [String: Any],
              NSDictionary(dictionary: verifiedReport).isEqual(to: report),
              SHA256.hash(data: reportBytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw failure(11, "报告尚未生成或回包无效")
        }
        return (sha256, data)
    }

    static func acknowledgeArtifact(serverURL: String, meetingID: String,
                                    deviceID: String, sha256: String) async throws {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(12, "报告回执地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.artifactAckPathTemplate, meetingID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(12, "报告回执地址无效") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID, "sha256": sha256
        ])
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端未确认报告送达")
        }
    }

    static func requestBroadcastGrant() async throws -> MeetingGrant {
        // A previous ReplayKit process may have been killed before its stop HTTP request finished.
        // Resolve that stop before starting a new generation of the same channel.
        try await flushPendingBroadcastStop()
        let registration = try sharedRegistration()
        let identity = registration.deviceID + "-replaykit"
        let view = try await deviceView(serverURL: registration.serverURL,
                                        deviceID: registration.deviceID)
        let meetingID = ["preparing", "active", "interrupted_pending"].contains(
            view.meeting?.status ?? "") ? view.meeting?.meetingID : nil
        let grant = try await requestGrant(serverURL: registration.serverURL,
                                           identity: identity,
                                           userID: registration.userID,
                                           deviceID: registration.deviceID,
                                           channel: SessionControlContract.systemAudio,
                                           meetingID: meetingID)
        return grant
    }

    static func stopChannel(serverURL: String, meetingID: String,
                            deviceID: String, channel: String,
                            generation: Int? = nil,
                            requestID: String = UUID().uuidString.lowercased()) async throws {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(7, "停止会议参数无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.stopPathTemplate, meetingID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(7, "停止会议地址无效") }
        guard channel == SessionControlContract.mic ||
              channel == SessionControlContract.systemAudio else {
            throw failure(7, "采集通道无效")
        }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
            var payload: [String: Any] = [
                "request_id": requestID,
                "device_id": deviceID,
                "channel": channel
            ]
            if let generation { payload["generation"] = generation }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure(8, "电脑端未确认会议停止")
            }
        }
    }

    /// 带号恢复被电脑端明确拒绝(旧会已封场,或这个号在电脑端已不存在)的判定。
    /// 只能按错误文案认码:控制面把 `{"error":"recovery_meeting_closed"}` 塞进 409 的
    /// body,而 `failure()` 只产出 code + message 的 NSError,没有结构化错误类型可用。
    static func isClosedMeetingRefusal(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("recovery_meeting_closed") || text.contains("recovery_meeting_not_found")
    }

    /// 丢掉这个通道的待确认申请。
    /// 为什么必须丢:同一个通道会复用原 requestID 与原请求体(见 `pendingStart`),
    /// 不清就会把"带号恢复"那条请求原样重放,永远拿不到新会。
    static func discardPendingStart(channel: String, deviceID: String) {
        clearPendingStart(channel: channel, deviceID: deviceID)
    }

    static func queueBroadcastStop(serverURL: String, meetingID: String, deviceID: String,
                                   generation: Int) throws {
        try queueStop(serverURL: serverURL, meetingID: meetingID,
                      deviceID: deviceID, channel: SessionControlContract.systemAudio,
                      generation: generation,
                      key: pendingStopKey)
    }

    static func queueMicStop(serverURL: String, meetingID: String, deviceID: String,
                             generation: Int) throws {
        try queueStop(serverURL: serverURL, meetingID: meetingID,
                      deviceID: deviceID, channel: SessionControlContract.mic,
                      generation: generation,
                      key: pendingMicStopKey)
    }

    private static func queueStop(serverURL: String, meetingID: String, deviceID: String,
                                  channel: String, generation: Int, key: String) throws {
        guard let defaults = sharedDefaults() else {
            throw failure(13, "App Group 不可用，无法保存停止请求")
        }
        if let data = defaults.data(forKey: key),
           let existing = try? JSONDecoder().decode(PendingStop.self, from: data),
           existing.meetingID == meetingID && existing.deviceID == deviceID &&
           existing.channel == channel && existing.generation == generation {
            clearPendingStart(channel: channel, deviceID: deviceID)
            return // Keep the idempotency key across retries and extension shutdown races.
        }
        let pending = PendingStop(serverURL: serverURL, meetingID: meetingID,
                                  deviceID: deviceID, channel: channel,
                                  requestID: UUID().uuidString.lowercased(),
                                  generation: generation)
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
        defaults.synchronize()
        clearPendingStart(channel: channel, deviceID: deviceID)
    }

    private static func pendingStartKey(_ channel: String) throws -> String {
        switch channel {
        case SessionControlContract.mic: return pendingMicStartKey
        case SessionControlContract.systemAudio: return pendingBroadcastStartKey
        default: throw failure(7, "采集通道无效")
        }
    }

    private static func pendingStart(serverURL: String, userID: String,
                                     deviceID: String, channel: String,
                                     meetingID: String?) throws -> PendingStart {
        guard let defaults = sharedDefaults() else {
            throw failure(13, "App Group 不可用，无法保存会议申请")
        }
        let key = try pendingStartKey(channel)
        if let data = defaults.data(forKey: key) {
            let pending = try JSONDecoder().decode(PendingStart.self, from: data)
            if pending.serverURL == serverURL, pending.userID == userID,
               pending.deviceID == deviceID, pending.channel == channel {
                // A retry must keep the original request body as well as its ID.
                // A newly observed meeting cannot be inserted into that fingerprint.
                return pending
            }
            // 这一条属于上一套设备登记或上一个地址,不是"丢失的回包"。
            // 以前这里抛错,结果是一次失败尝试(比如还没来得及填凭据)就能把 App 永久锁死:
            // 用户改了登记之后没有任何入口能清掉它,只能删 App 重装。
            defaults.removeObject(forKey: key)
        }
        if let meetingID, UUID(uuidString: meetingID) == nil {
            throw failure(15, "待恢复会议号无效")
        }
        let pending = PendingStart(serverURL: serverURL, userID: userID,
                                   deviceID: deviceID, channel: channel,
                                   requestID: UUID().uuidString.lowercased(),
                                   meetingID: meetingID)
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
        defaults.synchronize()
        return pending
    }

    private static func clearPendingStart(channel: String, deviceID: String) {
        guard let key = try? pendingStartKey(channel),
              let defaults = sharedDefaults(), let data = defaults.data(forKey: key),
              let pending = try? JSONDecoder().decode(PendingStart.self, from: data),
              pending.deviceID == deviceID else { return }
        defaults.removeObject(forKey: key)
    }

    static func flushPendingBroadcastStop() async throws {
        try await flushPendingStop(key: pendingStopKey)
    }

    static func flushPendingMicStop() async throws {
        try await flushPendingStop(key: pendingMicStopKey)
    }

    private static func flushPendingStop(key: String) async throws {
        guard let defaults = sharedDefaults(),
              let data = defaults.data(forKey: key) else { return }
        let pending = try JSONDecoder().decode(PendingStop.self, from: data)
        try await stopChannel(serverURL: pending.serverURL, meetingID: pending.meetingID,
                              deviceID: pending.deviceID, channel: pending.channel,
                              generation: pending.generation,
                              requestID: pending.requestID)
        // Another process may have replaced the record while this request was in flight.
        if defaults.data(forKey: key) == data {
            defaults.removeObject(forKey: key)
        }
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VoiceMemo.MeetingControl", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
