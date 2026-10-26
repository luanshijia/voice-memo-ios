import Foundation
import CryptoKit

/// Control API client used by the main App. App Group data below is read only for migration compatibility.
/// The computer creates the meeting id and returns it with the media grant.
struct MeetingGrant: Decodable {
    var requestID: String? = nil // local correlation; never decoded from the server
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
        /// 格式错误由控制回包契约拒绝；此处仅解析已校验的可选字段。
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
    let meetingID: String
    let epoch: String?
    let reset: Bool?
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
    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id", epoch, reset, items, latest, oldest, truncated
    }
}

enum MeetingClient {
    private struct PendingStart: Codable {
        let serverURL: String
        let userID: String
        let deviceID: String
        let channel: String
        let requestID: String
        let meetingID: String?
        var grantedMeetingID: String? = nil
        var grantedGeneration: Int? = nil
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

    private static func pendingStore() throws -> PendingRequestStore {
        let oldRoots = appGroupCandidates.compactMap({
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }).map { $0.appendingPathComponent("pending-control", isDirectory: true) }
        return PendingRequestStore(root: try AppStorage.pendingRequestDirectory(),
                                   legacy: sharedDefaults(), legacyRoots: oldRoots)
    }

    private static func validatedResponse(_ data: Data, kind: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure(16, "控制回包不是 JSON 对象")
        }
        if let problem = SessionControlContract.responseProblem(kind, object: object) {
            throw failure(16, "控制回包不符合契约：\(problem)")
        }
        return object
    }

    static func credential() throws -> String {
        guard let token = UserDefaults.standard.string(forKey: "vm.deviceToken"),
              !token.isEmpty else {
            throw failure(10, "这台手机尚未登记设备凭据，请在设置中填写")
        }
        return token
    }

    static func requestGrant(serverURL: String, identity: String, userID: String,
                             deviceID: String, channel: String,
                             meetingID: String? = nil,
                             ttl: Int = 15 * 60) async throws -> MeetingGrant {
        guard channel == SessionControlContract.mic else {
            throw failure(7, "此客户端只允许申请手机麦克风通道")
        }
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
            let errorCode = Self.controlErrorCode(from: data)
            throw failure(http.statusCode,
                          "电脑端拒绝会议申请(\(http.statusCode))\(body.isEmpty ? "" : ":" + body)",
                          controlErrorCode: errorCode)
        }
        var grant: MeetingGrant
        do {
            let object = try validatedResponse(data, kind: "grant")
            guard SessionControlContract.startRequiredFields.isSubset(of: Set(object.keys)) else {
                throw failure(4, "会议授权回包缺少契约字段")
            }
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
        grant.requestID = pending.requestID
        try pendingStore().transaction(try pendingStartKey(channel)) { data in
            guard let data, var saved = try? JSONDecoder().decode(PendingStart.self, from: data),
                  saved.requestID == pending.requestID else { return (data, ()) }
            saved.grantedMeetingID = grant.meetingID
            saved.grantedGeneration = grant.generation
            return (try JSONEncoder().encode(saved), ())
        }
        return grant
    }

    static func reportObservation(serverURL: String, meetingID: String, deviceID: String,
                                  channel: String, generation: Int,
                                  observed: String, requestID: String? = nil) async throws {
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(14, "电脑端未确认采集状态")
        }
        let confirmation = try validatedResponse(data, kind: "observation")
        guard confirmation["meeting_id"] as? String == meetingID else { throw failure(14, "采集回执会议号不一致") }
        if observed == "publishing", let requestID {
            try clearPendingStart(channel: channel, deviceID: deviceID, requestID: requestID)
        }
    }

    static func sharedRegistration() throws -> (serverURL: String, deviceID: String, userID: String) {
        let defaults = UserDefaults.standard
        guard
              let serverURL = defaults.string(forKey: "lk.url"), !serverURL.isEmpty,
              let deviceID = defaults.string(forKey: "lk.device"), !deviceID.isEmpty,
              let userID = defaults.string(forKey: "lk.user"), !userID.isEmpty else {
            throw failure(6, "本机没有电脑地址或设备登记信息；请先在设置页完成初始化")
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
        _ = try validatedResponse(data, kind: "device_view")
        let view = try JSONDecoder().decode(DeviceMeetingView.self, from: data)
        if let receiver = view.view {
            guard receiver.meetingID == view.meeting?.meetingID,
                  receiver.identity == deviceID + "-view",
                  let media = URL(string: receiver.url), media.scheme == "wss",
                  media.host?.caseInsensitiveCompare(components.host ?? "") == .orderedSame else {
                throw failure(9, "会议查看授权与设备或地址不一致")
            }
        }
        return view
    }

    static func fetchTranscript(serverURL: String, meetingID: String, deviceID: String,
                                after: Int, epoch: String? = nil) async throws -> TranscriptPage {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(12, "补取地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.transcriptPathTemplate, meetingID)
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID),
                                 URLQueryItem(name: "after", value: String(max(0, after)))]
        if let epoch { components.queryItems?.append(URLQueryItem(name: "epoch", value: epoch)) }
        guard let endpoint = components.url else { throw failure(12, "补取地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端补取失败")
        }
        let object = try validatedResponse(data, kind: "transcript")
        guard SessionControlContract.transcriptRequiredFields.isSubset(of: Set(object.keys)) else {
            throw failure(12, "补取回包缺少契约字段")
        }
        let page = try JSONDecoder().decode(TranscriptPage.self, from: data)
        // latest < oldest 只可能来自坏回包;宁可这一轮不补,也不把乱序的字塞进屏幕。
        guard page.meetingID == meetingID, page.oldest >= 0, page.latest >= page.oldest,
              page.epoch == nil || UUID(uuidString: page.epoch!) != nil,
              page.items.allSatisfy({ $0.seq > 0 && $0.seq >= page.oldest && $0.seq <= page.latest &&
                  $0.audioS.isFinite && $0.audioS >= 0 && $0.ts.isFinite && $0.ts > 0 &&
                  ($0.gapS == nil || ($0.gapS!.isFinite && $0.gapS! >= 0)) }),
              Set(page.items.map(\.seq)).count == page.items.count else {
            throw failure(12, "补取回包不自洽")
        }
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(11, "报告尚未生成或回包无效")
        }
        let object = try validatedResponse(data, kind: "artifact")
        guard object["meeting_id"] as? String == meetingID,
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端未确认报告送达")
        }
        let confirmation = try validatedResponse(data, kind: "artifact_ack")
        guard confirmation["meeting_id"] as? String == meetingID,
              confirmation["sha256"] as? String == sha256 else { throw failure(12, "报告回执版本不一致") }
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure(8, "电脑端未确认会议停止")
            }
            let confirmation = try validatedResponse(data, kind: "stop")
            guard confirmation["meeting_id"] as? String == meetingID else { throw failure(8, "停止回执会议号不一致") }
        }
    }

    /// 带号恢复被电脑端明确拒绝(旧会已封场,或这个号在电脑端已不存在)的判定。
    static func isClosedMeetingRefusal(_ error: Error) -> Bool {
        let code = (error as NSError).userInfo["controlErrorCode"] as? String
        return code == "recovery_meeting_closed" || code == "recovery_meeting_not_found"
    }

    private static func controlErrorCode(from data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = body["error"] as? String else { return nil }
        return code
    }

    /// 丢掉这个通道的待确认申请。
    /// 为什么必须丢:同一个通道会复用原 requestID 与原请求体(见 `pendingStart`),
    /// 不清就会把"带号恢复"那条请求原样重放,永远拿不到新会。
    static func discardPendingStart(channel: String, deviceID: String) throws {
        try clearPendingStart(channel: channel, deviceID: deviceID, discard: true)
    }

    static func retireClosedStart(channel: String, deviceID: String, meetingID: String) throws {
        try pendingStore().transaction(try pendingStartKey(channel)) { data in
            guard let data, let saved = try? JSONDecoder().decode(PendingStart.self, from: data),
                  saved.deviceID == deviceID,
                  saved.grantedMeetingID == meetingID || saved.meetingID == meetingID else { return (data, ()) }
            return (nil, ())
        }
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
        try pendingStore().transaction(key) { data in
            if let data, let existing = try? JSONDecoder().decode(PendingStop.self, from: data),
               existing.serverURL == serverURL, existing.meetingID == meetingID,
               existing.deviceID == deviceID, existing.channel == channel,
               existing.generation == generation { return (data, ()) }
            let pending = PendingStop(serverURL: serverURL, meetingID: meetingID,
                deviceID: deviceID, channel: channel, requestID: UUID().uuidString.lowercased(),
                generation: generation)
            return (try JSONEncoder().encode(pending), ())
        }
        try clearPendingStart(channel: channel, deviceID: deviceID,
                              meetingID: meetingID, generation: generation)
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
        if let meetingID, UUID(uuidString: meetingID) == nil {
            throw failure(15, "待恢复会议号无效")
        }
        return try pendingStore().transaction(try pendingStartKey(channel)) { data in
            if let data {
                let pending = try JSONDecoder().decode(PendingStart.self, from: data)
                if pending.serverURL == serverURL, pending.userID == userID,
                   pending.deviceID == deviceID, pending.channel == channel {
                    return (data, pending) // replay the original id and fingerprint
                }
            }
            let pending = PendingStart(serverURL: serverURL, userID: userID, deviceID: deviceID,
                channel: channel, requestID: UUID().uuidString.lowercased(), meetingID: meetingID)
            return (try JSONEncoder().encode(pending), pending)
        }
    }

    private static func clearPendingStart(channel: String, deviceID: String,
                                          requestID: String? = nil, meetingID: String? = nil,
                                          generation: Int? = nil, discard: Bool = false) throws {
        try pendingStore().transaction(try pendingStartKey(channel)) { data in
            guard let data, let saved = try? JSONDecoder().decode(PendingStart.self, from: data),
                  saved.deviceID == deviceID else { return (data, ()) }
            let sameRequest = requestID != nil && saved.requestID == requestID
            let sameGrant = meetingID != nil && saved.grantedMeetingID == meetingID &&
                saved.grantedGeneration == generation
            return (discard || sameRequest || sameGrant ? nil : data, ())
        }
    }

    static func flushPendingBroadcastStop() async throws {
        try await flushPendingStop(key: pendingStopKey)
    }

    static func flushPendingMicStop() async throws {
        try await flushPendingStop(key: pendingMicStopKey)
    }

    private static func flushPendingStop(key: String) async throws {
        let store = try pendingStore()
        guard let data = try store.read(key) else { return }
        let pending = try JSONDecoder().decode(PendingStop.self, from: data)
        try await stopChannel(serverURL: pending.serverURL, meetingID: pending.meetingID,
                              deviceID: pending.deviceID, channel: pending.channel,
                              generation: pending.generation, requestID: pending.requestID)
        try store.transaction(key) { current in (current == data ? nil : current, ()) }
    }

    private static func failure(_ code: Int, _ message: String,
                                controlErrorCode: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let controlErrorCode { userInfo["controlErrorCode"] = controlErrorCode }
        return NSError(domain: "VoiceMemo.MeetingControl", code: code,
                       userInfo: userInfo)
    }
}


/// V2 authoritative capture projection. A media grant is optional on observations/actions.
struct CaptureView: Codable, Equatable {
    struct Binding: Codable, Equatable {
        let channel: String
        let inputRef: String
        enum CodingKeys: String, CodingKey { case channel; case inputRef = "input_ref" }
    }
    struct Media: Codable, Equatable { let url: String; let token: String; let identity: String }
    let meetingID: String
    let protocolVersion: Int
    let observationRevision: Int?
    let status: String
    let stateRevision: Int
    let desiredState: String
    let observedState: String
    let channel: String
    let generation: Int
    let segmentID: String
    let sourceTag: String
    let input: Binding
    let room: String
    let createdAt: String
    let identity: String
    let media: Media?
    var canRecover: Bool { desiredState == "active" && SessionControlV2Contract.recoveryEligibleMeetingStates.contains(status) }
    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id", protocolVersion = "protocol_version", status
        case observationRevision = "observation_revision"
        case stateRevision = "state_revision", desiredState = "desired_state", observedState = "observed_state"
        case channel, generation, segmentID = "segment_id", sourceTag = "source_tag", input, room
        case createdAt = "created_at", identity, media
    }
}
struct CaptureDeviceView: Decodable {
    let meeting: CaptureView?
    let pendingReports: [DeviceMeetingView.PendingReport]
    enum CodingKeys: String, CodingKey { case meeting; case pendingReports = "pending_reports" }
}

extension MeetingClient {
    private struct PendingCapture: Codable {
        let serverURL: String
        let deviceID: String
        let path: String
        let body: Data
        let requestID: String
        let action: String
        var afterGrant: String?
    }
    private static let capturePendingKey = "vm.pendingCaptureV2"
    private static let captureGrantKey = "vm.captureGrantV2"
    static func hasPendingCapture() -> Bool {
        (try? pendingStore().read(capturePendingKey)) != nil
    }
    static func savedCapture() -> CaptureView? {
        guard let data = try? pendingStore().read(captureGrantKey) else { return nil }
        return try? JSONDecoder().decode(CaptureView.self, from: data)
    }
    private static func saveCapture(_ view: CaptureView) throws {
        let data = try JSONEncoder().encode(view)
        try pendingStore().transaction(captureGrantKey) { current in
            if let current, let saved = try? JSONDecoder().decode(CaptureView.self, from: current) {
                if saved.createdAt > view.createdAt || (saved.meetingID == view.meetingID &&
                    (saved.stateRevision > view.stateRevision ||
                     (saved.stateRevision == view.stateRevision && (saved.observationRevision ?? 0) > (view.observationRevision ?? 0)))) {
                    return (current, ())
                }
            }
            return (data, ())
        }
    }
    private static func captureEndpoint(_ serverURL: String, path: String) throws -> URL {
        guard var c = URLComponents(string: serverURL), c.scheme == "wss", c.host != nil else {
            throw failure(60, "电脑地址必须为 wss://")
        }
        c.scheme = "https"; c.path = path; c.queryItems = nil
        guard let url = c.url else { throw failure(60, "会控地址无效") }
        return url
    }
    private static func captureRequest(serverURL: String, path: String, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: try captureEndpoint(serverURL, path: path))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        req.timeoutInterval = 8; req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = controlErrorCode(from: data) ?? "control_v2_unavailable"
            throw failure(61, "电脑会控未确认：" + code, controlErrorCode: code)
        }
        return data
    }
    private static func decodeCapture(_ data: Data) throws -> CaptureView {
        let object = try JSONSerialization.jsonObject(with: data)
        if let problem = SessionControlV2Contract.responseProblem("capture", object: object) {
            throw failure(62, "会控回包不符合契约：" + problem)
        }
        return try JSONDecoder().decode(CaptureView.self, from: data)
    }
    static func captureDeviceView(config: LiveKitConfig) async throws -> CaptureDeviceView {
        let path = SessionControlV2Contract.device_viewPath.replacingOccurrences(of: "{device_id}", with: config.device)
        let data = try await captureRequest(serverURL: config.url, path: path)
        let view = try JSONDecoder().decode(CaptureDeviceView.self, from: data)
        if let capture = view.meeting { _ = try decodeCapture(JSONEncoder().encode(capture)) }
        return view
    }
    static func queueCaptureStart(config: LiveKitConfig, revision: Int, input: InputBinding,
                                  meetingID: String?) throws {
        let store = try pendingStore()
        try store.transaction(capturePendingKey) { current in
            if let current {
                let pending = try JSONDecoder().decode(PendingCapture.self, from: current)
                guard pending.serverURL == config.url, pending.deviceID == config.device,
                      pending.action == "start" else { throw failure(63, "请先确认上一项会控动作") }
                return (current, ())
            }
            let id = UUID().uuidString.lowercased()
            var object: [String: Any] = ["request_id": id, "device_id": config.device, "user_id": config.userID,
                "config_revision": revision, "input": ["channel": input.channel, "input_ref": input.inputRef],
                "source_tag": input.sourceTag.rawValue]
            if let meetingID { object["resume_meeting_id"] = meetingID }
            let pending = PendingCapture(serverURL: config.url, deviceID: config.device,
                path: SessionControlV2Contract.startPath, body: try JSONSerialization.data(withJSONObject: object),
                requestID: id, action: "start")
            return (try JSONEncoder().encode(pending), ())
        }
    }
    static func queueCaptureAction(config: LiveKitConfig, view: CaptureView?, action: String,
                                   input: InputBinding? = nil) throws {
        guard let view = view ?? savedCapture().flatMap({ $0.desiredState == "ended" ? nil : $0 }) else {
            guard action == "pause" || action == "end" else { throw failure(63, "没有可操作的会议") }
            try pendingStore().transaction(capturePendingKey) { current in
                guard let current else { throw failure(63, "没有待确认的会议申请") }
                var pending = try JSONDecoder().decode(PendingCapture.self, from: current)
                guard pending.action == "start" else { throw failure(63, "会议申请尚未对账") }
                if pending.afterGrant != "end" { pending.afterGrant = action }
                return (try JSONEncoder().encode(pending), ())
            }
            return
        }
        let id = UUID().uuidString.lowercased()
        var object: [String: Any] = ["request_id": id, "device_id": config.device,
            "expected_revision": view.stateRevision, "generation": view.generation,
            "segment_id": view.segmentID, "action": action]
        if let input { object["input"] = ["channel": input.channel, "input_ref": input.inputRef]; object["source_tag"] = input.sourceTag.rawValue }
        let pending = PendingCapture(serverURL: config.url, deviceID: config.device,
            path: SessionControlV2Contract.actionsPath.replacingOccurrences(of: "{meeting_id}", with: view.meetingID),
            body: try JSONSerialization.data(withJSONObject: object), requestID: id, action: action)
        try pendingStore().transaction(capturePendingKey) { current in
            if let current {
                let old = try JSONDecoder().decode(PendingCapture.self, from: current)
                if old.action == "end" && action != "end" { throw failure(63, "结束动作优先，不能恢复采集") }
            }
            return (try JSONEncoder().encode(pending), ())
        }
    }
    static func flushPendingCapture(allowRebase: Bool = true) async throws -> CaptureView? {
        let store = try pendingStore()
        guard let data = try store.read(capturePendingKey) else { return nil }
        let pending = try JSONDecoder().decode(PendingCapture.self, from: data)
        let view: CaptureView
        do {
            view = try decodeCapture(await captureRequest(serverURL: pending.serverURL, path: pending.path, body: pending.body))
        } catch {
            let code = (error as NSError).userInfo["controlErrorCode"] as? String ?? ""
            guard allowRebase, ["stale_capture_revision", "stale_segment", "request_superseded", "capture_ended"].contains(code) else { throw error }
            let config = LiveKitConfig(url: pending.serverURL, device: pending.deviceID, userID: "")
            guard let fresh = try await captureDeviceView(config: config).meeting,
                  pending.path.contains(fresh.meetingID) else { throw error }
            if ["pause", "end"].contains(pending.action), fresh.desiredState != "ended",
               !(pending.action == "pause" && fresh.desiredState == "paused") {
                try queueCaptureAction(config: config, view: fresh, action: pending.action)
                return try await flushPendingCapture(allowRebase: false)
            }
            try saveCapture(fresh)
            try store.transaction(capturePendingKey) { current in
                guard let current, let latest = try? JSONDecoder().decode(PendingCapture.self, from: current),
                      latest.requestID == pending.requestID else { return (current, ()) }
                return (nil, ())
            }
            return fresh // A conflicting resume never reopens input automatically.
        }
        try saveCapture(view) // Save the granted identity/segment before forgetting the request.
        let after: String? = try store.transaction(capturePendingKey) { current in
            guard let current, let latest = try? JSONDecoder().decode(PendingCapture.self, from: current),
                  latest.requestID == pending.requestID else { return (current, nil) }
            return (nil, latest.afterGrant)
        }
        if let after {
            let config = LiveKitConfig(url: pending.serverURL, device: pending.deviceID, userID: "")
            try queueCaptureAction(config: config, view: view, action: after)
            return try await flushPendingCapture()
        }
        return view
    }
    static func observeCapture(config: LiveKitConfig, view: CaptureView, observed: String) async throws {
        let body: [String: Any] = ["device_id": config.device, "channel": view.channel,
            "generation": view.generation, "segment_id": view.segmentID, "observed": observed]
        let path = SessionControlV2Contract.observePath.replacingOccurrences(of: "{meeting_id}", with: view.meetingID)
        _ = try decodeCapture(await captureRequest(serverURL: config.url, path: path,
                      body: JSONSerialization.data(withJSONObject: body)))
    }
}
